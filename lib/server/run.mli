(** The [run] subcommand — execute one cron job in a container and report how it
    ended.

    One thing reaches it: the subcommand reads a job's run file on standard
    input and dispatches here, which is how the exec lines Bondi writes fire.
    This is where a scheduled job's failure becomes visible: what the subcommand
    writes to stderr and the document it writes to standard output are what
    reach cron's mail, and the payload's sinks are what reach the operator's
    alerting.

    Everything here besides {!run} is exposed for one of two reasons — it is
    part of the answer the caller reads, or it is a pure seam the tests reach
    because the code around it needs a Docker client and an Eio net that a unit
    test has no business constructing. Nothing but {!run} is intended for
    another module to call in production. *)

type run_payload = {
  job : string;
  image : string;
  network : string option;
  env_vars : Json_helpers.string_map option;
  alert_sinks : Bondi_common.Alert.sinks option;
  exit_code_severities : Strategy.Simple.exit_code_severities option;
}
(** The body of a run request, and the whole content of a job's run file:
    {!Crontab.run_payload_of_cron_job} encodes it at deploy time into the file
    {!Crontab.entry_of_cron_job}'s line hands to the [run] subcommand on
    standard input. The optional fields are omitted rather than written as
    [null], so a job that configures nothing produces the same bytes it did
    before those fields existed. Unknown fields are rejected: a misspelled key
    must not read as an unconfigured one. *)

type run_response = { exit_code : int; warning : string option }
(** The body of a successful run. [warning] reports a best-effort cleanup step
    that failed without affecting the run itself. *)

val run_payload_of_yojson : Yojson.Safe.t -> (run_payload, string) result
(** Decode a run request body. *)

val run_response_to_yojson : run_response -> Yojson.Safe.t
(** Encode a run result for the document the subcommand writes. *)

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

val cron_log_config :
  job:string -> labels:(string * string) list -> Docker.Client.log_config
(** The log driver a cron container runs with: the journal, tagged with the job,
    copying every label named in [labels] into the journal as a field. *)

val run_opts :
  container_name:string ->
  full_image:string ->
  run_payload ->
  Docker.Client.run_image_options
(** The Docker options that start one cron run: the pinned image, the job's
    environment, and the labels that let the run be discovered later as a Bondi
    cron container.

    The run logs through the [journald] driver, tagged with the job and with its
    [labels] option naming every one of those labels, so each line reaches the
    host journal however briefly the container lives. The driver's cache is left
    on, so [docker logs] still shows the run's output. The host config states no
    restart policy: a cron run is one-shot. *)

val combine_warnings : string option -> string option -> string option
(** Join two best-effort cleanup warnings into the single [warning] field,
    keeping both when both are present. *)

(** What is under a job's name when a run reads it, judged by the labels a run
    writes. *)
type existing =
  | No_container  (** Nothing is under the name. *)
  | Own_cron_container of string
      (** This job's cron container, by id: it carries both [bondi.type=cron]
          and [bondi.name] naming the job, so a finished run may replace it. *)
  | Foreign of string
      (** A container under the job's name, named here, that lacks either label:
          something this job did not make, which a run never removes, replaces
          or starts over. *)

val existing_of : job:string -> Docker.Client.container option -> existing
(** The verdict on the container found under [job]'s name, purely.

    Both labels are required. [bondi.type=cron] alone is not enough, because one
    job's container must never be taken for another's, and a [bondi.name] alone
    is what a managed container or a service carries too. *)

val start_unless_foreign :
  refuse:(string -> unit) ->
  lookup:(unit -> (existing, string) result) ->
  start:(unit -> (string, string) result) ->
  (string, string) result
