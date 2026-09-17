open Alcotest
module Setup = Bondi_client.Cmd.Setup
module Setup_phases = Bondi_client.Setup_phases
module Host_answer = Bondi_client.Host_answer
module Managed_container = Bondi_common.Managed_container

let spec =
  match
    Managed_container.create ~name:"gateway" ~image:"example.com/ib-gateway"
      ~tag:"10.48.1e" ~restart:Managed_container.Unless_stopped
      ~network:(Some Bondi_common.Defaults.network_name) ~ports:[] ~env:[]
  with
  | Ok spec -> spec
  | Error error -> failwith (Managed_container.error_to_string error)

let phase_string = function
  | Setup_phases.Docker -> "Docker"
  | Setup_phases.Network -> "Network"
  | Setup_phases.Cron_docker -> "Cron_docker"
  | Setup_phases.Cron_curl -> "Cron_curl"
  | Setup_phases.Acme -> "Acme"
  | Setup_phases.Orchestrator -> "Orchestrator"
  | Setup_phases.Alloy -> "Alloy"
  | Setup_phases.Managed -> "Managed"

let phase action = Setup.phase_of_action action
let phases actions = List.map phase actions
let contains = Test_helpers.contains

(* ------------------------------------------------------------------------- *)
(* Which phase an action belongs to                                          *)
(* ------------------------------------------------------------------------- *)

(* Every constructor of [action] appears here. A new one is a compile error in
   [phase_of_action], which is where the phase is chosen; naming it here is what
   pins which phase it was given. *)
let test_phase_of_each_action_is_named () =
  let cases =
    [
      (Setup.EnsureDocker, "Docker");
      (Setup.EnsureNetwork "bondi-network", "Network");
      (Setup.RequireCronDocker, "Cron_docker");
      (Setup.RequireCronCurl, "Cron_curl");
      (Setup.EnsureAcmeFile, "Acme");
      (Setup.StopOrchestrator, "Orchestrator");
      (Setup.RemoveOrchestrator, "Orchestrator");
      (Setup.RunServer, "Orchestrator");
      (Setup.EnsureAlloyConfig, "Alloy");
      (Setup.WriteAlloyEnv, "Alloy");
      (Setup.RunAlloy, "Alloy");
      (Setup.StopAlloy, "Alloy");
      (Setup.RemoveAlloy, "Alloy");
      (Setup.CleanAlloyConfig, "Alloy");
      (Setup.WriteManagedEnv spec, "Managed");
      (Setup.RunManaged spec, "Managed");
      (Setup.StopManaged "gateway", "Managed");
      (Setup.RemoveManaged "gateway", "Managed");
      (Setup.CleanManagedConfig "gateway", "Managed");
    ]
  in
  check (list string) "phase of every action" (List.map snd cases)
    (List.map (fun (action, _expected) -> phase_string (phase action)) cases)

(* ------------------------------------------------------------------------- *)
(* What a mid-plan failure left unrun                                        *)
(* ------------------------------------------------------------------------- *)

(* The case the incident produced: a bondi-alloy that could not be started stops
   the run, and the declared managed containers after it are never converged.
   [plan] emits alloy ahead of managed, which
   [test_setup_plan_ensure_network_precedes_joining_actions] pins against a real
   plan (RunServer, RunAlloy, RunManaged in that order). *)
let test_unfinished_phases_after_a_mid_plan_failure () =
  check (list string) "phases that did not run" [ "Managed" ]
    (List.map phase_string
       (Setup_phases.unfinished_phases ~failed:(phase Setup.RunAlloy)
          ~remaining:
            (phases [ Setup.WriteManagedEnv spec; Setup.RunManaged spec ])))

(* Several actions share a phase, and the operator wants the phase named once.
   The failing phase is not among them: it is reported as the phase the run
   stopped in, and repeating it as "did not run" would say the opposite of what
   half-applied means. *)
