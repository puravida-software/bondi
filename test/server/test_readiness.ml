open Alcotest
module Readiness = Bondi_server__Readiness
module Handler_error = Bondi_server__Handler_error
module String_utils = Bondi_common.String_utils

(* An observation list is the one thing the compiler cannot check for
   completeness, so the probe set is named arm by arm here. A probe added to the
   variant later makes this [function] inexhaustive in this file, which is where
   the missing coverage would otherwise have gone unnoticed. *)
let probe_name = function
  | Readiness.Docker_socket -> "docker socket"
  | Readiness.Crontab_spool -> "crontab spool"
  | Readiness.Diagnostic_sink -> "diagnostic sink"

let passing probe = { Readiness.probe; outcome = Ok () }
let failing probe reason = { Readiness.probe; outcome = Error reason }

let is_ready = function
  | Readiness.Ready -> true
  | Readiness.Not_ready _ -> false

(* The verdict is compared through the names of the probes it reports rather
   than through a structural equality on the verdict itself: what the operator
   is owed is which probes failed, and a comparison on names fails with that
   list printed rather than with a record dump. *)
let failing_probe_names = function
  | Readiness.Ready -> []
  | Readiness.Not_ready observations ->
      List.map
        (fun (observation : Readiness.observation) ->
          probe_name observation.probe)
        observations

let test_all_probes_passing_is_ready () =
  let verdict =
    Readiness.plan
      [
        passing Readiness.Docker_socket;
        passing Readiness.Crontab_spool;
        passing Readiness.Diagnostic_sink;
      ]
  in
  check bool "every probe returned Ok, so the box is ready" true
    (is_ready verdict);
  check (list string) "a ready verdict carries no failing probe" []
    (failing_probe_names verdict)

let test_a_failing_probe_is_not_ready () =
  let verdict =
    Readiness.plan
      [
        passing Readiness.Docker_socket;
        failing Readiness.Crontab_spool "the spool directory is not writable";
        passing Readiness.Diagnostic_sink;
      ]
  in
  check bool "one failing probe is enough to withhold ready" false
    (is_ready verdict);
  check (list string) "the verdict names the probe that failed and no other"
    [ "crontab spool" ]
    (failing_probe_names verdict)

(* A box with two faults that reports one costs a second trip to a machine the
   operator had to reach, so the verdict carries every failing probe. A [plan]
   that stops at the first failure passes the case above and fails here. *)
let test_every_failing_probe_is_reported () =
  let verdict =
    Readiness.plan
      [
        failing Readiness.Docker_socket "the docker socket cannot be opened";
        passing Readiness.Crontab_spool;
        failing Readiness.Diagnostic_sink
          "the diagnostic sink cannot be written";
      ]
  in
  check (list string) "both failures are named, in the order observed"
    [ "docker socket"; "diagnostic sink" ]
    (failing_probe_names verdict);
  match Readiness.error_of_verdict verdict with
  | None -> fail "a not-ready verdict must produce an error"
  | Some error ->
      let message = Handler_error.message error in
      check bool "the message names the socket failure" true
        (String_utils.contains ~needle:"the docker socket cannot be opened"
           message);
      check bool "the message names the sink failure" true
        (String_utils.contains ~needle:"the diagnostic sink cannot be written"
           message)

(* The [None] arm is an assertion of absence, so the same probe set is run again
   with one probe failing. Without that arm a [error_of_verdict] that answered
   [None] for everything would pass. *)
let test_ready_produces_no_error () =
  let ready =
    Readiness.plan
      [ passing Readiness.Docker_socket; passing Readiness.Diagnostic_sink ]
  in
  check bool "a ready verdict produces no error" true
    (Option.is_none (Readiness.error_of_verdict ready));
  let not_ready =
    Readiness.plan
      [
        failing Readiness.Docker_socket "the docker socket cannot be opened";
        passing Readiness.Diagnostic_sink;
      ]
  in
  check bool "the same probe set with one failure does produce an error" true
    (Option.is_some (Readiness.error_of_verdict not_ready))

(* The verdict on stdout is a wire contract: the subcommand's bytes are read by
   a script, so the field names and their order are asserted as bytes rather
   than by re-encoding through the same function. The keys are the probe
   constructors in snake_case -- the operator-facing names ("crontab spool")
   belong in the message on stderr, where a human is reading them. *)
let encoded observations =
  Yojson.Safe.to_string (Readiness.observations_to_yojson observations)

let test_a_ready_observation_list_encodes_every_probe () =
  check string "ready is true and every probe taken is named"
    {|{"ready":true,"probes":[{"name":"docker_socket","ok":true},{"name":"crontab_spool","ok":true},{"name":"diagnostic_sink","ok":true}]}|}
    (encoded
       [
         passing Readiness.Docker_socket;
         passing Readiness.Crontab_spool;
         passing Readiness.Diagnostic_sink;
       ])

(* The failing document is the one a program acts on, and [check] emits it:
   [Cmd_io.diagnostic_of] writes the document on both arms and leaves the prose
   to stderr. This pins the bytes of that arm -- ready is false and every failing
   probe carries its own reason -- as a wire contract, the same way the passing
   arm above is pinned. The spool probe is absent here rather than reported as
   passing, which is what a deployment without cron produces. *)
let test_a_failing_observation_carries_its_reason () =
  check string "ready is false and the failing probe carries its reason"
    {|{"ready":false,"probes":[{"name":"docker_socket","ok":true},{"name":"diagnostic_sink","ok":false,"reason":"/proc/1/fd/2: Permission denied"}]}|}
    (encoded
       [
         passing Readiness.Docker_socket;
         failing Readiness.Diagnostic_sink "/proc/1/fd/2: Permission denied";
       ])

let () =
  run "readiness"
    [
      ( "verdict",
        [
          test_case "all probes passing is ready" `Quick
            test_all_probes_passing_is_ready;
          test_case "a failing probe is not ready" `Quick
            test_a_failing_probe_is_not_ready;
          test_case "every failing probe is reported, not the first" `Quick
            test_every_failing_probe_is_reported;
          test_case "ready produces no error" `Quick
            test_ready_produces_no_error;
        ] );
      ( "verdict json",
        [
          test_case "a ready observation list encodes every probe" `Quick
            test_a_ready_observation_list_encodes_every_probe;
          test_case "a failing observation carries its reason" `Quick
            test_a_failing_observation_carries_its_reason;
        ] );
    ]
