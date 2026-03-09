(** Alloy Docker container configuration and River config generation.

    This module builds Docker run options for the Alloy sidecar and delegates
    River config generation to {!Bondi_common.Alloy_river}. *)

(** Log collection scope. Re-exported from {!Bondi_common.Alloy_river} for
    convenience. *)
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
(** Full Alloy configuration including Docker image and Grafana Cloud
    credentials. The [image] field is used only for Docker container creation;
    River config generation uses the remaining fields. *)

type docker_config = {
  container_config : Client.container_config;
  host_config : Client.host_config;
}
(** Docker container and host configuration for running the Alloy container. *)

val default_alloy_image : string
(** Default pinned Alloy image version from {!Bondi_common.Defaults}. *)

val collect_mode_of_string : string -> (collect_mode, string) result
(** Parse ["all"] or ["services_only"]. Delegates to
    {!Bondi_common.Alloy_river.collect_mode_of_string}. *)

val generate_river_config : alloy_config -> string
(** Generate Alloy River configuration for log collection. Pure function —
    returns the config file content as a string. Delegates to
    {!Bondi_common.Alloy_river.generate}. *)

val get_docker_config : alloy_config -> docker_config
(** Build Docker container + host config for the Alloy container. Mounts Docker
    socket (read-only) for container discovery and the generated River config
    file. Restart policy: [unless-stopped]. No port bindings (push-only mode).
*)
