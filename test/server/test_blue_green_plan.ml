open Alcotest
module Blue_green = Bondi_server__Strategy__Blue_green
module Docker = Bondi_server__Docker__Client
module Simple = Bondi_server__Strategy__Simple
module Workload_host_config = Bondi_server__Strategy__Workload_host_config

let traefik_labels =
  [
    ("traefik.enable", "true");
    ( "traefik.http.routers.bondi.rule",
      "Host(`example.com`) || Host(`www.example.com`)" );
    ("traefik.http.routers.bondi.entrypoints", "websecure");
    ("traefik.http.routers.bondi.tls", "true");
    ("traefik.http.routers.bondi.tls.certresolver", "bondi_resolver");
    ("traefik.http.services.bondi.loadbalancer.server.port", "8080");
  ]

let base_config =
  {
    Blue_green.container_name = "my-service";
    temp_container_name = "my-service-new";
    config =
      {
        Docker.image = Some "myapp:v1";
        env = None;
        cmd = None;
        entrypoint = None;
        hostname = None;
        working_dir = None;
        labels = Some traefik_labels;
        exposed_ports = None;
      };
    host_config = Workload_host_config.of_volumes None;
    networking_conf = Simple.default_networking_config;
    network_name = "bondi-network";
    poll_interval = 1.0;
    health_timeout = 120.0;
    drain_grace_period = 2.0;
  }

let old_workload =
  Server_test_helpers.mk_container ~id:"old-container-id" ~image:"myapp:v0.9"
    ~names:[ "/my-service" ] ()

let context_with_workload =
  {
    Blue_green.current_workload = Some old_workload;
    orphaned_new_container = None;
  }

let empty_context =
  { Blue_green.current_workload = None; orphaned_new_container = None }

let action_string = function
  | Blue_green.CleanupOrphanedContainer { container_id } ->
      "CleanupOrphanedContainer(" ^ container_id ^ ")"
  | Blue_green.RunNewContainer { container_name; _ } ->
      "RunNewContainer(" ^ container_name ^ ")"
  | Blue_green.WaitForHealthy { container_name; _ } ->
      "WaitForHealthy(" ^ container_name ^ ")"
  | Blue_green.DisconnectFromNetwork { container_id; network_name } ->
      "DisconnectFromNetwork(" ^ container_id ^ "," ^ network_name ^ ")"
  | Blue_green.DrainGracePeriod { seconds } ->
      "DrainGracePeriod(" ^ string_of_float seconds ^ ")"
  | Blue_green.StopAndRemoveContainer { container_id } ->
      "StopAndRemoveContainer(" ^ container_id ^ ")"
  | Blue_green.RenameContainer { container_id; new_name } ->
      "RenameContainer(" ^ container_id ^ "," ^ new_name ^ ")"

let test_plan_success_path_actions () =
  let plan = Blue_green.plan base_config context_with_workload in
  check (list string) "success path actions"
    [
      "RunNewContainer(my-service-new)";
      "WaitForHealthy(my-service-new)";
      "DisconnectFromNetwork(old-container-id,bondi-network)";
      "DrainGracePeriod(2.)";
      "StopAndRemoveContainer(old-container-id)";
      "RenameContainer(my-service-new,my-service)";
    ]
    (List.map action_string plan.success_path)

let test_plan_success_path_no_existing_workload () =
  let plan = Blue_green.plan base_config empty_context in
  check (list string) "success path for first deploy"
    [ "RunNewContainer(my-service)"; "WaitForHealthy(my-service)" ]
    (List.map action_string plan.success_path)

let test_plan_rollback_container_name () =
  let plan = Blue_green.plan base_config context_with_workload in
  check string "rollback container name" "my-service-new"
    plan.rollback_container_name

