(** Pure classification and routing of a job run's outcome into alerts.

    A scheduled job run ends either with the container's exit code or with an
    orchestrator-level failure before it could start. This module maps that
    outcome to one of three Bondi-defined severities through a per-job exit-code
    map, and plans which sink URLs an alert is delivered to. It assigns no
    domain meaning to any exit code and performs no I/O: the whole
    classification and routing decision lives here so it is testable with plain
    data, leaving only the POST to an impure delivery module.

    The severity map and each sink are abstract with validating constructors, so
    an illegal map (an unknown severity name, a code claimed by two severities)
    or an illegal sink (a non-https or unparseable URL) cannot be represented.
*)

(** The three Bondi-defined severities. Only [Failure] and [Critical] route to
    sinks; [Success] never alerts. *)
type severity = Success | Failure | Critical

(** How a run ended. [Exited] carries the container exit code and is subject to
    the per-job map; [Start_failed] is an orchestrator-level failure with no
    exit code, carrying a diagnostic message. *)
type outcome = Exited of int | Start_failed of string

type severity_map
(** A per-job set of exit-code overrides atop the fixed defaults ([0] is
    [Success], any non-zero is [Failure]). Abstract: built only through
    {!severity_map_of_yojson}, which rejects any severity name outside the
    closed set and any exit code claimed by two severities, so an ambiguous or
    invented mapping is unrepresentable. *)

(** Why a severity map was rejected. [Unknown_severity] carries the offending
    key; [Duplicate_code] carries the exit code listed under two severities;
    [Malformed] carries a context label and the raw JSON value that was outside
    the expected shape (a non-integer code, a non-list value, or a non-object
    map), so the offending input is never dropped from the message. *)
type severity_map_error =
  | Unknown_severity of string
  | Duplicate_code of int
  | Malformed of string * Yojson.Safe.t

val severity_map_of_yojson :
  Yojson.Safe.t -> (severity_map, severity_map_error) result
(** Parse a map of the shape
    [{ "critical": [int], "failure": [int], "success": [int] }]. Every key must
    be one of the three known severities and no exit code may appear under two
    of them. Absent keys and a JSON [null] denote no overrides. *)

val severity_map_to_yojson : severity_map -> Yojson.Safe.t
(** Encode the overrides in the same shape {!severity_map_of_yojson} accepts,
    grouping the mapped codes under their severity. The defaults are implicit
    and never emitted. *)

val severity_map_error_to_string : severity_map_error -> string
(** A message naming the offending severity key or exit code, suitable for
    surfacing to whoever wrote the configuration. *)

val default_severity_map : severity_map
(** The bare defaults with no overrides: [0] is [Success], every non-zero code
    is [Failure]. *)

val severity_of_exit_code : severity_map -> int -> severity
(** Classify a container exit code through the map, falling back to the defaults
    for any code the map does not mention. *)

val severity_of_outcome : severity_map -> outcome -> severity
(** Classify a run outcome. [Start_failed] is always [Failure] and ignores the
    map (FR-2); [Exited n] consults {!severity_of_exit_code}. *)

type sink
(** A validated https POST target. Abstract: built only through
    {!sink_of_string}, so a sink is guaranteed to carry an https URL whose host
    is a valid RFC-1123 hostname, parsed once at construction. *)

(** Why a sink URL was rejected. [Not_https] and [Invalid_url] carry the
    offending URL; [Empty_url] carries nothing. A host that is not a valid
    hostname is reported as [Invalid_url]. *)
type sink_error = Empty_url | Not_https of string | Invalid_url of string

val sink_of_string : string -> (sink, sink_error) result
(** Validate a sink URL. It must be non-empty, use the [https] scheme, and carry
    a host that parses as a valid RFC-1123 hostname; plaintext [http],
    schemeless input, and hosts that are not valid hostnames are rejected, so a
    sink can never be posted to without TLS or with a host TLS cannot verify. *)

val sink_error_to_string : sink_error -> string
(** A message naming the rejected URL and why it was rejected. *)

val sink_url : sink -> string
(** The validated URL, as passed to {!sink_of_string}. *)

val sink_host : sink -> string
(** The host of the sink URL as a string, for redacted delivery-failure logging
    that never emits the full URL, which may embed a credential. *)

val sink_host_domain : sink -> [ `host ] Domain_name.t
(** The parsed, validated host, for wiring TLS certificate-hostname verification
    without re-parsing the URL at delivery time. *)

type sinks = { critical : sink list; failure : sink list }
(** The per-job sink sets by alerting severity. [Success] has no sinks by
    construction. *)

val sinks_of_yojson : Yojson.Safe.t -> (sinks, string) result
(** Parse [{ "critical": [url], "failure": [url] }], resolving each URL through
    {!sink_of_string}. An absent key denotes an empty set; the first invalid URL
    is surfaced as the error. *)

val sinks_to_yojson : sinks -> Yojson.Safe.t
(** Encode the sink sets in the shape {!sinks_of_yojson} accepts. *)

type payload
(** The generic, consumer-agnostic alert body. Abstract: built only by {!plan},
    so every payload reflects a real dispatch decision. Encodes the job name,
    severity, exit code and timestamp — nothing sink-specific and no secret
    material (FR-7). *)

val payload_to_yojson : payload -> Yojson.Safe.t
(** Encode the alert payload as JSON, ready to POST. *)

type dispatch = { targets : sink list; payload : payload }
(** A planned alert: the sinks to POST to and the body to send. *)

val plan :
  severity_map ->
  outcome ->
  sinks ->
  job:string ->
  timestamp:float ->
  dispatch option
(** Plan the alert for a run outcome. Returns [None] when the severity is
    [Success] or when the matched alerting severity has no configured sinks, so
    a severity with no sink emits nothing rather than falling back to an implied
    target (NFR-2). Otherwise returns the sinks for the matched severity and a
    payload carrying [job], the severity, the exit code (absent for
    [Start_failed]) and [timestamp]. *)
