(** [POST /api/v1/deploy] -- move the box to a new image, and write its cron
    jobs.

    This is the endpoint that acts on a [bondi.yaml]. It plans the cron half of
    the request, chooses a deployment strategy, pulls what that strategy needs,
    converges the reverse proxy's restart policy, rolls the workload forward,
    and then writes each job's files and the crontab. A request that names no
    service is a cron-only deploy: it plans, writes the cron half, and touches
    no workload.

    The order is not incidental. The cron plan is pure and is refused first, so
    a job declaring a network Bondi does not manage is rejected before the
    service has moved to a new tag; the crontab is written last, so a box whose
    deploy failed is not left firing jobs against an image that is not there.

    Everything below {!route} is exposed for one of two reasons -- it is part of
    the wire contract, or it is a pure seam the tests reach because the code
    around it needs a Docker client and an Eio net that a unit test has no
    business constructing. Nothing here is intended for another module to call
    in production. *)

type deploy_response = {
  status : string;
  tag : string;
  strategy : string;
  strategy_reason : string;
}
(** The body of a successful deploy. [tag] is the tag that was deployed,
    ["unknown"] when the image carries none, and ["n/a"] when the request names
    no image at all, which is a cron-only deploy. [strategy_reason] says why
    [strategy] was the one that ran, so an operator who configured nothing can
    see what the image's [HEALTHCHECK] decided on their behalf. *)

val deploy_response_to_yojson : deploy_response -> Yojson.Safe.t
(** Encode a deploy response for the wire. *)

(** How the workload is rolled forward. The request may declare one; when it
    does not, the presence of a [HEALTHCHECK] on the image decides, because
    blue-green has nothing to wait for without one. *)
type deployment_strategy =
  | Simple  (** Stop the old container, then start the new one. *)
  | Blue_green
      (** Start the new container alongside the old, wait for its health check,
          repoint the proxy, and only then stop the old one. *)

val string_of_deployment_strategy : deployment_strategy -> string
(** The wire name of a strategy: ["simple"] or ["blue-green"]. It is what the
    response reports and what a request declares, so the two cannot drift. *)

val deployment_strategy_of_string : string -> deployment_strategy option
(** Read the strategy a request declared. [None] for anything else, which the
    endpoint reports to the caller rather than resolving to a default: a
    misspelled strategy must not silently deploy by the other one. *)

val serveraddress_from_image : string -> (string, string) result
(** The registry host an image name implies, for the [serveraddress] field of
    the Engine's [AuthConfig]. An image with no registry component yields an
    error rather than a guess, and the caller then sends no credentials at all:
    offering a password to the wrong registry is worse than failing to
    authenticate. *)

val image_name_and_tag : string -> (string * string, string) result
(** Split an image into its name and its tag. An image with no tag is refused: a
    pull with no tag is a pull of [latest], which is not the image the operator
    declared. *)

val tag_from_image : string -> string
(** The tag to report back in the response, ["unknown"] when the image carries
    none or does not parse. This is reporting rather than validation -- the
    refusal is {!image_name_and_tag}'s job -- so it answers for every input
    instead of failing beside a deploy that has already happened. *)

(** One step of a deploy that is not the workload itself. The list is produced
    by the two plan functions below and executed afterwards, so a request can be
    refused before anything on the box has moved. *)
type deploy_action =
  | EnsureCronNetwork
      (** Create the one network Bondi manages if it is absent. It carries no
          name because there is only ever that one, and it is idempotent, so any
          number of jobs declaring it plan a single action. *)
  | PullCronImages of Strategy.Simple.cron_job list
      (** Pull each declared job's image, with that job's own registry
          credentials. *)
  | UpsertCrontab of Strategy.Simple.cron_job list option
      (** Replace each job's files and the crontab with the declared set. A job
          gets a run file, which is the definition its crontab line points at,
          and an env file holding the secrets that definition deliberately does
          not carry. Both are written before the crontab, so no line is
          installed ahead of the files it reads.

          Every declared job is written even when it declares no secrets, so
          withdrawing a credential truncates the file rather than leaving the
          last one behind for the next run. *)
  | UpdateRestartPolicy of {
      container_id : string;
      restart_policy : Docker.Client.restart_policy;
    }  (** Write a restart policy onto a running container in place. *)

val cron_plan :
  Strategy.Simple.deploy_input -> (deploy_action list, Handler_error.t) result
(** Plan the cron half of a deploy, purely, from the request alone. A request
    declaring no jobs plans nothing. Two things are refused here, both by naming
    every offending job in one message rather than only the first, so the
    operator does not rediscover the next bad one on a later deploy.

    A job whose name could not be placed in a path is refused, by the same check
    that guards the write, because the interpreter that writes the job's files
    and its crontab line interpolates that name into three paths and carries no
    check of its own. Refusing here means nothing on the box has moved yet.

    A job declaring a network Bondi does not manage is refused too. That check
    compares against the one managed name and cannot see which networks exist on
    the box, so a network created by hand is invisible to it and every remedy
    the message offers is one the operator can apply in [bondi.yaml]. *)

type traefik_policy_context = {
  traefik : Docker.Client.container option;
  applied_policy : Docker.Client.restart_policy option;
}
(** The reverse proxy as a container listing reports it, together with the
    restart policy the daemon says it applied -- not the one it was asked for.
    [applied_policy] is absent when there is no proxy, when the daemon reports
    no policy, and when the read failed. The last of those is deliberately not
    distinguished from the others: a policy that cannot be read is already
    non-compliant, and a deploy must not be blocked on reading one. *)

val traefik_policy_plan :
  strategy:deployment_strategy ->
  Strategy.Simple.deploy_input ->
  traefik_policy_context ->
  deploy_action list
(** Plan the proxy's restart policy, purely. Nothing is planned when the request
    declares no proxy -- a box running one that the request no longer declares
    is corrected by declaring it again, not by writing to a container the
    request does not claim -- when the strategy in force is about to replace the
    proxy anyway, or when the applied policy already matches. The correction is
    written in place rather than by recreating: rebuilding the proxy to change
    one field would drop TLS for every site on the box. *)

val build_response :
  strategy:deployment_strategy ->
  strategy_reason:string ->
  Strategy.Simple.deploy_input ->
  deploy_response
(** The body of a successful deploy, purely from the request and the strategy
    that ran. *)

val decode_input :
  string -> (Strategy.Simple.deploy_input, Handler_error.t) result
(** Read a request body into the input {!deploy} acts on. A body that is not
    JSON and a body that is JSON of the wrong shape are both refused, each
    naming which it was, so an operator can tell a malformed file from a
    misdeclared one.

    Refusals are [Invalid_request], so this decision carries a status and an
    exit code like every other the endpoint makes, and a caller holding no HTTP
    request reaches it. It is separate from {!deploy} rather than folded into it
    because the two failures answer with different wording on the wire, and a
    caller that has already decoded must not be made to re-encode. *)

val deploy :
  clock:_ Eio.Time.clock ->
  net:_ Eio.Net.t ->
  Strategy.Simple.deploy_input ->
  (deploy_response, Handler_error.t) result
(** What the endpoint decides, naming no transport, so a caller holding no HTTP
    request can reach it. The Docker client is built here rather than passed in
    because the registry credentials it carries come out of the request.

    Only the cron plan can answer [Invalid_request]: it is the one step that
    fails on what the caller wrote. Everything after it is Bondi acting on the
    caller's behalf, so its failures are [Orchestrator_failure] by construction,
    and an exception escaping a gather or a strategy is reported as one too
    rather than escaping into the transport. [Eio.Cancel.Cancelled] is the
    exception to that: it propagates rather than being classified, because a
    cancelled fiber that returned a value would break structured concurrency.

    Precondition: it drives Docker through Eio -- [Cohttp_eio] under an
    [Eio.Switch] -- so it must be called from inside an Eio fiber, which in this
    process means under [Lwt_eio.with_event_loop]. {!route} supplies one with
    [Lwt_eio.run_eio]; a caller holding no HTTP request supplies its own, with
    [Eio_main.run] or the same wrapper. *)

val route : clock:_ Eio.Time.clock -> net:_ Eio.Net.t -> Dream.route
(** The [POST /api/v1/deploy] route. It decodes the request body, dispatches to
    {!deploy}, and encodes the answer as JSON or as the failure's own status and
    message. A body that does not decode is answered by {!decode_input}'s own
    status and never reaches {!deploy}; the two are worded differently on the
    wire -- a decode failure reads ["Bad request: "] and everything else reads
    ["Error deploying: "] -- which is why the decode is a step of its own. *)