(** Start the run, or refuse it, by the verdict this reads before the start.

    It takes the lookup rather than its result, so no caller can hand it a
    verdict that skips the guard: the read is made here, once, before anything
    starts. A lookup that fails is the start's failure and calls nothing that
    starts. Nothing under the name and the job's own container both call [start]
    and answer what it answered. A {!Foreign} container calls nothing that
    starts or removes: the refusal, naming the container, is handed to [refuse]
    and answered as the start's failure, so it reaches the answer and the alert
    by the same path a container that failed to start takes. {!run} passes
    {!Diagnostics.to_container_log} as [refuse]: the answer is what the
    subcommand prints on its own standard error, so the refusal is printed there
    once, and [refuse] only adds the container log's copy. *)

val cleanup_of_existing :
  refuse:(string -> unit) ->
  remove:(string -> string option) ->
  rename:(unit -> string option) ->
  lookup:(unit -> (existing, string) result) ->
  (string option, string) result
(** The post-run cleanup, by the verdict this reads once the pass finished.

    It takes the lookup rather than its result, so the name is read here, after
    the pass, and cannot be a verdict read earlier. The job's own container is
    removed by its id and the pass takes the name; with nothing under the name
    the pass only takes it. A {!Foreign} container, which took the name while
    the pass ran, is neither removed nor contended for: the refusal, naming it,
    is handed to [refuse] and answered as the [Error], and the pass's container
    keeps its temporary name. A name that could not be read removes nothing; the
    failed read is a warning beside the rename, as a failed removal or rename
    is, because the pass itself finished. *)

val warning_of_run :
  cleanup:(string -> (string option, string) result) ->
  started:(string, string) result ->
  run_result:(int, string) result ->
  (string option, string) result
(** Decide whether the post-run cleanup happens, and carry what it reported: a
    warning, or a refusal that fails the run.

    [cleanup] runs only when the container both started and finished. Removing
    the previous container before a failed run has been reported would destroy
    the only record of what ran last, and renaming a container that never
    started has nothing to rename. Taking [cleanup] as a parameter is what keeps
    this decision pure: {!run} supplies the Docker calls it needs, through
    {!cleanup_of_existing}. *)

val settle :
  cleaned:(string option, string) result ->
  (int, string) result ->
  (int, string) result * string option
(** The run's final result and its warning, once the cleanup has answered.

    A cleanup refusal turns a run that finished into a failure carrying the
    refusal, so the answer is an [Orchestrator_failure] and the alert is the one
    a run that never started raises. Otherwise the run's own result stands with
    the cleanup's warning beside it. *)

val prepare :
  deliver:
    (targets:Bondi_common.Alert.sink list ->
    payload:Bondi_common.Alert.payload ->
    unit) ->
  string ->
  (run_payload * string, Handler_error.t) result
(** Decode a request body and require an image that parses and is pinned by a
    tag or a digest, before anything is started. Returns the payload alongside
    the image to run, which is the reference as written, registry port and
    digest included.

    A payload that decoded names its job and carries its sinks, so a failure
    here dispatches an alert through [deliver] rather than short-circuiting past
    the dispatch point at the end of {!run}. A body that did not decode names no
    job and has nowhere to alert to; the crontab command's non-zero exit is its
    only failure channel. *)

val response_of_run_result :
  warning:string option ->
  (int, string) result ->
  (run_response, Handler_error.t) result
(** Classify the container lifecycle result. A container that ran to completion
    is a result whatever its exit code — a failing job is a successful run
    report — while a Docker-level failure is Bondi's fault, not the caller's. *)

val run :
  clock:'clock Eio.Time.clock ->
  client:Docker.Client.t ->
  net:'net Eio.Net.t ->
  deliver:
    (net:'net Eio.Net.t ->
    clock:'clock Eio.Time.clock ->
    targets:Bondi_common.Alert.sink list ->
    payload:Bondi_common.Alert.payload ->
    unit) ->
  string ->
  (run_response, Handler_error.t) result
(** The whole decision, naming no transport. Takes the request body as written
    and answers the response or the failure.

    [deliver] is taken in the shape {!Environment.with_environment} builds once
    per process, and the net and the clock it needs are bound here rather than
    by the caller: a caller that had to pre-bind them would be rebuilding part
    of this function, which is what this signature exists to make unnecessary.

    The container under the job's name is read before anything starts and read
    again before the cleanup, and judged both times by {!existing_of}. A run
    never removes, replaces or starts over a container that is not this job's
    own: one found before the start refuses the run with nothing started, and
    one found at cleanup is left in place while the pass keeps its temporary
    name. Either answers [Orchestrator_failure] naming the container, writes the
    same message to {!Diagnostics.write}, and alerts as a run that never
    started. A listing that fails before the start answers
    [Orchestrator_failure] with nothing started, as a start that failed does;
    one that fails at cleanup removes nothing and is a warning on the finished
    run.

    Alert delivery is a bounded, best-effort side channel run after the outcome
    is recorded and the container is cleaned up: it cannot change the answer,
    though being synchronous it may delay it by up to one timeout per sink. A
    body that did not decode names no job and reaches no sink; a body that did
    alerts even when it is refused before anything starts.

    Unlike {!Status.report} and {!Deploy.deploy}, this catches no exception. One
    that escapes is classified by the subcommand boundary in {!Cli}, which
    records the raw backtrace on the diagnostics stream before answering
    [Orchestrator_failure]; catching it here would answer the same class with
    the backtrace already lost.

    Precondition: it runs the container through Eio -- [Cohttp_eio] under an
    [Eio.Switch] -- so it must be called from inside an Eio fiber, and [~clock]
    and [~net] must be that fiber's own. Both are what
    {!Environment.with_environment} hands its callback, which is the one place
    this process enters the Eio runtime; a caller that passes capabilities from
    anywhere else is passing them across a runtime boundary they do not belong
    to. *)
