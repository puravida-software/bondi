open Alcotest
module Config_file = Bondi_client.Config_file
module Setup = Bondi_client.Cmd.Setup

let action_string = function
  | Setup.EnsureDocker -> "EnsureDocker"
  | Setup.EnsureAcmeFile -> "EnsureAcmeFile"
  | Setup.StopOrchestrator -> "StopOrchestrator"
  | Setup.RunServer -> "RunServer"

let check_actions ~expected actions =
  check (list string) "actions" expected (List.map action_string actions)

let minimal_server =
  { Config_file.ip_address = "1.2.3.4"; Config_file.ssh = None }

let minimal_user_service =
  {
    Config_file.image = "app:v1";
    Config_file.port = 8080;
    Config_file.registry_user = None;
    Config_file.registry_pass = None;
    Config_file.env_vars = [];
    Config_file.servers = [ minimal_server ];
  }

let make_config ~user_service ~cron_jobs ~version =
  {
    Config_file.user_service;
    Config_file.bondi_server = { Config_file.version };
    Config_file.traefik = None;
    Config_file.cron_jobs;
  }

let ctx ~running_version ~docker_installed ~acme_exists =
  {
    Setup.docker_status =
      (if docker_installed then `Installed "Docker version 24.0"
       else `NotInstalled "command not found");
    Setup.acme_file_exists = acme_exists;
    Setup.running_version;
  }

let test_plan_always_includes_ensure_docker () =
  let config =
    make_config ~user_service:None ~cron_jobs:None ~version:"1.0.0"
  in
  let context =
    ctx ~running_version:"" ~docker_installed:true ~acme_exists:false
  in
  let actions = Setup.plan config context in
  check bool "EnsureDocker is first" (List.hd actions = Setup.EnsureDocker) true

let test_plan_no_user_service_skips_acme () =
  let config =
    make_config ~user_service:None ~cron_jobs:None ~version:"1.0.0"
  in
  let context =
    ctx ~running_version:"" ~docker_installed:true ~acme_exists:false
  in
  let actions = Setup.plan config context in
  check bool "no EnsureAcmeFile when no user_service"
    (List.mem Setup.EnsureAcmeFile actions)
    false

let test_plan_with_user_service_includes_acme () =
  let config =
    make_config ~user_service:(Some minimal_user_service) ~cron_jobs:None
      ~version:"1.0.0"
  in
  let context =
    ctx ~running_version:"" ~docker_installed:true ~acme_exists:false
  in
  let actions = Setup.plan config context in
  check bool "EnsureAcmeFile when user_service present"
    (List.mem Setup.EnsureAcmeFile actions)
    true

let test_plan_skip_server_when_up_to_date () =
  let config =
    make_config ~user_service:None ~cron_jobs:None ~version:"1.0.0"
  in
  let context =
    ctx ~running_version:"1.0.0" ~docker_installed:true ~acme_exists:false
  in
  let actions = Setup.plan config context in
  check bool "no RunServer when version matches and no cron"
    (List.mem Setup.RunServer actions)
    false;
  check bool "no StopOrchestrator when skipping"
    (List.mem Setup.StopOrchestrator actions)
    false

let test_plan_fresh_install_runs_server () =
  let config =
    make_config ~user_service:None ~cron_jobs:None ~version:"1.0.0"
  in
  let context =
    ctx ~running_version:"" ~docker_installed:true ~acme_exists:false
  in
  let actions = Setup.plan config context in
  check bool "RunServer when no running orchestrator"
    (List.mem Setup.RunServer actions)
    true;
  check bool "no StopOrchestrator on fresh install"
    (List.mem Setup.StopOrchestrator actions)
    false

let test_plan_version_mismatch_stops_and_runs () =
  let config =
    make_config ~user_service:None ~cron_jobs:None ~version:"1.0.0"
  in
  let context =
    ctx ~running_version:"0.9.0" ~docker_installed:true ~acme_exists:false
  in
  let actions = Setup.plan config context in
  check bool "StopOrchestrator on version mismatch"
    (List.mem Setup.StopOrchestrator actions)
    true;
  check bool "RunServer after version mismatch"
    (List.mem Setup.RunServer actions)
    true

let test_plan_cron_jobs_force_restart () =
  let cron_job =
    {
      Config_file.name = "backup";
      Config_file.image = "backup:v1";
      Config_file.schedule = "0 0 * * *";
      Config_file.env_vars = None;
      Config_file.registry_user = None;
      Config_file.registry_pass = None;
      Config_file.server = minimal_server;
    }
  in
  let config =
    make_config ~user_service:None ~cron_jobs:(Some [ cron_job ])
      ~version:"1.0.0"
  in
  let context =
    ctx ~running_version:"1.0.0" ~docker_installed:true ~acme_exists:false
  in
  let actions = Setup.plan config context in
  check bool "StopOrchestrator when adding cron jobs"
    (List.mem Setup.StopOrchestrator actions)
    true;
  check bool "RunServer when adding cron jobs"
    (List.mem Setup.RunServer actions)
    true

let test_plan_action_order () =
  let config =
    make_config ~user_service:(Some minimal_user_service) ~cron_jobs:None
      ~version:"1.0.0"
  in
  let context =
    ctx ~running_version:"0.9.0" ~docker_installed:true ~acme_exists:false
  in
  let actions = Setup.plan config context in
  check_actions
    ~expected:
      [ "EnsureDocker"; "EnsureAcmeFile"; "StopOrchestrator"; "RunServer" ]
    actions

let test_plan_cron_only_no_acme () =
  let cron_job =
    {
      Config_file.name = "backup";
      Config_file.image = "backup:v1";
      Config_file.schedule = "0 0 * * *";
      Config_file.env_vars = None;
      Config_file.registry_user = None;
      Config_file.registry_pass = None;
      Config_file.server = minimal_server;
    }
  in
  let config =
    make_config ~user_service:None ~cron_jobs:(Some [ cron_job ])
      ~version:"1.0.0"
  in
  let context =
    ctx ~running_version:"" ~docker_installed:true ~acme_exists:false
  in
  let actions = Setup.plan config context in
  check bool "no EnsureAcmeFile when cron-only (no user_service)"
    (List.mem Setup.EnsureAcmeFile actions)
    false;
  check_actions ~expected:[ "EnsureDocker"; "RunServer" ] actions

let () =
  run "Setup.plan"
    [
      ( "EnsureDocker",
        [
          test_case "always included" `Quick
            test_plan_always_includes_ensure_docker;
        ] );
      ( "ACME",
        [
          test_case "skipped when no user_service" `Quick
            test_plan_no_user_service_skips_acme;
          test_case "included when user_service present" `Quick
            test_plan_with_user_service_includes_acme;
          test_case "skipped when cron-only" `Quick test_plan_cron_only_no_acme;
        ] );
      ( "server",
        [
          test_case "skips when up-to-date and no cron" `Quick
            test_plan_skip_server_when_up_to_date;
          test_case "runs on fresh install" `Quick
            test_plan_fresh_install_runs_server;
          test_case "stops and runs on version mismatch" `Quick
            test_plan_version_mismatch_stops_and_runs;
          test_case "restarts when adding cron jobs" `Quick
            test_plan_cron_jobs_force_restart;
        ] );
      ("order", [ test_case "action order" `Quick test_plan_action_order ]);
    ]