let test_unfinished_phases_are_deduplicated_in_plan_order () =
  let remaining =
    [
      Setup.RemoveOrchestrator;
      Setup.RunServer;
      Setup.StopAlloy;
      Setup.RemoveAlloy;
      Setup.EnsureAlloyConfig;
      Setup.RunAlloy;
      Setup.WriteManagedEnv spec;
      Setup.RunManaged spec;
      Setup.StopManaged "old";
      Setup.RemoveManaged "old";
      Setup.CleanManagedConfig "old";
    ]
  in
  check (list string) "each later phase once, in plan order"
    [ "Alloy"; "Managed" ]
    (List.map phase_string
       (Setup_phases.unfinished_phases
          ~failed:(phase Setup.StopOrchestrator)
          ~remaining:(phases remaining)))

(* The affirmative arm for this emptiness is
   [test_unfinished_phases_after_a_mid_plan_failure]: the same failing action,
   differing only in what was left, reports a phase. So an empty answer here is
   the end of the plan rather than a function that reports nothing. *)
let test_unfinished_phases_is_empty_when_the_last_action_fails () =
  check (list string) "nothing after the last action" []
    (List.map phase_string
       (Setup_phases.unfinished_phases ~failed:(phase Setup.RunAlloy)
          ~remaining:(phases [])))

(* ------------------------------------------------------------------------- *)
(* The operator-facing report                                                *)
(* ------------------------------------------------------------------------- *)

let test_failure_message_names_the_failing_phase_and_the_skipped_ones () =
  let reason =
    "command failed (125): docker: Error response from daemon: Conflict. The \
     container name \"/bondi-alloy\" is already in use"
  in
  let message =
    Setup_phases.failure_message ~server:"10.0.0.1"
      ~failed:(phase Setup.RunAlloy)
      ~remaining:(phases [ Setup.WriteManagedEnv spec; Setup.RunManaged spec ])
      ~reason
  in
  check bool "carries the host's own account" true
    (contains ~needle:reason message);
  check bool "names the phase the run stopped in" true
    (contains ~needle:"alloy phase" message);
  (* [run ()] prints every server's failure together at the end of a multi-server
     run, far from the "Processing server" line, so a report that does not name
     its host is one an operator has to scroll to attribute. *)
  check bool "names the server it happened on" true
    (contains ~needle:"10.0.0.1" message);
  check bool "names the phase that did not run" true
    (contains ~needle:"managed containers" message);
  (* The affirmative arm for the absence asserted below: the same phrase this
     fixture must not produce when nothing was left, it must produce when
     something was. Without it a wording change in both branches would leave the
     absence passing while the report said nothing at all. *)
  check bool "says which phases did not run" true
    (contains ~needle:"did not run" message);
  (* Same fixture, nothing left to run: the report must not name a phase that
     was never skipped, or the list above would read as boilerplate. *)
  let last =
    Setup_phases.failure_message ~server:"10.0.0.1"
      ~failed:(phase Setup.RunAlloy) ~remaining:(phases []) ~reason
  in
  check bool "still carries the host's own account" true
    (contains ~needle:reason last);
  check bool "still names the phase the run stopped in" true
    (contains ~needle:"alloy phase" last);
  check bool "still names the server it happened on" true
    (contains ~needle:"10.0.0.1" last);
  check bool "claims no skipped phase" false
    (contains ~needle:"did not run" last)

(* ------------------------------------------------------------------------- *)
(* What a run says it corrected                                              *)
(* ------------------------------------------------------------------------- *)

let alloy_config_path = "/etc/bondi/alloy/config.alloy"

(* One correction per site, so that a site's own constructor is what is asked
   about it rather than one correction standing in for both. Neither takes the
   file or the container it is about: the subject is the site's own, derived
   where the line is worded, so there is no parameter here for a declared value
   to arrive through. *)
