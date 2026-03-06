open Alcotest
module Blue_green = Bondi_server__Strategy__Blue_green
module Docker = Bondi_server__Docker__Client
module Simple = Bondi_server__Strategy__Simple

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
        | _ -> false)
      plan.success_path
  in
  match drain_action with
  | Some (Blue_green.DrainGracePeriod { seconds }) ->
      check (float 0.01) "drain period" 5.0 seconds
  | _ -> Alcotest.fail "expected DrainGracePeriod action"

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
        | _ -> false)
      plan.success_path
  in
  match drain_action with
  | Some (Blue_green.DrainGracePeriod { seconds }) ->
      check (float 0.01) "default drain period" 2.0 seconds
  | _ -> Alcotest.fail "expected DrainGracePeriod action"

let test_plan_temp_container_name () =
  let plan = Blue_green.plan base_config context_with_workload in
  let run_action =
    List.find_opt
      (function
        | Blue_green.RunNewContainer _ -> true
        | _ -> false)
      plan.success_path
  in
  match run_action with
  | Some (Blue_green.RunNewContainer { container_name; _ }) ->
      check string "temp container name" "my-service-new" container_name
  | _ -> Alcotest.fail "expected RunNewContainer action"

let test_plan_traefik_labels_on_new_container () =
  let plan = Blue_green.plan base_config context_with_workload in
  let run_action =
    List.find_opt
      (function
        | Blue_green.RunNewContainer _ -> true
        | _ -> false)
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
  | _ -> Alcotest.fail "expected RunNewContainer action"

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
  let first_action = List.hd plan.success_path in
  check string "first action is cleanup" "CleanupOrphanedContainer(orphan-id)"
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
        [ test_case "temp container name" `Quick test_plan_temp_container_name ]
      );
      ( "traefik labels",
        [
          test_case "labels on new container" `Quick
            test_plan_traefik_labels_on_new_container;
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
