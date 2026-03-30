let read_all ic =
  let buffer = Buffer.create 256 in
  (try
     while true do
       let line = input_line ic in
       Buffer.add_string buffer line;
       Buffer.add_char buffer '\n'
     done
   with
  | End_of_file -> ());
  Buffer.contents buffer

let run_command cmd =
  let merged_cmd = cmd ^ " 2>&1" in
  let ic = Unix.open_process_in merged_cmd in
  let output = read_all ic in
  match Unix.close_process_in ic with
  | Unix.WEXITED 0 -> Ok output
  | Unix.WEXITED code ->
      Error (Printf.sprintf "command failed (%d): %s" code (String.trim output))
  | Unix.WSIGNALED signal ->
      Error
        (Printf.sprintf "command killed (%d): %s" signal (String.trim output))
  | Unix.WSTOPPED signal ->
      Error
        (Printf.sprintf "command stopped (%d): %s" signal (String.trim output))

let decode_private_key contents =
  match Base64.decode contents with
  | Ok decoded -> decoded
  | Error _ -> contents

let with_temp_key contents f =
  let path = Filename.temp_file "bondi-key-" ".pem" in
  let decoded = decode_private_key contents in
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () ->
      close_out_noerr oc;
      Sys.remove path)
    (fun () ->
      output_string oc decoded;
      close_out oc;
      Unix.chmod path 0o600;
      f path)

let remote_run ~user ~host ~key_path cmd =
  let destination = user ^ "@" ^ host in
  let ssh_cmd =
    Printf.sprintf
      "ssh -i %s -o BatchMode=yes -o StrictHostKeyChecking=accept-new %s -- %s"
      (Filename.quote key_path)
      (Filename.quote destination)
      (Filename.quote cmd)
  in
  run_command ssh_cmd

let run_remote_docker ~user ~host ~key_path cmd =
  remote_run ~user ~host ~key_path ("docker " ^ cmd)

let docker_command_output ~command server =
  match server.Config_file.ssh with
  | None ->
      Error
        (Printf.sprintf "Missing ssh configuration for server %s"
           server.Config_file.ip_address)
  | Some ssh_config ->
      with_temp_key ssh_config.private_key_contents (fun key_path ->
          run_remote_docker ~user:ssh_config.user
            ~host:server.Config_file.ip_address ~key_path command)
