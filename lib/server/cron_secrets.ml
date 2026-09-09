(* The root and both file paths are Bondi_common.Cron_exec_line's, because the
   crontab line the server writes names the run file and the client reads the
   name back out of that same path. A second spelling of either here is a
   spelling that can drift from the line.

   The environment file's path is there for the second reason: the client checks
   that a job's files survived a rebuilt container, and it cannot look for a
   file whose name is written only in this library.

   The mode comes from the same place, because the client creates this directory
   too -- on the host, ahead of copying the files out of a container it is about
   to remove -- and a second spelling of 0700 is a second spelling that can
   drift. *)
let root = Bondi_common.Cron_exec_line.cron_root
let root_mode = Bondi_common.Cron_exec_line.cron_root_mode
let dir_of name = Filename.concat root name
let env_file_of = Bondi_common.Cron_exec_line.env_file_of
let run_file_of = Bondi_common.Cron_exec_line.run_file_of

(* Managed_container's rule, called rather than restated: this name arrives in a
   deploy payload from the network and is interpolated into a path that gets
   written, so a leading dot or any separator must not be representable, or
   "job" could name its way out of its own directory. Restating it gave two
   predicates that agreed and were held together by nothing. *)
let is_valid_name = Bondi_common.Managed_container.is_valid_name

let file_contents entries =
  String.concat ""
    (List.map (fun (k, v) -> Printf.sprintf "%s=%s\n" k v) entries)

let parse_file contents =
  contents
  |> String.split_on_char '\n'
  |> List.filter_map (fun line ->
      match String.index_opt line '=' with
      | None -> None
      | Some i ->
          let key = String.sub line 0 i in
          let value = String.sub line (i + 1) (String.length line - i - 1) in
          if key = "" then None else Some (key, value))

let merge ~plain ~secret =
  let overridden = List.map fst secret in
  let kept = List.filter (fun (k, _) -> not (List.mem k overridden)) plain in
  List.map (fun (k, v) -> Printf.sprintf "%s=%s" k v) (kept @ secret)

let rec mkdir_p path =
  if path = "/" || path = "." || Sys.file_exists path then ()
  else begin
    mkdir_p (Filename.dirname path);
    try Unix.mkdir path root_mode with
    | Unix.Unix_error (Unix.EEXIST, _, _) -> ()
  end

(* 0o600 at creation. A chmod after the fact leaves a window in which the
   contents are world-readable, and O_TRUNC means a withdrawn secret does not
   survive in the tail of the old file. *)
let write_600 path contents =
  let fd =
    Unix.openfile path [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC ] 0o600
  in
  Fun.protect
    ~finally:(fun () ->
      try Unix.close fd with
      | Unix.Unix_error _ -> ())
    (fun () ->
      let n = Unix.write_substring fd contents 0 (String.length contents) in
      if n <> String.length contents then
        failwith (Printf.sprintf "short write to %s" path));
  (* An existing file created before this ran, or by an older Bondi, keeps its
     old mode through O_CREAT. Set it explicitly. *)
  Unix.chmod path 0o600

(* The name check runs before any I/O, so a name that could escape the job's
   directory never reaches mkdir or open. No error message names the contents:
   for both files the contents are the thing the file exists to keep out of the
   crontab, and this text is returned over HTTP and mailed by cron. *)
let write_job_file ~name ~path_of contents =
  if not (is_valid_name name) then
    Error (Printf.sprintf "unsafe cron job name for a config path: %S" name)
  else
    try
      mkdir_p (dir_of name);
      write_600 (path_of name) contents;
      Ok ()
    with
    | Unix.Unix_error (e, _, _) ->
        Error
          (Printf.sprintf "could not write %s: %s" (path_of name)
             (Unix.error_message e))
    | Failure msg -> Error msg

let write_env_file ~name entries =
  write_job_file ~name ~path_of:env_file_of (file_contents entries)

let write_run_file ~name payload =
  write_job_file ~name ~path_of:run_file_of (Yojson.Safe.to_string payload)

let read_env_file name =
  if not (is_valid_name name) then []
  else
    let path = env_file_of name in
    try
      let ic = open_in_bin path in
      Fun.protect
        ~finally:(fun () -> close_in_noerr ic)
        (fun () -> parse_file (really_input_string ic (in_channel_length ic)))
    with
    | Sys_error _ -> []
    | End_of_file -> []
