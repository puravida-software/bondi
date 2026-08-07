open Alcotest
module Setup = Bondi_client.Cmd.Setup
module Setup_phases = Bondi_client.Setup_phases
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
      (Setup.RequireCronCurl, "Cron_curl");
      (Setup.EnsureAcmeFile, "Acme");
      (Setup.StopOrchestrator, "Orchestrator");
      (Setup.RemoveOrchestrator, "Orchestrator");
      (Setup.RunServer, "Orchestrator");
      (Setup.EnsureAlloyConfig, "Alloy");
      (Setup.RunAlloy, "Alloy");
      (Setup.StopAlloy, "Alloy");
      (Setup.RemoveAlloy, "Alloy");
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

let () = Alcotest.run "Setup.phases" [ ("setup phases", tests) ]
