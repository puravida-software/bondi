open Alcotest
module Docker = Bondi_client.Docker_common

let contains = Test_helpers.contains

(* The report exists to be printed on exactly the runs that go wrong, and both
   commands that print one read the host over SSH first. A host that accepts the
   TCP connection and then stops answering — a firewall that drops rather than
   refuses, a box that is wedged rather than down — leaves [ssh] waiting with no
   deadline of its own, so the report is lost on one of the failures it exists
   to describe.

   The HTTP source was given a bound for this reason. This is the same bound on
   the source the report needs more: FR-3 makes the host read sufficient on its
   own, and there are several of them per server plus one per container waited
   on. *)
let test_ssh_options_bound_a_host_that_stops_answering () =
  let options = String.concat " " Docker.ssh_options in
  check bool "gives up on a connection that is never established" true
    (contains ~needle:"ConnectTimeout=" options);
  check bool "and on one that is established and then goes quiet" true
    (contains ~needle:"ServerAliveInterval=" options);
  check bool "after a bounded number of unanswered probes" true
    (contains ~needle:"ServerAliveCountMax=" options)

(* The options that were already there and are load-bearing for a different
   reason: a prompt is a wait with no deadline at all, and neither command that
   reads a host is attended by anyone who could answer one. *)
let test_ssh_options_never_prompt () =
  let options = String.concat " " Docker.ssh_options in
  check bool "never asks for a password" true
    (contains ~needle:"BatchMode=yes" options);
  check bool "never asks about an unknown host key" true
    (contains ~needle:"StrictHostKeyChecking=" options)

let () =
  run "Docker_common"
    [
      ( "ssh options",
        [
          test_case "bound a host that stops answering" `Quick
            test_ssh_options_bound_a_host_that_stops_answering;
          test_case "never wait on a prompt" `Quick
            test_ssh_options_never_prompt;
        ] );
    ]
