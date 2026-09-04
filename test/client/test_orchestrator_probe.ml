open Alcotest
module Probe = Bondi_client.Orchestrator_probe
module Remote_exec = Bondi_client.Remote_exec

let contains = Test_helpers.contains

(* The defect this module exists to prevent: `docker run -d` answers with a
   container id as soon as the container is created, which says nothing about
   whether the process inside survived. A readiness check that reads a
   successful SSH exit as a healthy server reproduces exactly that, so the only
   thing that counts as serving is the marker the probe prints after the health
   endpoint has answered. *)
let test_verdict_accepts_only_the_serving_marker () =
  match Probe.verdict (Ok "BONDI_ORCHESTRATOR_SERVING\n") with
  | Ok () -> ()
  | Error message -> fail ("expected the marker to be accepted: " ^ message)

let test_verdict_rejects_unreachable_marker () =
  match Probe.verdict (Ok "BONDI_ORCHESTRATOR_UNREACHABLE\n") with
  | Ok () -> fail "expected an unreachable orchestrator to be rejected"
  | Error message ->
      check bool "names the health endpoint" true
        (contains ~needle:"/api/v1/health" message)

(* A remote command that produced no output at all is not evidence of a healthy
   server. This is the arm that would silently pass if the check were "the SSH
   call succeeded". *)
let test_verdict_rejects_silent_success () =
  match Probe.verdict (Ok "") with
  | Ok () -> fail "expected empty probe output to be rejected"
  | Error message ->
      check bool "reports what the server said" true
        (contains ~needle:"answered" message)

(* The probe exits non-zero when the orchestrator never answers, so the SSH
   layer reports it as an error rather than as output. That must be a rejection
   carrying the failure, not a crash and not a pass. *)
let test_verdict_rejects_failed_probe () =
  match
    Probe.verdict
      (Error
         (Remote_exec.Command_failed { code = 1; output = "no such container" }))
  with
  | Ok () -> fail "expected a failed probe to be rejected"
  | Error message ->
      check bool "carries the underlying failure" true
        (contains ~needle:"no such container" message)

(* The two failures an operator resolves in different places. A host that could
   not be reached is a key, an address or a firewall; a host that ran the check
   and reported a non-zero exit is the box itself. Rendering both as "the check
   could not be run on the server" states the first about the second, and no
   reader of the sentence can tell which they have. *)
let test_ssh_failure_and_command_failure_reach_different_verdicts () =
  let unreached =
    Probe.verdict
      (Error
         (Remote_exec.Ssh_failed
            { code = 255; output = "Connection closed by 10.0.0.1 port 22" }))
  in
  let answered =
    Probe.verdict
      (Error
         (Remote_exec.Command_failed { code = 1; output = "no such container" }))
  in
  match (unreached, answered) with
  | Error unreached, Error answered ->
      check bool "a host that was never reached says the check did not run" true
        (contains ~needle:"could not be run on the server" unreached);
      check bool "a host that ran the check does not say that" false
        (contains ~needle:"could not be run on the server" answered);
      check bool "it says the check ran and failed instead" true
        (contains ~needle:"ran on the server" answered);
      check bool "and each still carries what came back" true
        (contains ~needle:"Connection closed" unreached
        && contains ~needle:"no such container" answered)
  | Ok (), _ -> fail "a host that could not be reached is not a serving server"
  | Error _, Ok () ->
      fail "a probe that failed on the host is not a serving server"

(* The probe checks that the server answers HTTP on the port it was told to
   check, rather than that a container exists — a container whose process died
   is exactly the case that used to report success. *)
let test_probe_command_checks_the_health_endpoint () =
  let command = Probe.probe_command ~port:3030 ~attempts:30 in
  check bool "requests the health endpoint" true
    (contains ~needle:"http://127.0.0.1:3030/api/v1/health" command);
  check bool "targets the orchestrator container" true
    (contains ~needle:"bondi-orchestrator" command)

(* What made the outage undiagnosable was that the operator was told nothing.
   The message has to carry the server's own account of the failure. *)
let test_failure_message_carries_the_diagnostics () =
  let message =
    Probe.failure_message ~ip_address:"46.225.53.162"
      ~image:"mlopez1506/bondi-server:0.10.1"
      ~reason:"the container did not answer GET /api/v1/health"
      ~diagnostics:
        "exited exit=127\n\
         Error loading shared library libzstd.so.1: No such file or directory"
  in
  check bool "names the server" true (contains ~needle:"46.225.53.162" message);
  check bool "names the image" true
    (contains ~needle:"mlopez1506/bondi-server:0.10.1" message);
  check bool "carries the exit code" true (contains ~needle:"exit=127" message);
  check bool "carries the loader error" true
    (contains ~needle:"libzstd.so.1" message)

let () =
  run "Orchestrator_probe"
    [
      ( "verdict",
        [
          test_case "accepts the serving marker" `Quick
            test_verdict_accepts_only_the_serving_marker;
          test_case "rejects an orchestrator that never answered" `Quick
            test_verdict_rejects_unreachable_marker;
          test_case "rejects a probe that produced no output" `Quick
            test_verdict_rejects_silent_success;
          test_case "rejects a probe that could not be run" `Quick
            test_verdict_rejects_failed_probe;
          test_case "an unreachable host and a failed check are not one verdict"
            `Quick test_ssh_failure_and_command_failure_reach_different_verdicts;
        ] );
      ( "probe_command",
        [
          test_case "checks the health endpoint on the given port" `Quick
            test_probe_command_checks_the_health_endpoint;
        ] );
      ( "failure_message",
        [
          test_case "carries the server's own diagnostics" `Quick
            test_failure_message_carries_the_diagnostics;
        ] );
    ]
