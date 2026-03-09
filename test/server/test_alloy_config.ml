module Alloy = Bondi_server__Docker__Alloy

let base_config : Alloy.alloy_config =
  {
    image = "grafana/alloy:v1.8.0";
    grafana_cloud_endpoint = "https://logs-prod.grafana.net/loki/api/v1/push";
    grafana_cloud_instance_id = "123456";
    grafana_cloud_api_key = "glc_secret_key";
    collect = All;
    labels = [];
    excluded_containers = [];
  }

let test_river_config_all_mode () =
  let config = { base_config with collect = All } in
  let river = Alloy.generate_river_config config in
  Alcotest.check Alcotest.bool "contains discovery.docker" true
    (Bondi_common.String_utils.contains ~needle:"discovery.docker" river);
  Alcotest.check Alcotest.bool "contains bondi.managed label filter" true
    (Bondi_common.String_utils.contains ~needle:"bondi.managed" river);
  Alcotest.check Alcotest.bool "does not filter by bondi.type" false
    (Bondi_common.String_utils.contains ~needle:"bondi.type" river
    && Bondi_common.String_utils.contains ~needle:"drop" river
    && Bondi_common.String_utils.contains ~needle:"infrastructure" river)

let test_river_config_services_only () =
  let config = { base_config with collect = Services_only } in
  let river = Alloy.generate_river_config config in
  Alcotest.check Alcotest.bool "contains discovery.docker" true
    (Bondi_common.String_utils.contains ~needle:"discovery.docker" river);
  Alcotest.check Alcotest.bool "filters by bondi.type" true
    (Bondi_common.String_utils.contains ~needle:"bondi.type" river)

let test_river_config_excluded_containers () =
  let config =
    {
      base_config with
      excluded_containers = [ "my-debug-svc"; "noisy-worker" ];
    }
  in
  let river = Alloy.generate_river_config config in
  Alcotest.check Alcotest.bool "contains my-debug-svc exclusion" true
    (Bondi_common.String_utils.contains ~needle:"my-debug-svc" river);
  Alcotest.check Alcotest.bool "contains noisy-worker exclusion" true
    (Bondi_common.String_utils.contains ~needle:"noisy-worker" river)

let test_river_config_custom_labels () =
  let config =
    { base_config with labels = [ ("env", "production"); ("team", "backend") ] }
  in
  let river = Alloy.generate_river_config config in
  Alcotest.check Alcotest.bool "contains env label" true
    (Bondi_common.String_utils.contains ~needle:"env" river
    && Bondi_common.String_utils.contains ~needle:"production" river);
  Alcotest.check Alcotest.bool "contains team label" true
    (Bondi_common.String_utils.contains ~needle:"team" river
    && Bondi_common.String_utils.contains ~needle:"backend" river)

let test_river_config_grafana_cloud_auth () =
  let config = base_config in
  let river = Alloy.generate_river_config config in
  Alcotest.check Alcotest.bool "contains loki.write" true
    (Bondi_common.String_utils.contains ~needle:"loki.write" river);
  Alcotest.check Alcotest.bool "contains endpoint" true
    (Bondi_common.String_utils.contains
       ~needle:"https://logs-prod.grafana.net/loki/api/v1/push" river);
  Alcotest.check Alcotest.bool "uses env() for instance_id" true
    (Bondi_common.String_utils.contains
       ~needle:"env(\"GRAFANA_CLOUD_INSTANCE_ID\")" river);
  Alcotest.check Alcotest.bool "uses env() for api_key" true
    (Bondi_common.String_utils.contains ~needle:"env(\"GRAFANA_CLOUD_API_KEY\")"
       river);
  Alcotest.check Alcotest.bool "does not contain raw credentials" false
    (Bondi_common.String_utils.contains ~needle:"123456" river
    || Bondi_common.String_utils.contains ~needle:"glc_secret_key" river)

let test_collect_mode_of_string_valid () =
  Alcotest.check
    (Alcotest.result Alcotest.bool Alcotest.string)
    "all parses" (Ok true)
    (Result.map (fun m -> m = Alloy.All) (Alloy.collect_mode_of_string "all"));
  Alcotest.check
    (Alcotest.result Alcotest.bool Alcotest.string)
    "services_only parses" (Ok true)
    (Result.map
       (fun m -> m = Alloy.Services_only)
       (Alloy.collect_mode_of_string "services_only"))

let test_collect_mode_of_string_invalid () =
  let result = Alloy.collect_mode_of_string "unknown_mode" in
  Alcotest.check Alcotest.bool "returns error" true (Result.is_error result)

let test_docker_config_mounts () =
  let docker = Alloy.get_docker_config base_config in
  let binds =
    match docker.host_config.binds with
    | Some b -> b
    | None -> []
  in
  Alcotest.check Alcotest.bool "has docker socket mount (ro)" true
    (List.exists
       (fun b ->
         Bondi_common.String_utils.contains ~needle:"/var/run/docker.sock" b
         && Bondi_common.String_utils.contains ~needle:":ro" b)
       binds);
  Alcotest.check Alcotest.bool "has config file mount" true
    (List.exists
       (fun b -> Bondi_common.String_utils.contains ~needle:"config.alloy" b)
       binds);
  Alcotest.check Alcotest.bool "has restart policy unless-stopped" true
    (match docker.host_config.restart_policy with
    | Some rp -> rp.name = "unless-stopped"
    | None -> false);
  Alcotest.check Alcotest.bool "has correct image" true
    (docker.container_config.image = Some "grafana/alloy:v1.8.0");
  Alcotest.check Alcotest.bool "has credentials as env vars" true
    (match docker.container_config.env with
    | Some envs ->
        List.exists
          (fun e ->
            Bondi_common.String_utils.contains
              ~needle:"GRAFANA_CLOUD_INSTANCE_ID=" e)
          envs
        && List.exists
             (fun e ->
               Bondi_common.String_utils.contains
                 ~needle:"GRAFANA_CLOUD_API_KEY=" e)
             envs
    | None -> false);
  Alcotest.check Alcotest.bool "has bondi.logs=false label" true
    (match docker.container_config.labels with
    | Some labels -> List.mem ("bondi.logs", "false") labels
    | None -> false)

let test_docker_config_no_ports () =
  let docker = Alloy.get_docker_config base_config in
  Alcotest.check Alcotest.bool "no port bindings" true
    (match docker.host_config.port_bindings with
    | None -> true
    | Some [] -> true
    | Some _ -> false);
  Alcotest.check Alcotest.bool "no exposed ports" true
    (match docker.container_config.exposed_ports with
    | None -> true
    | Some [] -> true
    | Some _ -> false)

let () =
  Alcotest.run "Alloy config"
    [
      ( "river config",
        [
          Alcotest.test_case "all mode" `Quick test_river_config_all_mode;
          Alcotest.test_case "services only" `Quick
            test_river_config_services_only;
          Alcotest.test_case "excluded containers" `Quick
            test_river_config_excluded_containers;
          Alcotest.test_case "custom labels" `Quick
            test_river_config_custom_labels;
          Alcotest.test_case "grafana cloud auth" `Quick
            test_river_config_grafana_cloud_auth;
        ] );
      ( "collect_mode_of_string",
        [
          Alcotest.test_case "valid modes" `Quick
            test_collect_mode_of_string_valid;
          Alcotest.test_case "invalid mode" `Quick
            test_collect_mode_of_string_invalid;
        ] );
      ( "docker config",
        [
          Alcotest.test_case "mounts and basics" `Quick
            test_docker_config_mounts;
          Alcotest.test_case "no ports" `Quick test_docker_config_no_ports;
        ] );
    ]
