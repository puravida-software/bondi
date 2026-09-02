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
        ] );
      ( "verification",
        [
          test_case "published binding assertion" `Quick test_binding_assertion;
        ] );
    ]