let correction_of_site = function
  | Setup_phases.Alloy_config_mode ->
      Setup_phases.config_mode_corrected
        ~found:(Host_answer.of_host_output "0644")
        ~applied:"0640"
  | Setup_phases.Orchestrator_restart_policy ->
      Setup_phases.restart_policy_corrected
        ~found:(Host_answer.of_host_output "no")
        ~applied:"unless-stopped"

let rendered ~server corrections =
  String.concat "\n" (Setup_phases.corrections_report ~server corrections)

(* Both values and the server, on both sites: a line that names only what was
   applied is the reassurance this account exists to replace, and a
   multi-server run prints every server's account together, far from the line
   that announced which server was being processed. *)
let test_corrections_report_names_what_was_found_and_applied () =
  let corrections =
    [
      correction_of_site Setup_phases.Alloy_config_mode;
      correction_of_site Setup_phases.Orchestrator_restart_policy;
    ]
  in
  let lines = Setup_phases.corrections_report ~server:"10.0.0.1" corrections in
  check int "one line per correction" 2 (List.length lines);
  let report = String.concat "\n" lines in
  check bool "names the file it corrected" true
    (contains ~needle:alloy_config_path report);
  check bool "names the mode the host had and the mode applied" true
    (contains ~needle:"was mode 0644, applied 0640" report);
  check bool "names the container it corrected" true
    (contains ~needle:"bondi-orchestrator" report);
  check bool "names the policy the host had and the policy applied" true
    (contains ~needle:"was restart policy no, applied unless-stopped" report);
  check bool "names the server both are about" true
    (contains ~needle:"on server 10.0.0.1" report);
  (* The absence arm of the pair below: a run that corrected something must not
     also claim it corrected nothing. *)
  check bool "claims nothing about a run that corrected nothing" false
    (contains ~needle:"corrected nothing" report)

(* An empty account and an account never taken must not read alike. The
   affirmative arm is the test above, on the same server, so an empty answer
   here is a run with nothing to say rather than a function that says
   nothing. *)
let test_corrections_report_says_nothing_diverged_when_empty () =
  let lines = Setup_phases.corrections_report ~server:"10.0.0.1" [] in
  check int "one line, not none" 1 (List.length lines);
  let report = String.concat "\n" lines in
  check bool "says the run corrected nothing" true
    (contains ~needle:"corrected nothing" report);
  check bool "names the server it is about" true
    (contains ~needle:"10.0.0.1" report);
  (* This sentence is printed by every converged run, including the runs whose
     cram fixtures assert that neither site reported anything --
     test/cram/setup_orchestrator.t greps for "restart policy" expecting none of
     it, and test/cram/setup_alloy_stopped.t for a mode reading. A sentence
     carrying either reading turns both of those assertions into their
     opposite while they still pass. *)
  check bool "carries no reading of the restart policy" false
    (contains ~needle:"restart policy" report);
  check bool "carries no reading of a mode" false
    (contains ~needle:"mode" report)

(* A reading nobody could take is the account's other kind of line, and it is a
   line of the same account: worded here, naming the server here, printed in the
   same block. Where it used to be written was mid-transcript, which is where a
   line goes missing on the run that stops two phases later -- the readability
   defect the block exists to remove, applied to a line the account's own
   machinery produced.

   It corrects nothing, and the run still says so. A register that dropped the
   nothing-corrected sentence as soon as it held any line at all would report a
   run that could not look as one that repaired something. *)
