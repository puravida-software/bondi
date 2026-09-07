let ( let* ) = Result.bind

type failure =
  | Not_configured of { server : string }
  | Ssh_failed of { code : int; output : string }
  | Command_failed of { code : int; output : string }
  | Signalled of { signal : int; output : string }
  | Stopped of { signal : int; output : string }

let ssh_config (server : Config_file.server) =
  match server.Config_file.ssh with
  | None -> Error (Not_configured { server = server.Config_file.ip_address })
  | Some ssh -> Ok ssh

(* The code ssh reserves for its own failures. A remote command exiting it is
   misclassified, and there is nothing in the code or the output that would
   separate the two -- see the interface, which says so where a caller reads. *)
let ssh_own_failure_code = 255

let failure_of_status status ~output =
  match status with
  | Unix.WEXITED 0 -> Ok output
  | Unix.WEXITED code when code = ssh_own_failure_code ->
      Error (Ssh_failed { code; output })
  | Unix.WEXITED code -> Error (Command_failed { code; output })
  | Unix.WSIGNALED signal -> Error (Signalled { signal; output })
  | Unix.WSTOPPED signal -> Error (Stopped { signal; output })

(* Which failures mean the host ran the command is one policy, and every caller
   that words a report around it was asking the same question of the same five
   arms. Asked here, beside the type, so that a sixth constructor is a compile
   error in one place rather than a silent fifth wording. *)
let ran_on_host = function
  | Command_failed _ -> true
  | Not_configured _
  | Ssh_failed _
  | Signalled _
  | Stopped _ ->
      false

let message = function
  | Not_configured { server } ->
      Printf.sprintf "Missing ssh configuration for server %s" server
  | Ssh_failed { code; output }
  | Command_failed { code; output } ->
      Printf.sprintf "command failed (%d): %s" code (String.trim output)
  | Signalled { signal; output } ->
      Printf.sprintf "command killed (%d): %s" signal (String.trim output)
  | Stopped { signal; output } ->
      Printf.sprintf "command stopped (%d): %s" signal (String.trim output)

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

(* Standard error is collected apart from standard output and merged into it
   only when the command failed. A failure is reported with whatever the command
   said about why, which is what the output stream alone cannot carry; a success
   is the host answering the question it was asked, and the warnings ssh and
   sudo write alongside that answer are not part of the answer. The callers that
   read these outputs read them by shape -- the first non-empty line of a
   container listing, a whole-output comparison against an expected port binding
   -- so a "Permanently added ... to the list of known hosts" ahead of the
   reading is read as the reading.

   Standard output is drained before standard error, so a command that fills the
   error pipe while this is still reading the output pipe would block. Nothing
   this client runs prints anything like a pipe buffer's worth of diagnostics,
   and the same order was what the two shapes this runner replaces used.

   [input] is written to the command's standard input rather than embedded in
   the command line, so that a payload carrying credentials never appears in
   argv on either machine. Nothing drains the command's output while the write
   is in flight, so callers must keep [input] small enough to fit the pipe
   buffer; an env file is a few hundred bytes.

   A call with nothing to feed writes nothing and closes, so the command on the
   far side reaches end of input at once. It is not handed this process's own
   standard input: a command on a deploy box has no business reading the
   operator's terminal, and the two shapes this runner replaces disagreed only
   because one of them was built on a spawn that had no input stream to give. *)

