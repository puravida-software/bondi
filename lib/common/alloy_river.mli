(** Pure Alloy River configuration generation.

    This module produces Alloy River config strings for log collection from
    Bondi-managed Docker containers. It is platform-independent and used by both
    client (setup) and server (docker/alloy) code. *)

(** Log collection scope. [All] collects from every Bondi-managed container;
    [Services_only] restricts to service and cron containers. Cron containers
    are collected from the journal under either mode. *)
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

    The generated config reads from two sources. The Docker source:
    - Discovers containers via Docker socket with [bondi.managed=true]
    - Drops [bondi.type] [cron], under either mode
    - Keeps only [bondi.type] [service] when [Services_only]
    - Drops containers with [bondi.logs=false] label, under either mode
    - Drops containers whose name contains one of [excluded_containers]
    - Sets a [container] label on every kept target: the container's
      [bondi.name] label when it is non-empty, otherwise the container name
      without Docker's leading [/]

    The journal source, the same under either mode:
    - Reads the host journal at [/var/log/journal], only entries carrying both
      [BONDI_MANAGED=true] and [BONDI_TYPE=cron]
    - Drops entries with [bondi.logs=false], and entries whose container name
      contains one of [excluded_containers]
    - Sets [container] the same way the Docker source does, from the container
      name and then [bondi.name]
    - Drops the [job] label the journal source adds, so a cron stream carries
      the labels a service stream does

    Both sources:
    - Forward to one writer, so both carry its external labels
    - Attach user-provided [labels] as external labels
    - Forward to the Grafana Cloud endpoint with basic auth credentials
      referenced via [sys.env("GRAFANA_CLOUD_INSTANCE_ID")] and
      [sys.env("GRAFANA_CLOUD_API_KEY")] — credentials are not baked into the
      config file; they must be provided as environment variables to the Alloy
      container

    The rules read container labels by the names Alloy's Docker discovery gives
    them, never by their Docker spelling: a label [bondi.x] reaches a target as
    [__meta_docker_container_label_bondi_x]. A rule naming [bondi.x] itself
    reads an empty value on every target, so it would keep nothing or drop
    nothing.

    Cron containers are read from the journal because a pass can exit before
    discovery, which lists running containers once a minute, ever sees it. Most
    passes would ship nothing, and a pass discovery did list would ship twice if
    the Docker source kept it too. A cron container logs through Docker's
    [journald] driver, which writes each [bondi.*] label it is told to copy as a
    journal field of its own.

    The journal rules follow the same rule as the Docker ones, under the names
    the journal source gives: a label [bondi.x] is written as the field
    [BONDI_X] and reaches a rule as [__journal_bondi_x], and the container name
    as [__journal_container_name], with no leading [/]. The driver writes no
    field for a label the container lacks, and an empty one for a label set to
    the empty string, so [bondi.name] falls back to the container name on both.

    The config reads [/var/log/journal] unconditionally. Alloy refuses to load
    it where that path does not exist, so the Alloy container must mount the
    host journal there.

    [bondi.name] carries the workload's name, which the container name does not
    always: a cron pass runs under a timestamped name and a blue-green candidate
    under a temporary one, so the container name alone would give each pass or
    deploy a log stream of its own. The fallback labels containers started
    before they carried [bondi.name]. *)

val env_file_contents : config -> string
(** The environment file the generated River configuration reads its Grafana
    Cloud credentials from: one [KEY=VALUE] line for each variable {!generate}
    references through [sys.env].

    It lives beside {!generate} because the two are halves of one contract. A
    variable named in one and not the other is a container that starts, reports
    itself healthy, and ships nothing — Alloy resolves a missing [sys.env] to
    the empty string rather than refusing to run, so the drift has no symptom at
    the point it is introduced. *)
