module Report = Bondi_client.Status_report

let mk_config ?user_service ?cron_jobs ?managed_containers ?bind_address
    ?api_token () : Bondi_client.Config_file.t =
  {
    user_service;
    bondi_server = { version = "0.1.0"; bind_address; api_token };
    traefik = None;
    cron_jobs;
    alloy = None;
    managed_containers;
  }

let mk_managed_container name image tag :
    Bondi_client.Config_file.managed_container =
  {
    name;
    image;
    tag;
    restart = "unless-stopped";
    network = Some "bondi-network";
    ports = None;
    env_vars = None;
    secret_env_vars = None;
  }

let row_named name (rows : Report.row list) =
  match
    List.find_opt (fun (row : Report.row) -> String.equal row.name name) rows
  with
  | Some row -> row
  | None ->
      Alcotest.failf "expected a row named %s, got rows: %s" name
        (String.concat ", "
           (List.map (fun (row : Report.row) -> row.name) rows))

(* PATH is restored on every path out, including the one where there was no
   PATH to begin with: leaving a stub directory on it outlives this case and
   every later one in the executable resolves [ssh] to whichever stub ran last.
   There is no [unsetenv] in [Unix], so an absent PATH is restored as an empty
   one -- which is what an absent PATH means to a search. *)
let with_path value f =
  let previous = Sys.getenv_opt "PATH" in
  Unix.putenv "PATH" value;
  Fun.protect
    ~finally:(fun () ->
      match previous with
      | None -> Unix.putenv "PATH" ""
      | Some previous -> Unix.putenv "PATH" previous)
    f

let with_ssh_stub script f =
  let dir = Filename.temp_dir "bondi-ssh-stub-" "" in
  (* The directory is removed by a cleanup of its own rather than after the
     stub's removal, so a stub that could not be removed does not also leak the
     directory that holds it. *)
  Fun.protect
    ~finally:(fun () ->
      try Unix.rmdir dir with
      | Unix.Unix_error _ -> ())
    (fun () ->
      let stub = Filename.concat dir "ssh" in
      Fun.protect
        ~finally:(fun () ->
          try Sys.remove stub with
          | Sys_error _ -> ())
        (fun () ->
          let oc = open_out stub in
          output_string oc script;
          close_out oc;
          Unix.chmod stub 0o755;
          with_path
            (match Sys.getenv_opt "PATH" with
            | None -> dir
            | Some previous -> dir ^ ":" ^ previous)
            f))

(* The lines the recording stub left, in the order it wrote them. A record that
   was never written to is no invocations rather than a failure to read: the
   stub creates the file on its first append and a case that expects none is
   entitled to find nothing. *)
let recorded path =
  match open_in_bin path with
  | ic ->
      Fun.protect
        ~finally:(fun () -> close_in_noerr ic)
        (fun () ->
          String.split_on_char '\n'
            (really_input_string ic (in_channel_length ic))
          |> List.filter (fun line -> not (String.equal line "")))
  | exception Sys_error _ -> []

(* Which key file each [ssh] invocation was handed, which is the only place the
   staging is visible from outside: the path is a temporary file the runner
   removes before it returns, and the type that holds it says nothing.

   The stub records its second argument because that is what [-i] is given, and
   it exits zero without printing so that a caller reads the count of
   invocations rather than a fixture's output. *)
let staged_keys_during f =
  let dir = Filename.temp_dir "bondi-key-record-" "" in
  let record = Filename.concat dir "keys" in
  Fun.protect
    ~finally:(fun () ->
      (try Sys.remove record with
      | Sys_error _ -> ());
      try Unix.rmdir dir with
      | Unix.Unix_error _ -> ())
    (fun () ->
      let value =
        with_ssh_stub
          (Printf.sprintf "#!/bin/sh\nprintf '%%s\\n' \"$2\" >> %s\n"
             (Filename.quote record))
          f
      in
      (value, recorded record))
