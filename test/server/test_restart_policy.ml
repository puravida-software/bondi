module Restart_policy = Bondi_server__Docker__Restart_policy
module Docker = Bondi_server__Docker__Client

(* The Engine reports a MaximumRetryCount on every container, including on a
   policy that cannot carry one, so a fixture omitting it would not be the shape
   the daemon actually answers with. *)
let applied name : Docker.restart_policy =
  { name; maximum_retry_count = Some 0 }

let test_bondi_managed_is_unless_stopped () =
  Alcotest.check Alcotest.string "policy name" "unless-stopped"
    Restart_policy.bondi_managed.Docker.name;
  Alcotest.check
    (Alcotest.option Alcotest.int)
    "no maximum retry count" None
    Restart_policy.bondi_managed.Docker.maximum_retry_count

(* An answer that says nothing is not evidence that the container is compliant. *)
let test_no_reported_policy_is_a_mismatch () =
  Alcotest.check Alcotest.bool "an unreported policy is not a pass" false
    (Restart_policy.applied_matches None)

(* The affirmative arm of the same collapse, and the one that pins the
   comparison as name-only: the retry count differs from [bondi_managed] and the
   container is still compliant. *)
let test_the_declared_policy_matches () =
  Alcotest.check Alcotest.bool "the declared policy matches on the name alone"
    true
    (Restart_policy.applied_matches (Some (applied "unless-stopped")))

let test_another_policy_does_not_match () =
  Alcotest.check Alcotest.bool "docker's default is a mismatch" false
    (Restart_policy.applied_matches (Some (applied "no")))

let mk_host_config restart_policy : Docker.host_config =
  { binds = None; port_bindings = None; network_mode = None; restart_policy }

let inspect_with host_config : Docker.inspect_response =
  Server_test_helpers.mk_inspect ~created_at:"2026-09-02T00:00:00Z"
    ~restart_count:0 ~status:"running" ~host_config ()

let policy_name = Option.map (fun (p : Docker.restart_policy) -> p.Docker.name)

(* The whole point of the collapse: an inspect Bondi could not make answers the
   same as a daemon reporting no policy, which [applied_matches] already treats
   as a mismatch. A read that failed therefore converges the container instead
   of blocking the caller that needed the read. *)
let test_unreadable_inspect_reports_no_policy () =
  let reading = Restart_policy.of_inspect (Error "request timed out") in
  Alcotest.check
    (Alcotest.option Alcotest.string)
    "an unreadable inspect reports no policy" None (policy_name reading);
  Alcotest.check Alcotest.bool "and is not read as agreement" false
    (Restart_policy.applied_matches reading)

(* The affirmative arm of the same collapse: the fixture does reach the policy,
   so the [None]s above are caused by the read failing, not by [of_inspect]
   never finding a policy in any shape. *)
let test_inspect_reports_the_applied_policy () =
  Alcotest.check
    (Alcotest.option Alcotest.string)
    "the policy the daemon reported" (Some "no")
    (policy_name
       (Restart_policy.of_inspect
          (Ok (inspect_with (Some (mk_host_config (Some (applied "no"))))))))

let test_inspect_without_a_host_config_reports_no_policy () =
  Alcotest.check
    (Alcotest.option Alcotest.string)
    "no host config is no policy" None
    (policy_name (Restart_policy.of_inspect (Ok (inspect_with None))))

let test_inspect_without_a_policy_reports_no_policy () =
  Alcotest.check
    (Alcotest.option Alcotest.string)
    "a host config carrying no policy is no policy" None
    (policy_name
       (Restart_policy.of_inspect
          (Ok (inspect_with (Some (mk_host_config None))))))

let () =
  Alcotest.run "Restart_policy"
    [
      ( "bondi managed",
        [
          Alcotest.test_case "is unless-stopped with no retry count" `Quick
            test_bondi_managed_is_unless_stopped;
        ] );
      ( "applied matches",
        [
          Alcotest.test_case "no reported policy" `Quick
            test_no_reported_policy_is_a_mismatch;
          Alcotest.test_case "the declared policy" `Quick
            test_the_declared_policy_matches;
          Alcotest.test_case "another policy" `Quick
            test_another_policy_does_not_match;
        ] );
      ( "of inspect",
        [
          Alcotest.test_case "an unreadable inspect" `Quick
            test_unreadable_inspect_reports_no_policy;
          Alcotest.test_case "a reported policy" `Quick
            test_inspect_reports_the_applied_policy;
          Alcotest.test_case "no host config" `Quick
            test_inspect_without_a_host_config_reports_no_policy;
          Alcotest.test_case "no policy in the host config" `Quick
            test_inspect_without_a_policy_reports_no_policy;
        ] );
    ]