let test_plan_uses_configured_drain_period () =
  let config = { base_config with drain_grace_period = 5.0 } in
  let plan = Blue_green.plan config context_with_workload in
  let drain_action =
    List.find_opt
      (function
        | Blue_green.DrainGracePeriod _ -> true
        | Blue_green.CleanupOrphanedContainer _
        | Blue_green.RunNewContainer _
        | Blue_green.WaitForHealthy _
        | Blue_green.DisconnectFromNetwork _
        | Blue_green.StopAndRemoveContainer _
        | Blue_green.RenameContainer _ ->
            false)
      plan.success_path
  in
  match drain_action with
  | Some (Blue_green.DrainGracePeriod { seconds }) ->
      check (float 0.01) "drain period" 5.0 seconds
  | Some (Blue_green.CleanupOrphanedContainer _)
  | Some (Blue_green.RunNewContainer _)
  | Some (Blue_green.WaitForHealthy _)
  | Some (Blue_green.DisconnectFromNetwork _)
  | Some (Blue_green.StopAndRemoveContainer _)
  | Some (Blue_green.RenameContainer _)
  | None ->
      Alcotest.fail "expected DrainGracePeriod action"

let test_plan_default_drain_period () =
  let config =
    {
      base_config with
      drain_grace_period = Blue_green.default_drain_grace_period;
    }
  in
  let plan = Blue_green.plan config context_with_workload in
  let drain_action =
    List.find_opt
      (function
        | Blue_green.DrainGracePeriod _ -> true
        | Blue_green.CleanupOrphanedContainer _
        | Blue_green.RunNewContainer _
        | Blue_green.WaitForHealthy _
        | Blue_green.DisconnectFromNetwork _
        | Blue_green.StopAndRemoveContainer _
        | Blue_green.RenameContainer _ ->
            false)
      plan.success_path
  in
  match drain_action with
  | Some (Blue_green.DrainGracePeriod { seconds }) ->
      check (float 0.01) "default drain period" 2.0 seconds
  | Some (Blue_green.CleanupOrphanedContainer _)
  | Some (Blue_green.RunNewContainer _)
  | Some (Blue_green.WaitForHealthy _)
  | Some (Blue_green.DisconnectFromNetwork _)
  | Some (Blue_green.StopAndRemoveContainer _)
  | Some (Blue_green.RenameContainer _)
  | None ->
      Alcotest.fail "expected DrainGracePeriod action"

let test_plan_temp_container_name () =
  let plan = Blue_green.plan base_config context_with_workload in
  let run_action =
    List.find_opt
      (function
        | Blue_green.RunNewContainer _ -> true
        | Blue_green.CleanupOrphanedContainer _
        | Blue_green.WaitForHealthy _
        | Blue_green.DisconnectFromNetwork _
        | Blue_green.DrainGracePeriod _
        | Blue_green.StopAndRemoveContainer _
        | Blue_green.RenameContainer _ ->
            false)
      plan.success_path
  in
  match run_action with
  | Some (Blue_green.RunNewContainer { container_name; _ }) ->
      check string "temp container name" "my-service-new" container_name
  | Some (Blue_green.CleanupOrphanedContainer _)
  | Some (Blue_green.WaitForHealthy _)
  | Some (Blue_green.DisconnectFromNetwork _)
  | Some (Blue_green.DrainGracePeriod _)
  | Some (Blue_green.StopAndRemoveContainer _)
  | Some (Blue_green.RenameContainer _)
  | None ->
      Alcotest.fail "expected RunNewContainer action"

let test_plan_traefik_labels_on_new_container () =
  let plan = Blue_green.plan base_config context_with_workload in
  let run_action =
    List.find_opt
      (function
        | Blue_green.RunNewContainer _ -> true
        | Blue_green.CleanupOrphanedContainer _
        | Blue_green.WaitForHealthy _
        | Blue_green.DisconnectFromNetwork _
        | Blue_green.DrainGracePeriod _
        | Blue_green.StopAndRemoveContainer _
        | Blue_green.RenameContainer _ ->
            false)
      plan.success_path
  in
  match run_action with
  | Some (Blue_green.RunNewContainer { config; _ }) ->
      let has_traefik_enable =
        match config.labels with
        | Some labels ->
            List.exists
              (fun (k, v) -> k = "traefik.enable" && v = "true")
              labels
        | None -> false
      in
      check bool "has traefik labels" true has_traefik_enable
  | Some (Blue_green.CleanupOrphanedContainer _)
  | Some (Blue_green.WaitForHealthy _)
  | Some (Blue_green.DisconnectFromNetwork _)
  | Some (Blue_green.DrainGracePeriod _)
  | Some (Blue_green.StopAndRemoveContainer _)
  | Some (Blue_green.RenameContainer _)
  | None ->
      Alcotest.fail "expected RunNewContainer action"

