open Alcotest
module Setup = Bondi_client.Cmd.Setup
module Config_file = Bondi_client.Config_file

(* Regression tests for the exposure found on 2026-08-29.
   `bondi setup` published the orchestrator with -p 3030:3030 -- every interface
   -- on every host it had ever set up. The orchestrator mounts the host Docker
   socket, so that was unauthenticated remote root, reachable by port scan.

   A hand-applied loopback binding had been masking it on one box. `setup`
   reverted that binding, because setup converges the box against bondi.yaml and
   the binding was not in bondi.yaml. These tests exist so the posture lives in
   the config and cannot be silently reverted again. *)

let cfg ?bind_address ?api_token ?cron_jobs () =
  Client_fixtures.mk_config ?bind_address ?api_token ?cron_jobs ()

let a_cron_job : Config_file.cron_job =
  {
    Config_file.name = "levtra-paper";
    image = "registry.example.com/org/levtra";
    schedule = "10 22 * * 1-5";
    network = None;
    env_vars = None;
    secret_env_vars = None;
    registry_user = None;
    registry_pass = None;
    alert_sinks = None;
    exit_code_severities = None;
    server = { Config_file.ip_address = "203.0.113.1"; ssh = None; port = None };
  }

let contains ~needle s = Bondi_common.String_utils.contains ~needle s

let ok_cmd c =
  match Setup.orchestrator_run_command c with
  | Ok s -> s
  | Error e -> failf "expected Ok, got Error: %s" e

(* THE test. If this fails, the orchestrator is on the public internet. *)
let test_default_is_loopback () =
  let cmd = ok_cmd (cfg ()) in
  check bool "publishes on loopback" true
    (contains ~needle:"-p 127.0.0.1:3030:3030" cmd);
  check bool "never publishes wide" false (contains ~needle:"-p 3030:3030" cmd)

let test_explicit_loopback () =
  let cmd = ok_cmd (cfg ~bind_address:"127.0.0.1" ()) in
  check bool "loopback" true (contains ~needle:"-p 127.0.0.1:3030:3030" cmd)

(* Public bind is allowed, but not unauthenticated -- that combination is the
   finding itself. *)
let test_public_without_token_refused () =
  match Setup.orchestrator_run_command (cfg ~bind_address:"0.0.0.0" ()) with
  | Ok _ -> fail "0.0.0.0 without api_token must be refused"
  | Error e ->
      check bool "names the address" true (contains ~needle:"0.0.0.0" e);
      check bool "names the remedy" true (contains ~needle:"api_token" e)

let test_public_with_token_allowed () =
  let cmd = ok_cmd (cfg ~bind_address:"0.0.0.0" ~api_token:"tok" ()) in
  check bool "publishes wide" true (contains ~needle:"-p 0.0.0.0:3030:3030" cmd);
  check bool "passes the token" true (contains ~needle:"BONDI_API_TOKEN" cmd)

let test_no_token_env_when_unset () =
  let cmd = ok_cmd (cfg ()) in
  check bool "no empty token var" false (contains ~needle:"BONDI_API_TOKEN" cmd)

(* Docker's default restart policy is `no`, so an orchestrator started without
   --restart is gone after a host reboot or a docker-ce upgrade and every
   deployed service with it. The needle is spelled out rather than built from
   the shared constant on purpose: through the constant this passes for any
   value it takes, including `always`, which blue-green must never see. *)
let test_run_command_declares_restart_policy () =
  let cmd = ok_cmd (cfg ()) in
  check bool "declares the policy" true
    (contains ~needle:"--restart unless-stopped" cmd)

(* Cron jobs force --user root, because Bondi manages cron by writing root's
   crontab through a bind mount. Dropping that flag leaves a container that
   answers health checks but cannot deploy a cron job -- which happened. *)
