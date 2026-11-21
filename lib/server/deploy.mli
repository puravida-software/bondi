(** The [deploy] subcommand -- move the box to a new image, and write its cron
    jobs.

    This is what acts on a [bondi.yaml]. It plans the cron half of the request,
    chooses a deployment strategy, pulls what that strategy needs, converges the
    reverse proxy's restart policy, rolls the workload forward, writes each
    job's files and the crontab, and then removes the images the deploy left
    behind. A request that names no service is a cron-only deploy: it plans,
    writes the cron half, removes the old images, and touches no workload.

    The order is not incidental. The cron plan is pure and is refused first, so
    a job declaring a network Bondi does not manage is rejected before the
    service has moved to a new tag; the crontab is written after the workload,
    so a box whose deploy failed is not left firing jobs against an image that
    is not there. Image removal comes last of all, and only when every step
    before it succeeded, so it never runs while the old image may still be
    needed. It is cleanup: a removal Docker refuses -- an image a cron pass is
    still running from -- is one diagnostic line and never a failed deploy.

    Everything here besides {!deploy} is exposed for one of two reasons -- it is
    part of the answer the caller reads, or it is a pure seam the tests reach
    because the code around it needs a Docker client and an Eio net that a unit
    test has no business constructing. Nothing here is intended for another
    module to call in production. *)

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
  | Simple
      (** Pull the new image, then stop the old container and start the new one,
          so a pull that fails leaves the old container running. *)
  | Blue_green
      (** Start the new container alongside the old, wait for its health check,
          repoint the proxy, and only then stop the old one. *)

val string_of_deployment_strategy : deployment_strategy -> string
(** The wire name of a strategy: ["simple"] or ["blue-green"]. It is what the
    response reports and what a request declares, so the two cannot drift. *)

val deployment_strategy_of_string : string -> deployment_strategy option
(** Read the strategy a request declared. [None] for anything else, which
    {!deploy} reports to the caller rather than resolving to a default: a
    misspelled strategy must not silently deploy by the other one. *)

val registry_auth :
  Bondi_common.Image_reference.t ->
  user:string option ->
  pass:string option ->
  string option
(** The [X-Registry-Auth] header for pulling the reference: the Engine's
    [AuthConfig] holding both credentials, with [serveraddress] set to
    {!Bondi_common.Image_reference.registry}, port included, base64url-encoded
    with its padding kept, as the Engine API specifies the header. The service's
    pull and each cron job's pull build theirs here.

    A reference that names no registry but has a namespace ([myorg/app], a
    Docker Hub repository) sends the credentials with the first path component
    ([myorg]) as [serveraddress], exactly as earlier releases did, so a private
    Docker Hub repository's pull is handed the same credentials it was before.

    [None], and so no credentials sent at all, when either credential is absent
    or when the reference is a single component with no registry ([nginx]),
    which earlier releases never sent credentials for either. *)

val tag_from_image : Bondi_common.Image_reference.t -> string
(** The tag to report back in the response, ["unknown"] when the reference
    carries none, as a reference pinned only by digest does. This is reporting
    rather than validation -- refusing a reference with neither a tag nor a
    digest is the decoder's job, done before anything is planned or pulled, and
    a service image that gets here has one -- so it answers for every reference
    instead of failing beside a deploy that has already happened. *)

(** One step of a deploy that is not the workload itself. The list is produced
    by the two plan functions below and executed afterwards, so a request can be
    refused before anything on the box has moved. *)
type deploy_action =
  | EnsureCronNetwork
      (** Create the one network Bondi manages if it is absent. It carries no
          name because there is only ever that one, and it is idempotent, so any
          number of jobs declaring it plan a single action. *)
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

(** An image the deploy runs, to be pulled before anything on the box changes.
*)
type pull =
  | PullWorkload of Bondi_common.Image_reference.t
  | PullTraefik of Bondi_common.Image_reference.t
      (** Pulled without credentials. *)
  | PullCronImage of Strategy.Simple.cron_job
      (** Pulled with that job's own registry credentials. *)

val pull_plan :
  strategy:deployment_strategy ->
  workload_pulled:bool ->
  Strategy.Simple.deploy_input ->
  Strategy.Simple.deploy_context ->
  pull list
(** Every image the deploy needs, purely. {!deploy} runs the whole list before a
    restart policy is written, a container is stopped, removed or created, or
    the crontab is touched, so a pull that fails leaves the box as it was. The
    proxy is listed only when the simple strategy will create or replace it, and
    the workload is left out when [workload_pulled] says choosing the strategy
    already pulled it. A request with no service names no workload and no proxy.
*)

(** One step of a deploy, in the order [deploy] takes them. *)
type deploy_step =
  | Pull_images  (** Every image from {!pull_plan}; changes nothing. *)
  | Converge_restart_policy
  | Snapshot_replaced
  | Deploy_workload
  | Apply_cron
  | Clean_up  (** Image removal; last, and cannot fail the deploy. *)

val deploy_steps : has_service:bool -> deploy_step list
(** The whole deploy's order, purely. {!Pull_images} precedes every step that
    changes the box, on every strategy; a request with no service has no
    restart-policy write, snapshot or workload step. *)

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

    An image reference that does not parse, for the service, for Traefik or for
    a cron job, is refused here too, so no plan is made from a reference that
    could not be read. The refusal names the field and restates the grammar, but
    does not carry the rejected text: {!Handler_error.message} never carries a
    value from the payload, and a reference that failed to parse may hold a
    pasted credential.

    Refusals are [Invalid_request], so this decision carries an exit code like
    every other one this module makes. It is separate from {!deploy} rather than
    folded into it because the two failures answer with different wording, and a
    caller that has already decoded must not be made to re-encode. *)

val deploy :
  clock:_ Eio.Time.clock ->
  net:_ Eio.Net.t ->
  Strategy.Simple.deploy_input ->
  (deploy_response, Handler_error.t) result
(** The whole decision, naming no transport. The Docker client is built here
    rather than passed in because the registry credentials it carries come out
    of the request.

    Of the steps inside it, only the cron plan can answer [Invalid_request]: it
    is the one that fails on what the caller wrote. Everything after the cron
    plan is Bondi acting on the caller's behalf, so its failures are
    [Orchestrator_failure] by construction, and an exception escaping a gather
    or a strategy is reported as one too rather than escaping into the
    transport. [Eio.Cancel.Cancelled] is the exception to that: it propagates
    rather than being classified, because a cancelled fiber that returned a
    value would break structured concurrency.

    The other refusals of what the caller wrote, a body that does not decode and
    an image reference that does not parse, are {!decode_input}'s, made before
    this is called.

    Precondition: it drives Docker through Eio -- [Cohttp_eio] under an
    [Eio.Switch] -- so it must be called from inside an Eio fiber, and [~clock]
    and [~net] must be that fiber's own. Both are what
    {!Environment.with_environment} hands its callback, which is the one place
    this process enters the Eio runtime; a caller that passes capabilities from
    anywhere else is passing them across a runtime boundary they do not belong
    to. *)
