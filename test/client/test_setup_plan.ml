open Alcotest
module Config_file = Bondi_client.Config_file
module Setup = Bondi_client.Cmd.Setup

let action_string = function
  | Setup.EnsureDocker -> "EnsureDocker"
  | Setup.EnsureAcmeFile -> "EnsureAcmeFile"
  | Setup.StopOrchestrator -> "StopOrchestrator"
  | Setup.RunServer -> "RunServer"
  | Setup.EnsureAlloyConfig -> "EnsureAlloyConfig"
  | Setup.RunAlloy -> "RunAlloy"
  | Setup.StopAlloy -> "StopAlloy"
  | Setup.RemoveAlloy -> "RemoveAlloy"

let check_actions ~expected actions =
  check (list string) "actions" expected (List.map action_string actions)

let minimal_server =
  { Config_file.ip_address = "1.2.3.4"; Config_file.ssh = None; port = None }

let minimal_user_service =
  {
    Config_file.name = "my-service";
    Config_file.image = "app";
    Config_file.port = 8080;
    Config_file.registry_user = None;
    Config_file.registry_pass = None;
    Config_file.env_vars = [];
    Config_file.servers = [ minimal_server ];
    Config_file.drain_grace_period = None;
    Config_file.deployment_strategy = None;
    Config_file.health_timeout = None;
    Config_file.poll_interval = None;
    Config_file.logs = None;
  }

let make_config ?(alloy = None) ~user_service ~cron_jobs ~version () =
  {
    Config_file.user_service;
    Config_file.bondi_server = { Config_file.version };
    Config_file.traefik = None;
    Config_file.cron_jobs;
    Config_file.alloy;
  }

let ctx ?(alloy_state = Setup.Alloy_not_running) ~running_version
    ~docker_installed ~acme_exists () =
  {
    Setup.docker_status =
      (if docker_installed then `Installed "Docker version 24.0"
       else `NotInstalled "command not found");
    Setup.acme_file_exists = acme_exists;
    Setup.running_version;
    Setup.alloy_state;
  }

let test_plan_always_includes_ensure_docker () =
  let config =
    make_config ~user_service:None ~cron_jobs:None ~version:"1.0.0" ()
  in
  let context =
    ctx ~running_version:None ~docker_installed:true ~acme_exists:false ()
  in
  let actions = Setup.plan config context in
  check bool "EnsureDocker is first" (List.hd actions = Setup.EnsureDocker) true

let test_plan_no_user_service_skips_acme () =
  let config =
    make_config ~user_service:None ~cron_jobs:None ~version:"1.0.0" ()
  in
  let context =
    ctx ~running_version:None ~docker_installed:true ~acme_exists:false ()
  in
  let actions = Setup.plan config context in
  check bool "no EnsureAcmeFile when no user_service"
    (List.mem Setup.EnsureAcmeFile actions)
    false

let test_plan_with_user_service_includes_acme () =
  let config =
    make_config ~user_service:(Some minimal_user_service) ~cron_jobs:None
      ~version:"1.0.0" ()
  in
  let context =
    ctx ~running_version:None ~docker_installed:true ~acme_exists:false ()
  in
  let actions = Setup.plan config context in
  check bool "EnsureAcmeFile when user_service present"
    (List.mem Setup.EnsureAcmeFile actions)
    true

let test_plan_skip_server_when_up_to_date () =
  let config =
    make_config ~user_service:None ~cron_jobs:None ~version:"1.0.0" ()
  in
  let context =
    ctx ~running_version:(Some "1.0.0") ~docker_installed:true
      ~acme_exists:false ()
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
    make_config ~user_service:None ~cron_jobs:None ~version:"1.0.0" ()
  in
  let context =
    ctx ~running_version:None ~docker_installed:true ~acme_exists:false ()
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
    make_config ~user_service:None ~cron_jobs:None ~version:"1.0.0" ()
  in
  let context =
    ctx ~running_version:(Some "0.9.0") ~docker_installed:true
      ~acme_exists:false ()
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
      ~version:"1.0.0" ()
  in
  let context =
    ctx ~running_version:(Some "1.0.0") ~docker_installed:true
      ~acme_exists:false ()
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
      ~version:"1.0.0" ()
  in
  let context =
    ctx ~running_version:(Some "0.9.0") ~docker_installed:true
      ~acme_exists:false ()
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
      ~version:"1.0.0" ()
  in
  let context =
    ctx ~running_version:None ~docker_installed:true ~acme_exists:false ()
  in
  let actions = Setup.plan config context in
  check bool "no EnsureAcmeFile when cron-only (no user_service)"
    (List.mem Setup.EnsureAcmeFile actions)
    false;
  check_actions ~expected:[ "EnsureDocker"; "RunServer" ] actions

