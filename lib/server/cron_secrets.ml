let root = "/etc/bondi/cron"
let dir_of name = Filename.concat root name
let env_file_of name = Filename.concat (dir_of name) "env"

(* Same rule as Managed_container.is_valid_name, and for the same reason: this
   name arrives in a deploy payload from the network and is interpolated into a
   path that gets written. A leading dot or any separator must not be
   representable, or "job" could name its way out of its own directory. *)
let is_valid_name name =
  let valid_char c =
    (c >= 'a' && c <= 'z')
    || (c >= 'A' && c <= 'Z')
    || (c >= '0' && c <= '9')
    || c = '_'
    || c = '.'
    || c = '-'
  in
  let alnum c =
    (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
  in
  String.length name > 0 && alnum name.[0] && String.for_all valid_char name

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
    try Unix.mkdir path 0o700 with
    | Unix.Unix_error (Unix.EEXIST, _, _) -> ()
  end

let write_env_file ~name entries =
  if not (is_valid_name name) then
    Error (Printf.sprintf "unsafe cron job name for a config path: %S" name)
  else
    try
      mkdir_p (dir_of name);
      let path = env_file_of name in
      (* 0o600 at creation. A chmod after the fact leaves a window in which the
         credential is world-readable, and O_TRUNC means a withdrawn secret does
         not survive in the tail of the old file. *)
      let fd =
        Unix.openfile path [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC ] 0o600
      in
      Fun.protect
        ~finally:(fun () ->
          try Unix.close fd with
          | Unix.Unix_error _ -> ())
        (fun () ->
          let s = file_contents entries in
          let n = Unix.write_substring fd s 0 (String.length s) in
          if n <> String.length s then
            failwith "short write to cron secret env file");
      (* An existing file created before this ran, or by an older Bondi, keeps
         its old mode through O_CREAT. Set it explicitly. *)
      Unix.chmod path 0o600;
      Ok ()
    with
    | Unix.Unix_error (e, _, _) ->
        Error
          (Printf.sprintf "could not write %s: %s" (env_file_of name)
             (Unix.error_message e))
    | Failure msg -> Error msg

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
