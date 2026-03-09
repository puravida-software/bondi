type collect_mode = Bondi_common.Alloy_river.collect_mode =
  | All
  | Services_only

type alloy_config = {
  image : string;
  grafana_cloud_endpoint : string;
  grafana_cloud_instance_id : string;
  grafana_cloud_api_key : string;
  collect : collect_mode;
  labels : (string * string) list;
  excluded_containers : string list;
}

type docker_config = {
  container_config : Client.container_config;
  host_config : Client.host_config;
}

let default_alloy_image = Bondi_common.Defaults.alloy_image
let collect_mode_of_string = Bondi_common.Alloy_river.collect_mode_of_string

let generate_river_config (config : alloy_config) : string =
  Bondi_common.Alloy_river.generate
    {
      grafana_cloud_endpoint = config.grafana_cloud_endpoint;
      grafana_cloud_instance_id = config.grafana_cloud_instance_id;
      grafana_cloud_api_key = config.grafana_cloud_api_key;
      collect = config.collect;
      labels = config.labels;
      excluded_containers = config.excluded_containers;
    }

let get_docker_config (config : alloy_config) : docker_config =
  let container_config : Client.container_config =
    {
      image = Some config.image;
      env =
        Some
          [
            "GRAFANA_CLOUD_INSTANCE_ID=" ^ config.grafana_cloud_instance_id;
            "GRAFANA_CLOUD_API_KEY=" ^ config.grafana_cloud_api_key;
          ];
      cmd = Some [ "run"; "/etc/bondi/alloy/config.alloy" ];
      entrypoint = None;
      hostname = None;
      working_dir = None;
      labels =
        Some
          [
            ("bondi.managed", "true");
            ("bondi.type", "infrastructure");
            ("bondi.logs", "false");
          ];
      exposed_ports = None;
    }
  in
  let host_config : Client.host_config =
    {
      binds =
        Some
          [
            "/var/run/docker.sock:/var/run/docker.sock:ro";
            "/etc/bondi/alloy/config.alloy:/etc/bondi/alloy/config.alloy:ro";
          ];
      port_bindings = None;
      network_mode = None;
      restart_policy =
        Some { Client.name = "unless-stopped"; maximum_retry_count = None };
    }
  in
  { container_config; host_config }