let extract_new_container_host_config (actions : Blue_green.action list) =
  List.find_map
    (function
      | Blue_green.RunNewContainer { host_config; _ } -> Some host_config
      | Blue_green.CleanupOrphanedContainer _
      | Blue_green.WaitForHealthy _
      | Blue_green.DisconnectFromNetwork _
      | Blue_green.DrainGracePeriod _
      | Blue_green.StopAndRemoveContainer _
      | Blue_green.RenameContainer _ ->
          None)
    actions

let check_planned_restart_policy msg (host_config : Docker.host_config) =
  match host_config.restart_policy with
  | None -> Alcotest.fail (msg ^ ": no restart policy planned")
  | Some policy ->
      check string (msg ^ ": policy name") "unless-stopped" policy.name;
      check (option int)
        (msg ^ ": no maximum retry count")
        None policy.maximum_retry_count

let check_restart_policy_for msg context =
  let plan = Blue_green.plan base_config context in
  match extract_new_container_host_config plan.success_path with
  | None -> Alcotest.fail (msg ^ ": expected a RunNewContainer action")
  | Some host_config -> check_planned_restart_policy msg host_config

(* [Blue_green.plan] builds [RunNewContainer] at two separate sites - the
   temp-container arm taken when a workload is already running, and the
   direct-name arm taken when none is. Both are asserted, because a policy set
   only at one site ships a workload without one on the other path. *)
let test_run_new_container_carries_restart_policy () =
  check_restart_policy_for "replacing a running workload" context_with_workload;
  check_restart_policy_for "no existing workload" empty_context

(* Volumes

   The config below is assembled from a deploy input by the same function
   [Blue_green.deploy] uses, so these cases see the host config the strategy
   actually runs with rather than one this file built. *)

let mount_testable = Server_test_helpers.mount_testable
let host_config_testable = Server_test_helpers.host_config_testable
let bind_mount = Test_helpers.bind_mount

let input_with_volumes : Simple.deploy_input =
  {
    service_name = Some "my-service";
    image = Some "myapp:v1";
    port = Some 8080;
    registry_user = None;
    registry_pass = None;
    env_vars = None;
    traefik_domain_name = Some "example.com";
    traefik_image = None;
    traefik_acme_email = None;
    force_traefik_redeploy = None;
    cron_jobs = None;
    drain_grace_period = None;
    deployment_strategy = Some "blue-green";
    health_timeout = None;
    poll_interval = None;
    logs = None;
    volumes =
      Some
        [
          bind_mount ~host:"/srv/comalito/invoices" ~container:"/app/invoices"
            ~read_only:false;
          bind_mount ~host:"/etc/comalito" ~container:"/app/config"
            ~read_only:true;
        ];
  }

let declared_mounts : Docker.mount list =
  [
    {
      type_ = "bind";
      source = "/srv/comalito/invoices";
      target = "/app/invoices";
      read_only = false;
    };
    {
      type_ = "bind";
      source = "/etc/comalito";
      target = "/app/config";
      read_only = true;
    };
  ]

let new_container_host_config msg input context =
  match Blue_green.config_of_input input with
  | Error e -> Alcotest.fail (msg ^ ": config refused: " ^ e)
  | Ok config -> (
      let plan = Blue_green.plan config context in
      match extract_new_container_host_config plan.success_path with
      | None -> Alcotest.fail (msg ^ ": expected a RunNewContainer action")
      | Some host_config -> host_config)

(* The temp-container site, taken when a workload is already running: the
   incoming colour mounts what the outgoing one does. *)
