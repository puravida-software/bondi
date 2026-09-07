let ( let* ) = Result.bind

(* -L binds the local end to 127.0.0.1 explicitly rather than to whatever
   GatewayPorts happens to be: a forward that lands on 0.0.0.0 would re-publish
   the orchestrator on the CI runner's own public interface, which is the exact
   exposure the loopback bind exists to remove, moved one machine to the left.

   ExitOnForwardFailure is load-bearing. Without it ssh stays up when the local
   port is already taken, and the caller gets "connection refused" from its own
   machine while a healthy-looking ssh process sits there -- a failure that
   reads as the remote box being down. *)
let tunnel_command ~key_path ~user ~host ~local_port ~remote_port =
  Printf.sprintf
    "ssh -i %s %s -o ExitOnForwardFailure=yes -N -L %d:127.0.0.1:%d %s"
    (Filename.quote key_path)
    (String.concat " " Remote_exec.ssh_options)
    local_port remote_port
    (Filename.quote (user ^ "@" ^ host))

let free_local_port () =
  let s = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Fun.protect
    ~finally:(fun () -> Unix.close s)
    (fun () ->
      Unix.bind s (Unix.ADDR_INET (Unix.inet_addr_loopback, 0));
      match Unix.getsockname s with
      | Unix.ADDR_INET (_, port) -> Ok port
      | Unix.ADDR_UNIX path ->
          Error
            (Printf.sprintf
               "ssh tunnel could not reserve a local port: the kernel named an \
                internet socket %s"
               path))

let port_accepts port =
  let s = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Fun.protect
    ~finally:(fun () ->
      try Unix.close s with
      | _ -> ())
    (fun () ->
      try
        Unix.connect s (Unix.ADDR_INET (Unix.inet_addr_loopback, port));
        true
      with
      | Unix.Unix_error _ -> false)

(* Readiness is confirmed, not waited out: ssh forks and returns before the
   forward is usable, so posting immediately races the tunnel and fails
   intermittently. Ten seconds at 100ms is well past a normal handshake and
   short enough that a wrong key reports quickly. *)
let readiness_attempts = 100
let readiness_interval = 0.1

(* One function in this client reads a process status, and it is not this one:
   the classification is [Remote_exec.failure_of_status] and only the wording is
   the tunnel's. The wording stays because it names the tunnel -- an operator
   shown "command failed (255)" in the middle of a deploy cannot tell a forward
   that never opened from the deploy itself failing.

   There is no output to hand the classifier: [-N] runs no command, and ssh's
   own diagnostics go straight to this process's stderr rather than through a
   pipe this module reads. *)
let early_exit_message status =
  let exited code =
    Printf.sprintf
      "ssh tunnel exited with status %d before the forward was usable -- check \
       the key and that port 22 is reachable"
      code
  in
  let killed = "ssh tunnel was killed before the forward was usable" in
  match Remote_exec.failure_of_status status ~output:"" with
  (* Exit 0 is the classifier's success and the tunnel's failure: [-N] gave ssh
     nothing to do but hold the forward open, so leaving at all is leaving too
     early. Nothing else reaches this arm, so the code is 0. *)
  | Ok _ -> exited 0
  | Error (Remote_exec.Ssh_failed { code; _ })
  | Error (Remote_exec.Command_failed { code; _ }) ->
      exited code
  | Error (Remote_exec.Signalled _)
  | Error (Remote_exec.Stopped _) ->
      killed
  (* Not reachable from a status -- [ssh_config] is its only producer -- and
     rendered by the module that owns it rather than given a tunnel sentence
     that would be untrue if it ever arrived. *)
  | Error (Remote_exec.Not_configured _ as failure) ->
      Remote_exec.message failure

let wait_until_ready ~port ~pid =
  let rec go attempt =
    if port_accepts port then Ok ()
    else if attempt >= readiness_attempts then
      Error
        (Printf.sprintf
           "ssh tunnel on local port %d did not become ready within %.0fs" port
           (float_of_int readiness_attempts *. readiness_interval))
    else
      (* An ssh that has already exited will never become ready, and its exit is
         the useful error -- a bad key or an unreachable host lands here. *)
      match Unix.waitpid [ Unix.WNOHANG ] pid with
      | 0, _ ->
          Unix.sleepf readiness_interval;
          go (attempt + 1)
      | _, status -> Error (early_exit_message status)
  in
  go 0

let with_tunnel ~(ssh : Config_file.server_ssh) ~host ~remote_port f =
  Remote_exec.with_temp_key ssh.private_key_contents (fun key_path ->
      let* local_port = free_local_port () in
      let cmd =
        tunnel_command ~key_path ~user:ssh.user ~host ~local_port ~remote_port
      in
      let pid =
        Unix.create_process "/bin/sh" [| "/bin/sh"; "-c"; cmd |] Unix.stdin
          Unix.stdout Unix.stderr
      in
      let shutdown () =
        (try Unix.kill pid Sys.sigterm with
        | Unix.Unix_error _ -> ());
        try ignore (Unix.waitpid [] pid) with
        | Unix.Unix_error _ -> ()
      in
      (* Fun.protect so an exception from [f] tears the tunnel down too. A
         leaked ssh holds the forward open for the life of the process, which on
         a self-hosted runner is the life of the job. *)
      Fun.protect ~finally:shutdown (fun () ->
          let* () = wait_until_ready ~port:local_port ~pid in
          f local_port))
