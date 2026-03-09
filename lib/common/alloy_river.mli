(** Pure Alloy River configuration generation.

    This module produces Alloy River config strings for log collection from
    Bondi-managed Docker containers. It is platform-independent and used by both
    client (setup) and server (docker/alloy) code. *)

(** Log collection scope. [All] collects from every Bondi-managed container;
    [Services_only] restricts to service and cron containers. *)
type collect_mode = All | Services_only

type config = {
  grafana_cloud_endpoint : string;
  grafana_cloud_instance_id : string;
  grafana_cloud_api_key : string;
  collect : collect_mode;
  labels : (string * string) list;
  excluded_containers : string list;
}
(** Inputs for River config generation. *)

val collect_mode_of_string : string -> (collect_mode, string) result
(** Parse ["all"] or ["services_only"]. Returns [Error] with a clear message for
    any other input. *)

val generate : config -> string
(** Generate a complete Alloy River configuration for log collection. Pure
    function — returns the config file content as a string.

    The generated config:
    - Discovers containers via Docker socket with [bondi.managed=true]
    - Filters by collect mode when [Services_only]
    - Drops containers with [bondi.logs=false] label
    - Drops containers matching [excluded_containers] names
    - Attaches user-provided [labels] as external labels
    - Forwards to Grafana Cloud endpoint with basic auth credentials referenced
      via [env("GRAFANA_CLOUD_INSTANCE_ID")] and [env("GRAFANA_CLOUD_API_KEY")]
      — credentials are not baked into the config file; they must be provided as
      environment variables to the Alloy container *)