let test_new_container_carries_mounts_when_replacing_a_workload () =
  check
    (option (list mount_testable))
    "incoming colour's mounts" (Some declared_mounts)
    (new_container_host_config "replacing" input_with_volumes
       context_with_workload)
      .mounts

(* The direct-name site, taken when nothing is running yet. *)
let test_new_container_carries_mounts_on_first_deploy () =
  check
    (option (list mount_testable))
    "first container's mounts" (Some declared_mounts)
    (new_container_host_config "first deploy" input_with_volumes empty_context)
      .mounts

let simple_workload_host_config (input : Simple.deploy_input) =
  let context = { Simple.current_traefik = None; current_workload = None } in
  match Simple.plan input context with
  | Error e -> Alcotest.fail ("simple plan failed: " ^ e)
  | Ok actions -> (
      match
        List.find_map
          (function
            | Simple.RunWorkload { host_config; _ } -> Some host_config
            | Simple.CreateNetwork _
            | Simple.EnsureTraefik _
            | Simple.StopAndRemoveContainer _
            | Simple.PullImage _ ->
                None)
          actions
      with
      | None -> Alcotest.fail "expected a RunWorkload action"
      | Some host_config -> host_config)

(* For one deploy input, the simple strategy's container and both blue-green
   sites get the same host config. The first check is the affirmative arm:
   equality between two configs that both carry no mounts would prove nothing. *)
let test_simple_and_blue_green_mount_identically () =
  let simple = simple_workload_host_config input_with_volumes in
  check
    (option (list mount_testable))
    "simple carries the declared mounts" (Some declared_mounts) simple.mounts;
  check host_config_testable "blue-green replacing a workload" simple
    (new_container_host_config "replacing" input_with_volumes
       context_with_workload);
  check host_config_testable "blue-green first deploy" simple
    (new_container_host_config "first deploy" input_with_volumes empty_context)

(* The colour started beside a running workload runs as [<svc>-new] and is
   renamed afterwards, so its container name is not the workload's name. The
   name check is the arm: it proves the label below was read off the temp
   container and not off the direct-name first-deploy site. *)
let test_blue_green_temp_container_carries_service_name () =
  match Blue_green.config_of_input input_with_volumes with
  | Error e -> Alcotest.fail ("config refused: " ^ e)
  | Ok config -> (
      let plan = Blue_green.plan config context_with_workload in
      let started =
        List.find_map
          (function
            | Blue_green.RunNewContainer { container_name; config; _ } ->
                Some (container_name, config.labels)
            | Blue_green.CleanupOrphanedContainer _
            | Blue_green.WaitForHealthy _
            | Blue_green.DisconnectFromNetwork _
            | Blue_green.DrainGracePeriod _
            | Blue_green.StopAndRemoveContainer _
            | Blue_green.RenameContainer _ ->
                None)
          plan.success_path
      in
      match started with
      | None -> Alcotest.fail "expected a RunNewContainer action"
      | Some (_, None) -> Alcotest.fail "expected labels on the temp container"
      | Some (container_name, Some labels) ->
          check string "started under the temp name" "my-service-new"
            container_name;
          check (option string) "bondi.name is the service, not the temp name"
            (Some "my-service")
            (List.assoc_opt "bondi.name" labels))

let test_plan_orphan_cleanup () =
  let orphan =
    Server_test_helpers.mk_container ~id:"orphan-id" ~image:"myapp:v0.8"
      ~names:[ "/my-service-new" ] ()
  in
  let context =
    {
      Blue_green.current_workload = Some old_workload;
      orphaned_new_container = Some orphan;
    }
  in
  let plan = Blue_green.plan base_config context in
  match plan.success_path with
  | [] -> Alcotest.fail "expected a non-empty success path"
  | first_action :: _ ->
      check string "first action is cleanup"
        "CleanupOrphanedContainer(orphan-id)"
        (action_string first_action)

let mk_health_log output exit_code : Docker.health_log_entry =
  { output; exit_code }

let test_last_health_output_empty_log () =
  let health = Server_test_helpers.mk_health_state "unhealthy" in
  check (option string) "no output" None (Blue_green.last_health_output health)