(* The process is reaped on every path out of [f], including one [f] leaves by
   raising -- a read that fails part-way is a child nobody waits on and three
   descriptors nobody closes, and setup opens this some thirty-four times per
   server. [Fun.protect] does not fit: the status is the value the caller needs
   and a [~finally] has nowhere to return it. The backtrace is taken before the
   close so that the fault reported is [f]'s own, at the place it happened. *)
let with_process cmd f =
  let channels = Unix.open_process_full cmd (Unix.environment ()) in
  match f channels with
  | value -> (Unix.close_process_full channels, value)
  | exception exn ->
      let backtrace = Printexc.get_raw_backtrace () in
      let (_ : Unix.process_status) = Unix.close_process_full channels in
      Printexc.raise_with_backtrace exn backtrace

let output_of_status status ~standard_output ~standard_error =
  match status with
  | Unix.WEXITED 0 -> standard_output
  | Unix.WEXITED _
  | Unix.WSIGNALED _
  | Unix.WSTOPPED _ ->
      standard_output ^ standard_error

let run_command ?input cmd =
  let status, (standard_output, standard_error) =
    with_process cmd (fun (from_command, to_command, from_command_errors) ->
        (* Writing to a command that has already exited raises SIGPIPE, which at
           its default disposition terminates this process before the status
           below can report anything. Ignoring it for the duration of the write
           is what turns that into the [Sys_error] the handler expects. Restored
           afterwards so the disposition is not changed program-wide. *)
        let previous_sigpipe = Sys.signal Sys.sigpipe Sys.Signal_ignore in
        Fun.protect
          ~finally:(fun () -> Sys.set_signal Sys.sigpipe previous_sigpipe)
          (fun () ->
            match input with
            | None -> ()
            | Some payload -> (
                (* The command may exit before reading its input, which closes
                   the pipe. That is reported by the status below, so the write
                   failing is not itself an error worth surfacing. *)
                try
                  output_string to_command payload;
                  flush to_command
                with
                | Sys_error _ -> ()));
        close_out_noerr to_command;
        let standard_output = read_all from_command in
        let standard_error = read_all from_command_errors in
        (standard_output, standard_error))
  in
  failure_of_status status
    ~output:(output_of_status status ~standard_output ~standard_error)

let decode_private_key contents =
  match Base64.decode contents with
  | Ok decoded -> decoded
  | Error _ -> contents

let with_temp_key contents f =
  let decoded = decode_private_key contents in
  let path = Filename.temp_file "bondi-key-" ".pem" in
  Fun.protect
    ~finally:(fun () ->
      (* A cleanup that finds nothing to remove is the file already having gone
         -- a sweeper, or an [f] that moved it -- and that is the outcome this
         wanted. Left to raise, [Fun.protect] turns it into
         [Fun.Finally_raised], which reports the cleanup and discards the fault
         the caller was about to be told about. *)
      try Sys.remove path with
      | Sys_error _ -> ())
    (fun () ->
      (* Opening is inside the protected region, so a file that was created and
         then could not be written to is still removed. *)
      let oc = open_out path in
      Fun.protect
        ~finally:(fun () -> close_out_noerr oc)
        (fun () ->
          output_string oc decoded;
          close_out oc;
          Unix.chmod path 0o600;
          f path))

(* A prompt is a wait with no deadline, and neither command that reads a host is
   attended by anyone who could answer one -- hence the two that were always
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
     (* A directory that has already gone, or one this process may no longer
        write to, is the outcome the cleanup wanted; anything else -- an
        [Out_of_memory] on the way out, an interrupt -- is not the cleanup's to
        swallow, so the two the filesystem raises are named rather than
        everything. *)
     at_exit (fun () ->
         (try
            Array.iter
              (fun f ->
                try Unix.unlink (Filename.concat dir f) with
                | Unix.Unix_error _
                | Sys_error _ ->
                    ())
              (Sys.readdir dir)
          with
         | Unix.Unix_error _
         | Sys_error _ ->
             ());
         try Unix.rmdir dir with
         | Unix.Unix_error _
         | Sys_error _ ->
             ());
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

let ssh_command ~user ~host ~key_path cmd =
  let destination = user ^ "@" ^ host in
  Printf.sprintf "ssh -i %s %s %s %s -- %s" (Filename.quote key_path)
    (String.concat " " ssh_options)
    (String.concat " " (multiplex_options ()))
    (Filename.quote destination)
    (Filename.quote cmd)

let command_output ?input ~command (server : Config_file.server) =
  let* ssh = ssh_config server in
  with_temp_key ssh.Config_file.private_key_contents (fun key_path ->
      run_command ?input
        (ssh_command ~user:ssh.Config_file.user ~host:server.ip_address
           ~key_path command))

let docker_command_output ?input ~command server =
  command_output ?input ~command:("docker " ^ command) server

let command_output_text ?input ~command server =
  Result.map_error message (command_output ?input ~command server)

let docker_command_output_text ?input ~command server =
  Result.map_error message (docker_command_output ?input ~command server)