let minimal_alloy =
  {
    Config_file.image = None;
    Config_file.grafana_cloud =
      {
        Config_file.instance_id = "123456";
        Config_file.api_key = "glc_secret";
        Config_file.endpoint = "https://logs-prod.grafana.net/loki/api/v1/push";
      };
    Config_file.collect = None;
    Config_file.labels = None;
  }

let test_plan_alloy_enabled () =
  let config =
    make_config ~alloy:(Some minimal_alloy) ~user_service:None ~cron_jobs:None
      ~version:"1.0.0" ()
  in
  let context =
    ctx ~running_version:None ~docker_installed:true ~acme_exists:false ()
  in
  let actions = Setup.plan config context in
  check bool "EnsureAlloyConfig when alloy configured"
    (List.mem Setup.EnsureAlloyConfig actions)
    true;
  check bool "RunAlloy when alloy configured"
    (List.mem Setup.RunAlloy actions)
    true

let test_plan_alloy_disabled () =
  let config =
    make_config ~user_service:None ~cron_jobs:None ~version:"1.0.0" ()
  in
  let context =
    ctx ~running_version:None ~docker_installed:true ~acme_exists:false ()
  in
  let actions = Setup.plan config context in
  check bool "no EnsureAlloyConfig when alloy not configured"
    (List.mem Setup.EnsureAlloyConfig actions)
    false;
  check bool "no RunAlloy when alloy not configured"
    (List.mem Setup.RunAlloy actions)
    false

let test_plan_alloy_removed () =
  let config =
    make_config ~user_service:None ~cron_jobs:None ~version:"1.0.0" ()
  in
  let context =
    ctx
      ~alloy_state:
        (Setup.Alloy_running { image = Bondi_common.Defaults.alloy_image })
      ~running_version:(Some "1.0.0") ~docker_installed:true ~acme_exists:false
      ()
  in
  let actions = Setup.plan config context in
  check bool "StopAlloy when alloy removed from config"
    (List.mem Setup.StopAlloy actions)
    true;
  check bool "RemoveAlloy when alloy removed from config"
    (List.mem Setup.RemoveAlloy actions)
    true

let test_plan_alloy_version_change () =
  let alloy_with_custom_image =
    { minimal_alloy with Config_file.image = Some "grafana/alloy:v2.0.0" }
  in
  let config =
    make_config ~alloy:(Some alloy_with_custom_image) ~user_service:None
      ~cron_jobs:None ~version:"1.0.0" ()
  in
  let context =
    ctx
      ~alloy_state:(Setup.Alloy_running { image = "grafana/alloy:v1.8.0" })
      ~running_version:(Some "1.0.0") ~docker_installed:true ~acme_exists:false
      ()
  in
  let actions = Setup.plan config context in
  check bool "StopAlloy on version change"
    (List.mem Setup.StopAlloy actions)
    true;
  check bool "RemoveAlloy on version change"
    (List.mem Setup.RemoveAlloy actions)
    true;
  check bool "EnsureAlloyConfig on version change"
    (List.mem Setup.EnsureAlloyConfig actions)
    true;
  check bool "RunAlloy on version change" (List.mem Setup.RunAlloy actions) true

let test_excluded_containers_no_service () =
  let config =
    make_config ~user_service:None ~cron_jobs:None ~version:"1.0.0" ()
  in
  check (list string) "empty when no service" []
    (Setup.excluded_containers_from_config config)

let test_excluded_containers_logs_true () =
  let service = { minimal_user_service with Config_file.logs = Some true } in
  let config =
    make_config ~user_service:(Some service) ~cron_jobs:None ~version:"1.0.0" ()
  in
  check (list string) "empty when logs=true" []
    (Setup.excluded_containers_from_config config)

let test_excluded_containers_logs_none () =
  let config =
    make_config ~user_service:(Some minimal_user_service) ~cron_jobs:None
      ~version:"1.0.0" ()
  in
  check (list string) "empty when logs=None" []
    (Setup.excluded_containers_from_config config)