let test_cron_jobs_imply_root_and_mount () =
  let cmd = ok_cmd (cfg ~cron_jobs:[ a_cron_job ] ()) in
  check bool "runs as root" true (contains ~needle:"--user root" cmd);
  check bool "mounts crontab spool" true
    (contains ~needle:"/var/spool/cron/crontabs" cmd);
  (* and still on loopback -- the cron path calls localhost, not the public IP *)
  check bool "still loopback" true
    (contains ~needle:"-p 127.0.0.1:3030:3030" cmd)

(* setup must check what it got, not assume the run command took. *)
let test_binding_assertion () =
  check bool "match" true
    (Setup.published_binding_matches ~expected:"127.0.0.1" "127.0.0.1\n" = Ok ());
  (match Setup.published_binding_matches ~expected:"127.0.0.1" "0.0.0.0" with
  | Error got -> check string "reports what it found" "0.0.0.0" got
  | Ok () -> fail "0.0.0.0 must not satisfy a 127.0.0.1 expectation");
  (* Docker reports "all interfaces" as an empty HostIp. That must read as
     0.0.0.0, not as agreement with whatever was asked for. *)
  match Setup.published_binding_matches ~expected:"127.0.0.1" "" with
  | Error got -> check string "empty HostIp is 0.0.0.0" "0.0.0.0" got
  | Ok () -> fail "empty HostIp must not satisfy a loopback expectation"

(* The orchestrator's policy is read back from the host, not assumed from the
   run command. A run that predates --restart, a flag the daemon quietly
   dropped, and a policy a human cleared by hand all look identical from here,
   and all three are what the 2026-09-02 audit found on a live box. *)
let test_restart_inspect_command_reads_the_applied_policy () =
  let cmd = Setup.orchestrator_restart_command in
  check bool "inspects the orchestrator by name" true
    (contains ~needle:"docker inspect bondi-orchestrator" cmd);
  check bool "reads the applied policy" true
    (contains ~needle:"{{.HostConfig.RestartPolicy.Name}}" cmd)

(* Correcting the policy must not cost a restart: docker update writes the
   field on the running container, leaving the pid and StartedAt alone. A
   command that stopped, removed or re-ran the orchestrator would drop TLS for
   every site on the box to change a flag. *)
let test_restart_update_command_names_the_policy () =
  let cmd =
    Setup.orchestrator_restart_update_command ~policy:"unless-stopped"
  in
  check bool "updates in place" true (contains ~needle:"docker update" cmd);
  check bool "names the policy" true
    (contains ~needle:"--restart=unless-stopped" cmd);
  check bool "names the container" true
    (contains ~needle:"bondi-orchestrator" cmd);
  check bool "never recreates" false (contains ~needle:"docker run" cmd);
  check bool "never stops" false (contains ~needle:"docker stop" cmd)

let test_restart_matches_accepts_the_declared_policy () =
  match
    Setup.declared_restart_matches ~expected:"unless-stopped" "unless-stopped\n"
  with
  | Ok () -> ()
  | Error got -> failf "the declared policy must satisfy the check, got %s" got

(* Spelled out rather than built from the shared constant, as the run-command
   test above is: through the constant this would pass for whatever value the
   constant takes. *)
let test_restart_matches_rejects_a_different_policy () =
  match Setup.declared_restart_matches ~expected:"unless-stopped" "no\n" with
  | Error got -> check string "reports what it found" "no" got
  | Ok () -> fail "`no` must not satisfy an unless-stopped expectation"

(* Empty is what the host prints when the container is gone, when the answer is
   unreadable, and when an ssh stub has no arm for the command. None of those is
   agreement. Docker prints the word `no` for a container with no policy --
   observed 2026-09-02 -- so empty never means "no policy" and must not be
   rendered as if it did. *)
let test_restart_matches_rejects_empty_output () =
  match Setup.declared_restart_matches ~expected:"unless-stopped" "" with
  | Error got ->
      check string "names that nothing was read" "(none reported)" got
  | Ok () -> fail "empty output must be a rejection, never agreement"

