(** [POST /api/v1/run] — execute one cron job in a container and report how it
    ended.

    The crontab lines Bondi writes call this endpoint. That makes it the place
    where a scheduled job's failure becomes visible: the response status and
    body are what reach cron's mail, and the payload's sinks are what reach the
    operator's alerting.

    Everything below {!route} is exposed for one of two reasons — it is part of
    the wire contract, or it is a pure seam the tests reach because the code
    around it needs a Docker client and an Eio net that a unit test has no
    business constructing. Nothing here is intended for another module to call
    in production. *)

type run_payload = {
  job : string;
  image : string;
  network : string option;
  env_vars : Json_helpers.string_map option;
  alert_sinks : Bondi_common.Alert.sinks option;
  exit_code_severities : Strategy.Simple.exit_code_severities option;
}
(** The body of a run request, as written into the crontab line by
    {!Crontab.entry_of_cron_job}. The optional fields are omitted rather than
    sent as [null], so a job that configures nothing produces the same bytes it
    did before those fields existed. Unknown fields are rejected: a misspelled
    key must not read as an unconfigured one. *)

type run_response = { exit_code : int; warning : string option }
(** The body of a successful run. [warning] reports a best-effort cleanup step
    that failed without affecting the run itself. *)

val run_payload_of_yojson : Yojson.Safe.t -> (run_payload, string) result
(** Decode a run request body. *)

val run_response_to_yojson : run_response -> Yojson.Safe.t
(** Encode a run result for the HTTP response. *)

(** Why a run request did not produce a result. The distinction is what the
    endpoint's status is chosen from, so it is a variant rather than a string:
    the caller's mistake and Bondi's own fault are not the same event and must
    not be reported as though they were. *)
type run_error =
  | Invalid_request of string
      (** The request could not be acted on as written — a body that does not
          decode, or an image with no tag. *)
  | Orchestrator_failure of string
      (** Bondi could not carry out a well-formed request. *)

val run_error_message : run_error -> string
(** The human-readable half of a failure, without its classification. Never
    contains a value taken from the rejected payload: run payloads carry
    environment variables and sink URLs that may embed credentials, and this
    text is returned over HTTP and mailed by cron. *)

val status_of_run_error : run_error -> Dream.status
(** The HTTP status for a failure class: 400 for {!Invalid_request}, 500 for
    {!Orchestrator_failure}. Kept next to the variant so that adding a class
    forces a status to be chosen for it, rather than defaulting inside the
    handler. *)

val outcome_of_result : (int, string) result -> Bondi_common.Alert.outcome
(** Classify how a run ended for alerting: a container that completed reports
    its exit code, and a failure before or at start reports as never having run.
*)

val plan_for_payload :
  run_payload ->
  Bondi_common.Alert.outcome ->
  timestamp:float ->
  Bondi_common.Alert.dispatch option

(** Route an outcome to the sinks the payload configured, purely. A job that
    configures no severity map falls to the default one and a job that
    configures no sinks routes nowhere, so an unconfigured job plans no alert
    rather than an implied one. Separate from delivery so the routing is
    testable without a clock or a network. *)

val networking_conf_of_network :
  string option -> Docker.Client.networking_config option
(** The Docker networking configuration for a declared network, or none when the
    job declares no network and stays on the default bridge. *)

val run_opts :
  container_name:string ->
  full_image:string ->
  run_payload ->
  Docker.Client.run_image_options
(** The Docker options that start one cron run: the pinned image, the job's
    environment, and the labels that let the run be discovered later as a Bondi
    cron container. *)

val combine_warnings : string option -> string option -> string option
(** Join two best-effort cleanup warnings into the single [warning] field,
    keeping both when both are present. *)

val warning_of_run :
  cleanup:(string -> string option) ->
  started:(string, string) result ->
  run_result:(int, string) result ->
  string option
(** Decide whether the post-run cleanup happens, and carry what it reported.

    [cleanup] runs only when the container both started and finished. Removing
    the previous container before a failed run has been reported would destroy
    the only record of what ran last, and renaming a container that never
    started has nothing to rename. Taking [cleanup] as a parameter is what keeps
    this decision pure: {!run} supplies the Docker calls it needs. *)

val prepare :
  deliver:
    (targets:Bondi_common.Alert.sink list ->
    payload:Bondi_common.Alert.payload ->
    unit) ->
  string ->
  (run_payload * string, run_error) result
(** Decode a request body and require a tagged image, before anything is
    started. Returns the payload alongside the fully-qualified image.

    A payload that decoded names its job and carries its sinks, so a failure
    here dispatches an alert through [deliver] rather than short-circuiting past
    the dispatch point at the end of {!run}. A body that did not decode names no
    job and has nowhere to alert to; the crontab command's non-zero exit is its
    only failure channel. *)

val response_of_run_result :
  warning:string option ->
  (int, string) result ->
  (run_response, run_error) result
(** Classify the container lifecycle result. A container that ran to completion
    is a result whatever its exit code — a failing job is a successful run
    report — while a Docker-level failure is Bondi's fault, not the caller's. *)

val route :
  clock:'clock ->
  client:Docker.Client.t ->
  net:([> [> `Generic ] Eio.Net.ty ] as 'net) Eio.Resource.t ->
  deliver:
    (net:'net Eio.Resource.t ->
    clock:'clock ->
    targets:Bondi_common.Alert.sink list ->
    payload:Bondi_common.Alert.payload ->
    unit) ->
  Dream.route
(** The [POST /api/v1/run] route.

    Alert delivery is a bounded, best-effort side channel run after the outcome
    is recorded: it cannot change the status or body this route returns, though
    being synchronous it may delay the response by up to one timeout per sink.
*)
