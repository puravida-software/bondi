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

(* A prompt is a wait with no deadline, and neither command that reads a host is
   attended by anyone who could answer one — hence the two that were always
   here.

   The three bounds are the same reasoning applied to the network. A host that
   refuses the connection answers at once; one that accepts it and then drops
   the packets answers never, and [ssh] has no deadline of its own. Both
   commands that read a host print a report at the end of their work, so an
   unbounded read is the report being lost on exactly the failure it exists to
   describe. The keepalive covers the harder half: a session that was
   established and then went quiet, which no connect timeout can reach. *)
let ssh_options =
  [
    "-o BatchMode=yes";
    "-o StrictHostKeyChecking=accept-new";
    "-o ConnectTimeout=10";
    "-o ServerAliveInterval=15";
    "-o ServerAliveCountMax=4";
  ]

(* One SSH connection reused across a command's many round trips.
   `bondi setup` issues 31 separate ssh invocations. Measured against the
   trading box on 2026-09-02: 2.48s each cold, 0.39s multiplexed -- about 77
   seconds of pure handshake per setup, versus about 15. The server side was
   already clean (usedns no, gssapiauthentication no); this was entirely a
   missing client option.

   The socket lives in a private mode-700 directory named after this process,
   not at a predictable path in a shared /tmp. Whoever can open a control socket
   can multiplex onto the connection it holds -- which is root on a deploy box.
   On the runner fleet every agent runs as the same uid, so a shared, guessable
   path would let any repo's job ride another job's deployment connection. The
   directory is removed at exit; a master that outlives it is unreachable and
   expires on ControlPersist. *)
let control_dir =
  lazy
    (let dir =
       Filename.concat
         (Filename.get_temp_dir_name ())
         (Printf.sprintf "bondi-ssh-%d" (Unix.getpid ()))
     in
     (try Unix.mkdir dir 0o700 with
     | Unix.Unix_error (Unix.EEXIST, _, _) -> ());
     at_exit (fun () ->
         (try
            Array.iter
              (fun f ->
                try Unix.unlink (Filename.concat dir f) with
                | _ -> ())
              (Sys.readdir dir)
          with
         | _ -> ());
         try Unix.rmdir dir with
         | _ -> ());
     dir)

(* Kept apart from [ssh_options] because not every caller wants it: an SSH
   tunnel is one long-lived connection that gains nothing from multiplexing, and
   routing it through a shared master would make tearing it down a question of
   channels rather than of killing a process. *)
let multiplex_options () =
  let dir = Lazy.force control_dir in
  [
    "-o ControlMaster=auto";
    Printf.sprintf "-o ControlPath=%s"
      (Filename.quote (Filename.concat dir "c"));
    "-o ControlPersist=30";
  ]

let remote_run ~user ~host ~key_path cmd =
  let destination = user ^ "@" ^ host in
  let ssh_cmd =
    Printf.sprintf "ssh -i %s %s %s %s -- %s" (Filename.quote key_path)
      (String.concat " " ssh_options)
      (String.concat " " (multiplex_options ()))
      (Filename.quote destination)
      (Filename.quote cmd)
  in
  run_command ssh_cmd

let command_output ~command server =
  match server.Config_file.ssh with
  | None ->
      Error
        (Printf.sprintf "Missing ssh configuration for server %s"
           server.Config_file.ip_address)
  | Some ssh_config ->
      with_temp_key ssh_config.private_key_contents (fun key_path ->
          remote_run ~user:ssh_config.user ~host:server.Config_file.ip_address
            ~key_path command)

let docker_command_output ~command server =
  command_output ~command:("docker " ^ command) server