(* Both arms from the same expectation, differing only in what the host
   reported. The compliant arm alone passes against a decision that never
   updates; the differing arm alone passes against one that always does. *)
let test_convergence_updates_only_when_the_policy_differs () =
  (match
     Setup.orchestrator_restart_convergence ~expected:"unless-stopped" "no\n"
   with
  | Setup.Restart_policy_needs_update { observed; command } ->
      check string "names what the host applied" "no" observed;
      check bool "corrects it in place" true
        (contains ~needle:"docker update" command);
      check bool "asks for the declared policy" true
        (contains ~needle:"unless-stopped" command)
  | Setup.Restart_policy_already_applied ->
      fail "an orchestrator reporting `no` must be converged"
  | Setup.Restart_policy_unreadable ->
      fail "a host that reported `no` was read, so this is not unreadable");
  match
    Setup.orchestrator_restart_convergence ~expected:"unless-stopped"
      "unless-stopped\n"
  with
  | Setup.Restart_policy_already_applied -> ()
  | Setup.Restart_policy_needs_update { observed; command = _ } ->
      failf "a compliant orchestrator must not be updated (observed %s)"
        observed
  | Setup.Restart_policy_unreadable ->
      fail "a host that reported the declared policy was read"

(* Nothing read is not a policy. A removed orchestrator, an unreadable answer
   and an ssh stub with no arm for the command all print empty, and correcting
   that as if it were a difference issues `docker update` against a container
   that is not there -- surfacing whatever raw text Docker returns instead of
   naming what setup was attempting. The affirmative arm is the case above:
   the same function still updates on a real difference and still passes a
   compliant orchestrator, so this rejection is caused by the read, not by the
   decision having stopped updating anything. *)
let test_convergence_rejects_an_unreadable_inspect () =
  let unreadable label output =
    match
      Setup.orchestrator_restart_convergence ~expected:"unless-stopped" output
    with
    | Setup.Restart_policy_unreadable -> ()
    | Setup.Restart_policy_needs_update { observed; command = _ } ->
        failf "%s must not be corrected as a difference (observed %s)" label
          observed
    | Setup.Restart_policy_already_applied ->
        failf "%s must never read as agreement" label
  in
  unreadable "empty output" "";
  unreadable "whitespace-only output" "  \n"

let () =
  run "orchestrator bind"
    [
      ( "publish address",
        [
          test_case "defaults to loopback" `Quick test_default_is_loopback;
          test_case "explicit loopback" `Quick test_explicit_loopback;
          test_case "public without token refused" `Quick
            test_public_without_token_refused;
          test_case "public with token allowed" `Quick
            test_public_with_token_allowed;
          test_case "no token env when unset" `Quick
            test_no_token_env_when_unset;
          test_case "cron implies root + mount" `Quick
            test_cron_jobs_imply_root_and_mount;
          test_case "run command declares restart policy" `Quick
            test_run_command_declares_restart_policy;
        ] );
      ( "verification",
        [
          test_case "published binding assertion" `Quick test_binding_assertion;
          test_case "restart inspect command" `Quick
            test_restart_inspect_command_reads_the_applied_policy;
          test_case "restart update command" `Quick
            test_restart_update_command_names_the_policy;
          test_case "restart matcher accepts the declared policy" `Quick
            test_restart_matches_accepts_the_declared_policy;
          test_case "restart matcher rejects a different policy" `Quick
            test_restart_matches_rejects_a_different_policy;
          test_case "restart matcher rejects empty output" `Quick
            test_restart_matches_rejects_empty_output;
          test_case "convergence updates only on a difference" `Quick
            test_convergence_updates_only_when_the_policy_differs;
          test_case "convergence rejects an unreadable inspect" `Quick
            test_convergence_rejects_an_unreadable_inspect;
        ] );
    ]