let test_excluded_containers_logs_false () =
  let service = { minimal_user_service with Config_file.logs = Some false } in
  let config =
    make_config ~user_service:(Some service) ~cron_jobs:None ~version:"1.0.0" ()
  in
  check (list string) "service name when logs=false" [ "my-service" ]
    (Setup.excluded_containers_from_config config)

let test_alloy_river_config_defaults () =
  let config =
    make_config ~user_service:None ~cron_jobs:None ~version:"1.0.0" ()
  in
  let river = Setup.alloy_river_config config minimal_alloy in
  check string "endpoint" "https://logs-prod.grafana.net/loki/api/v1/push"
    river.grafana_cloud_endpoint;
  check string "instance_id" "123456" river.grafana_cloud_instance_id;
  check string "api_key" "glc_secret" river.grafana_cloud_api_key;
  check bool "collect defaults to All" true
    (river.collect = Bondi_common.Alloy_river.All);
  check (list (pair string string)) "labels default to empty" [] river.labels;
  check (list string) "excluded_containers empty" [] river.excluded_containers

let test_alloy_river_config_services_only () =
  let alloy =
    { minimal_alloy with Config_file.collect = Some "services_only" }
  in
  let config =
    make_config ~user_service:None ~cron_jobs:None ~version:"1.0.0" ()
  in
  let river = Setup.alloy_river_config config alloy in
  check bool "collect is Services_only" true
    (river.collect = Bondi_common.Alloy_river.Services_only)

let test_alloy_river_config_with_labels () =
  let alloy =
    {
      minimal_alloy with
      Config_file.labels = Some [ ("env", "prod"); ("team", "platform") ];
    }
  in
  let config =
    make_config ~user_service:None ~cron_jobs:None ~version:"1.0.0" ()
  in
  let river = Setup.alloy_river_config config alloy in
  check
    (list (pair string string))
    "labels passed through"
    [ ("env", "prod"); ("team", "platform") ]
    river.labels

let test_alloy_river_config_excludes_service () =
  let service = { minimal_user_service with Config_file.logs = Some false } in
  let config =
    make_config ~user_service:(Some service) ~cron_jobs:None ~version:"1.0.0" ()
  in
  let river = Setup.alloy_river_config config minimal_alloy in
  check (list string) "excluded service name" [ "my-service" ]
    river.excluded_containers

let test_plan_alloy_already_running () =
  let config =
    make_config ~alloy:(Some minimal_alloy) ~user_service:None ~cron_jobs:None
      ~version:"1.0.0" ()
  in
  let desired_image =
    Option.value minimal_alloy.image ~default:Bondi_common.Defaults.alloy_image
  in
  let context =
    ctx
      ~alloy_state:(Setup.Alloy_running { image = desired_image })
      ~running_version:(Some "1.0.0") ~docker_installed:true ~acme_exists:false
      ()
  in
  let actions = Setup.plan config context in
  check bool "no StopAlloy when already running with same version"
    (List.mem Setup.StopAlloy actions)
    false;
  check bool "no RemoveAlloy when already running with same version"
    (List.mem Setup.RemoveAlloy actions)
    false;
  check bool "no RunAlloy when already running with same version"
    (List.mem Setup.RunAlloy actions)
    false

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
      ( "alloy",
        [
          test_case "enabled" `Quick test_plan_alloy_enabled;
          test_case "disabled" `Quick test_plan_alloy_disabled;
          test_case "removed" `Quick test_plan_alloy_removed;
          test_case "version change" `Quick test_plan_alloy_version_change;
          test_case "already running" `Quick test_plan_alloy_already_running;
        ] );
      ( "excluded_containers_from_config",
        [
          test_case "no service" `Quick test_excluded_containers_no_service;
          test_case "logs=true" `Quick test_excluded_containers_logs_true;
          test_case "logs=None" `Quick test_excluded_containers_logs_none;
          test_case "logs=false" `Quick test_excluded_containers_logs_false;
        ] );
      ( "alloy_river_config",
        [
          test_case "defaults" `Quick test_alloy_river_config_defaults;
          test_case "services_only collect" `Quick
            test_alloy_river_config_services_only;
          test_case "with labels" `Quick test_alloy_river_config_with_labels;
          test_case "excludes service with logs=false" `Quick
            test_alloy_river_config_excludes_service;
        ] );
    ]