let test_an_unreadable_reading_is_reported_and_corrects_nothing () =
  let lines =
    Setup_phases.corrections_report ~server:"10.0.0.1"
      [
        Setup_phases.unreadable_reading ~site:Setup_phases.Alloy_config_mode
          ~detail:"the host reported nothing";
      ]
  in
  let report = String.concat "\n" lines in
  check bool "says which reading it could not take" true
    (contains ~needle:"could not read the mode" report);
  check bool "names the file the reading was about" true
    (contains ~needle:alloy_config_path report);
  check bool "names the server it could not read it on" true
    (contains ~needle:"on server 10.0.0.1" report);
  check bool "carries the caller's account of why" true
    (contains ~needle:"the host reported nothing" report);
  (* Never a value: a line reading as though the host had answered a mode is the
     silent success the whole register exists to remove, and the cram fixtures
     that count a converged run's readings search for exactly that phrasing. *)
  check bool "claims no mode the host never reported" false
    (contains ~needle:"was mode" report);
  check bool "and still says the run corrected nothing" true
    (contains ~needle:"setup corrected nothing on server 10.0.0.1" report);
  (* The affirmative arm on the same function: a real correction does suppress
     that sentence, so its presence above is the unreadable reading's doing and
     not a report that always says it. *)
  let corrected =
    String.concat "\n"
      (Setup_phases.corrections_report ~server:"10.0.0.1"
         [ correction_of_site Setup_phases.Alloy_config_mode ])
  in
  check bool
    "a run that corrected something does not also say it corrected nothing"
    false
    (contains ~needle:"corrected nothing" corrected)

(* The bound is log hygiene, not redaction: what the host said is the only thing
   that says what the box reported, so it is flattened and cut rather than
   dropped. *)
let test_a_multi_line_host_answer_is_bounded_not_dropped () =
  let multi_line = "sudo: unable to resolve host box\n0644" in
  let lines =
    Setup_phases.corrections_report ~server:"10.0.0.1"
      [
        Setup_phases.config_mode_corrected
          ~found:(Host_answer.of_host_output multi_line)
          ~applied:"0640";
      ]
  in
  check int "one line, whatever the host sent" 1 (List.length lines);
  let report = String.concat "\n" lines in
  check bool "carries every word the host said, on one line" true
    (contains ~needle:"was mode sudo: unable to resolve host box 0644, applied"
       report);
  check bool "leaves no newline in the line" false (String.contains report '\n');
  (* An answer past the bound. Its reading comes first, so what survives the cut
     is checkable rather than a run of filler. *)
  let long = "0644 " ^ String.make 900 'x' in
  let long_report =
    rendered ~server:"10.0.0.1"
      [
        Setup_phases.config_mode_corrected
          ~found:(Host_answer.of_host_output long)
          ~applied:"0640";
      ]
  in
  check bool "still carries what the host reported" true
    (contains ~needle:"was mode 0644 xxxxxxxxxx" long_report);
  check bool "says the answer was cut" true
    (contains ~needle:"truncated" long_report);
  check bool "says how much there was" true
    (contains
       ~needle:(Printf.sprintf "%d bytes" (String.length long))
       long_report);
  check bool "does not carry all of it" false
    (contains ~needle:long long_report);
  check bool "is shorter than what the host sent" true
    (String.length long_report < String.length long)

let corrections_tests =
  [
    test_case "a report names what was found and what was applied" `Quick
      test_corrections_report_names_what_was_found_and_applied;
    test_case "a run that corrected nothing says so" `Quick
      test_corrections_report_says_nothing_diverged_when_empty;
    test_case "a reading nobody could take is a line of the same account" `Quick
      test_an_unreadable_reading_is_reported_and_corrects_nothing;
    test_case "a multi-line host answer is bounded, not dropped" `Quick
      test_a_multi_line_host_answer_is_bounded_not_dropped;
  ]

let tests =
  [
    test_case "phase of every action" `Quick test_phase_of_each_action_is_named;
    test_case "a mid-plan failure strands the phases after it" `Quick
      test_unfinished_phases_after_a_mid_plan_failure;
    test_case "phases are named once, in plan order" `Quick
      test_unfinished_phases_are_deduplicated_in_plan_order;
    test_case "the last action strands nothing" `Quick
      test_unfinished_phases_is_empty_when_the_last_action_fails;
    test_case "the report names the failing and the skipped phases" `Quick
      test_failure_message_names_the_failing_phase_and_the_skipped_ones;
  ]

let () =
  Alcotest.run "Setup.phases"
    [ ("setup phases", tests); ("corrections", corrections_tests) ]