let test_last_health_output_returns_last () =
  let log =
    [ mk_health_log "first check" 1; mk_health_log "connection refused" 1 ]
  in
  let health = Server_test_helpers.mk_health_state ~log "unhealthy" in
  check (option string) "last output" (Some "connection refused")
    (Blue_green.last_health_output health)

let test_last_health_output_trims_whitespace () =
  let log = [ mk_health_log "  some output  \n" 1 ] in
  let health = Server_test_helpers.mk_health_state ~log "unhealthy" in
  check (option string) "trimmed" (Some "some output")
    (Blue_green.last_health_output health)

let test_last_health_output_blank_is_none () =
  let log = [ mk_health_log "   " 1 ] in
  let health = Server_test_helpers.mk_health_state ~log "unhealthy" in
  check (option string) "blank is none" None
    (Blue_green.last_health_output health)

let test_health_detail_empty () =
  let health = Server_test_helpers.mk_health_state "unhealthy" in
  check string "no detail" "" (Blue_green.health_detail health)

let test_health_detail_streak_only () =
  let health =
    Server_test_helpers.mk_health_state ~failing_streak:3 "unhealthy"
  in
  check string "streak only" " (3 consecutive failures)"
    (Blue_green.health_detail health)

let test_health_detail_output_only () =
  let log = [ mk_health_log "connection refused" 1 ] in
  let health = Server_test_helpers.mk_health_state ~log "unhealthy" in
  check string "output only" " (last output: connection refused)"
    (Blue_green.health_detail health)

let test_health_detail_streak_and_output () =
  let log = [ mk_health_log "timeout" 1 ] in
  let health =
    Server_test_helpers.mk_health_state ~failing_streak:5 ~log "unhealthy"
  in
  check string "streak and output"
    " (5 consecutive failures, last output: timeout)"
    (Blue_green.health_detail health)

let () =
  run "Blue_green"
    [
      ( "success path",
        [
          test_case "with existing workload" `Quick
            test_plan_success_path_actions;
          test_case "no existing workload" `Quick
            test_plan_success_path_no_existing_workload;
        ] );
      ( "rollback",
        [
          test_case "rollback container name" `Quick
            test_plan_rollback_container_name;
        ] );
      ( "drain period",
        [
          test_case "uses configured drain period" `Quick
            test_plan_uses_configured_drain_period;
          test_case "default drain period" `Quick test_plan_default_drain_period;
        ] );
      ( "container naming",
        [
          test_case "temp container name" `Quick test_plan_temp_container_name;
          test_case "temp container carries the service name" `Quick
            test_blue_green_temp_container_carries_service_name;
        ] );
      ( "traefik labels",
        [
          test_case "labels on new container" `Quick
            test_plan_traefik_labels_on_new_container;
        ] );
      ( "restart policy",
        [
          test_case "new container carries the policy" `Quick
            test_run_new_container_carries_restart_policy;
        ] );
      ( "volumes",
        [
          test_case "new container carries mounts when replacing a workload"
            `Quick test_new_container_carries_mounts_when_replacing_a_workload;
          test_case "new container carries mounts on first deploy" `Quick
            test_new_container_carries_mounts_on_first_deploy;
          test_case "simple and blue-green mount identically" `Quick
            test_simple_and_blue_green_mount_identically;
        ] );
      ( "orphan cleanup",
        [
          test_case "orphaned container triggers cleanup first" `Quick
            test_plan_orphan_cleanup;
        ] );
      ( "last_health_output",
        [
          test_case "empty log" `Quick test_last_health_output_empty_log;
          test_case "returns last entry" `Quick
            test_last_health_output_returns_last;
          test_case "trims whitespace" `Quick
            test_last_health_output_trims_whitespace;
          test_case "blank is none" `Quick test_last_health_output_blank_is_none;
        ] );
      ( "health_detail",
        [
          test_case "empty" `Quick test_health_detail_empty;
          test_case "streak only" `Quick test_health_detail_streak_only;
          test_case "output only" `Quick test_health_detail_output_only;
          test_case "streak and output" `Quick
            test_health_detail_streak_and_output;
        ] );
    ]
