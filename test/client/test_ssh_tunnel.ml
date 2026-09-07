open Alcotest
module Ssh_tunnel = Bondi_client.Ssh_tunnel

let contains ~needle s = Bondi_common.String_utils.contains ~needle s

let cmd () =
  Ssh_tunnel.tunnel_command ~key_path:"/tmp/k.pem" ~user:"root"
    ~host:"203.0.113.7" ~local_port:54321 ~remote_port:3030

(* The local end must be pinned to 127.0.0.1. A forward that lands on 0.0.0.0 --
   which is what a host with GatewayPorts=yes would give -- republishes the
   orchestrator on the CI runner's own public interface, recreating the exposure
   one machine to the left. *)
let test_local_end_is_loopback () =
  check bool "binds local end to loopback" true
    (contains ~needle:"-L 54321:127.0.0.1:3030" (cmd ()))

(* Without this, ssh stays up when the local port is taken and the caller sees
   "connection refused" from its own machine -- which reads as the remote box
   being down. *)
let test_exit_on_forward_failure () =
  check bool "ExitOnForwardFailure" true
    (contains ~needle:"-o ExitOnForwardFailure=yes" (cmd ()))

let test_no_remote_command () =
  check bool "-N, no remote command" true (contains ~needle:" -N " (cmd ()))

let test_uses_the_key () =
  check bool "identity file" true (contains ~needle:"-i '/tmp/k.pem'" (cmd ()))

(* BatchMode in particular: a tunnel that stops to ask for a passphrase in CI
   hangs the job until the step times out. *)
let test_shares_client_ssh_options () =
  let c = cmd () in
  check bool "BatchMode" true (contains ~needle:"BatchMode=yes" c);
  check bool "ConnectTimeout" true (contains ~needle:"ConnectTimeout=10" c)

let test_destination_is_quoted () =
  check bool "user@host quoted" true
    (contains ~needle:"'root@203.0.113.7'" (cmd ()))

let free_port () =
  match Ssh_tunnel.free_local_port () with
  | Ok port -> port
  | Error e -> fail e

let test_free_port_is_usable () =
  let p = free_port () in
  check bool "in the ephemeral range" true (p > 1024 && p < 65536);
  (* and actually bindable, which is the property the caller depends on *)
  let s = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Fun.protect
    ~finally:(fun () -> Unix.close s)
    (fun () ->
      Unix.bind s (Unix.ADDR_INET (Unix.inet_addr_loopback, p));
      check bool "bindable" true true)

let test_free_ports_differ () =
  (* Two calls handing back the same port would make concurrent deploys on one
     runner collide -- and the fleet runs 16 agents on one box. *)
  let a = free_port () in
  let s = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Fun.protect
    ~finally:(fun () -> Unix.close s)
    (fun () ->
      Unix.bind s (Unix.ADDR_INET (Unix.inet_addr_loopback, a));
      let b = free_port () in
      check bool "does not hand out a bound port" true (a <> b))

let killed = "ssh tunnel was killed before the forward was usable"

(* The sentence names the tunnel. An operator shown only the shared rendering --
   "command failed (255)" -- cannot tell a forward that never opened from the
   deploy the forward exists to carry. *)
let test_exit_status_is_reported () =
  let m = Ssh_tunnel.early_exit_message (Unix.WEXITED 7) in
  check bool "names the tunnel" true (contains ~needle:"ssh tunnel" m);
  check bool "carries the status" true (contains ~needle:"status 7" m);
  check bool "says where to look" true (contains ~needle:"check the key" m)

(* 255 is the code ssh reserves for its own failures, which Remote_exec
   classifies apart from a remote exit. The tunnel reports the number either
   way: for a forward there is no remote command whose code it could be. *)
let test_ssh_own_failure_code_is_reported () =
  check bool "carries 255" true
    (contains ~needle:"status 255"
       (Ssh_tunnel.early_exit_message (Unix.WEXITED 255)))

(* An ssh that exits cleanly before the forward answers has still failed: -N
   means it had nothing to do but hold the forward open. *)
let test_clean_exit_is_still_a_failure () =
  check bool "carries 0" true
    (contains ~needle:"status 0"
       (Ssh_tunnel.early_exit_message (Unix.WEXITED 0)))

let test_signalled_reads_as_killed () =
  check string "killed" killed
    (Ssh_tunnel.early_exit_message (Unix.WSIGNALED Sys.sigterm))

let test_stopped_reads_as_killed () =
  check string "killed" killed
    (Ssh_tunnel.early_exit_message (Unix.WSTOPPED Sys.sigstop))

(* An unreachable host must fail as an error rather than hang: the readiness
   loop watches the ssh child, so its exit is reported instead of waited out.
   Port 1 on the discard-ish loopback address refuses immediately. *)
let test_unreachable_host_errors () =
  let ssh : Bondi_client.Config_file.server_ssh =
    {
      user = "nobody";
      private_key_contents = "not-a-key";
      private_key_pass = "";
    }
  in
  match
    Ssh_tunnel.with_tunnel ~ssh ~host:"127.0.0.1" ~remote_port:1 (fun _ ->
        Ok "should not be reached")
  with
  | Ok _ -> fail "expected the tunnel to fail against an unusable host"
  | Error msg ->
      check bool "explains itself" true (contains ~needle:"ssh tunnel" msg)

let () =
  run "ssh tunnel"
    [
      ( "command",
        [
          test_case "local end is loopback" `Quick test_local_end_is_loopback;
          test_case "ExitOnForwardFailure" `Quick test_exit_on_forward_failure;
          test_case "no remote command" `Quick test_no_remote_command;
          test_case "uses the key" `Quick test_uses_the_key;
          test_case "shares client ssh options" `Quick
            test_shares_client_ssh_options;
          test_case "destination quoted" `Quick test_destination_is_quoted;
        ] );
      ( "local port",
        [
          test_case "usable" `Quick test_free_port_is_usable;
          test_case "not already bound" `Quick test_free_ports_differ;
        ] );
      ( "failure",
        [
          test_case "exit status is reported" `Quick
            test_exit_status_is_reported;
          test_case "ssh's own failure code is reported" `Quick
            test_ssh_own_failure_code_is_reported;
          test_case "clean exit is still a failure" `Quick
            test_clean_exit_is_still_a_failure;
          test_case "signalled reads as killed" `Quick
            test_signalled_reads_as_killed;
          test_case "stopped reads as killed" `Quick
            test_stopped_reads_as_killed;
          test_case "unreachable host errors" `Quick
            test_unreachable_host_errors;
        ] );
    ]
