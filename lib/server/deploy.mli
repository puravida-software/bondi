(** The [deploy] subcommand -- move the box to a new image, and write its cron
    jobs.

    This is what acts on a [bondi.yaml]. It plans the cron half of the request,
    chooses a deployment strategy, pulls every image the deploy needs, refuses a
    workload image that declares its router's middlewares, converges the reverse
    proxy's restart policy and then the proxy itself, whichever strategy is
    chosen, rolls the workload forward, writes each job's files and the crontab,
    and then removes the images the deploy left behind. A request that names no
    service is a cron-only deploy: it plans, writes the cron half, removes the
    old images, and touches no workload.

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
    does not, a service with no proxy is {!Simple}, and otherwise the presence
    of a [HEALTHCHECK] on the image decides, because blue-green has nothing to
    wait for without one. See {!strategy_choice}. *)
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

val auto_strategy : Docker.Client.image_inspect_response -> deployment_strategy
(** The strategy an image selects when the request declares none, purely from
    the image's [Config.Healthcheck]. Only a [Test] of [CMD] or [CMD-SHELL] is a
    health check and selects {!Blue_green}. [HEALTHCHECK NONE], which reports a
    [Test] of [["NONE"]], selects {!Simple}, as an image with no health check
    does: blue-green would wait for a health that never comes. *)

val auto_selection :
  Docker.Client.image_inspect_response -> deployment_strategy * string
(** {!auto_strategy} with the reason it gives, for the response. A [Test] whose
    first word is neither a probe, [NONE] nor empty selects {!Simple} under a
    reason that names the word, and is not reported as the image having no
    [HEALTHCHECK]. *)

val strategy_choice :
  Strategy.Simple.deploy_input ->
  ( Docker.Client.image_inspect_response -> deployment_strategy * string,
    Handler_error.t )
  result
(** The strategy a service deploy runs under, and the reason the response gives
    for it. It is decided from the request first and from the image second, so
    the result is either a refusal or the choice still to be applied to the
    image's inspect: every refusal is made before the image is pulled, and no
    refusal can depend on what the image declares.

    A declared strategy runs as declared, for the reason
    ["configured in bondi.yaml"], except blue-green on a request with no
    [traefik_domain_name]: blue-green switches traffic through the proxy, so
    with none it is refused as [Invalid_request], naming the service. Left to
    choose, a request with no domain is {!Simple} for the reason
    ["no traefik: block"], whatever the image's health check, and one with a
    domain is {!auto_selection} of the image. A declared strategy that is not
    one is refused as [Orchestrator_failure], naming it. *)

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

val managed_container_names : Docker.Client.container list -> string list
(** The names the managed containers in a listing run under, without the leading
    [/] the Engine reports them with. A container is managed when it carries
    {!Bondi_common.Managed_container.type_label}; a cron run's container and an
    unlabelled one are left out. {!deploy} reads these off the box for
    {!cron_plan}, because the request carries no managed containers. *)

val service_names_of :
  Docker.Client.container list -> Bondi_common.Router_name.t list
(** The services in a listing: a container labelled [bondi.type=service] gives
    its [bondi.name], when that is a router name. The blue-green candidate
    [<service>-new] is the same container under a temporary name and carries the
    same label, so it gives the same service. Managed and cron containers and
    unlabelled ones give none. {!deploy} reads these off the box for
    {!cron_plan}, because a cron-only request carries no service name. *)

val cron_plan :
  managed_containers:string list ->
  box_services:Bondi_common.Router_name.t list ->
  Strategy.Simple.deploy_input ->
  (deploy_action list, Handler_error.t) result
(** Plan the cron half of a deploy, purely, from the request and
    [managed_containers], the names of the managed containers on the box, which
    the request does not carry, and [box_services], the services on the box,
    which stand in for the service's names when the request declares no service
    (a cron-only deploy) and are ignored when it does. There is no default: a
    plan that assumed the box held none would accept a job named like one. A
    request declaring no jobs plans nothing. Four things are refused here, each
    by naming every offending job in one message rather than only the first, so
    the operator does not rediscover the next bad one on a later deploy. Every
    refusal is [Invalid_request].

    A job whose name could not be placed in a path is refused, by the same check
    that guards the write, because the interpreter that writes the job's files
    and its crontab line interpolates that name into three paths and carries no
    check of its own. Refusing here means nothing on the box has moved yet.

    A job whose name is already in use is refused, by
    {!Bondi_common.Cron_job_name.collisions}, the rule the client applies too: a
    built-in container's name, the service's, its blue-green candidate's
    ([<service>-new]), a name in [managed_containers], or another job's. A job
    container takes its job's name, so a clash would fail the run or have its
    cleanup remove the container that held the name. The message names the job
    and what holds the name.

    A secret entry {!Bondi_common.Env_entry.check} refuses is refused, naming
    the job and the key and never the value. The entry is a line of the job's
    env file, and a control character in it, newline included, would be a second
    entry. The client refuses it as well, but this side writes the file.

    A job declaring a network Bondi does not manage is refused too. That check
    compares against the one managed name and cannot see which networks exist on
    the box, so a network created by hand is invisible to it and every remedy
    the message offers is one the operator can apply in [bondi.yaml]. *)

val proxy_plan :
  Strategy.Simple.deploy_input ->
  current_traefik:Docker.Client.container option ->
  Proxy.action list
(** The reverse proxy's convergence, purely, from the request and the container
    a lookup by the proxy's name returned. It is the same under every strategy:
    the proxy is a property of the box, not of how the workload is rolled
    forward. A request that declares no proxy (no Traefik image, domain and ACME
    email) plans nothing at all, even on a box running one. Otherwise the plan
    is [Proxy.plan] of [Proxy.decide]: a proxy that is created or replaced is
    pulled before anything of it is stopped. *)

(** An image the deploy runs, to be pulled before anything on the box changes.
*)
type pull =
  | PullWorkload of Bondi_common.Image_reference.t
  | PullTraefik of Bondi_common.Image_reference.t
      (** Pulled without credentials. *)
  | PullCronImage of Strategy.Simple.cron_job
      (** Pulled with that job's own registry credentials. *)

val pull_plan :
  workload_pulled:bool ->
  Strategy.Simple.deploy_input ->
  current_traefik:Docker.Client.container option ->
  pull list
(** Every image the deploy needs, purely. {!deploy} runs the whole list before a
    restart policy is written, a container is stopped, removed or created, or
    the crontab is touched, so a pull that fails leaves the box as it was. The
    proxy is listed whenever {!proxy_plan} will create or replace it, whatever
    the strategy, and the workload is left out when [workload_pulled] says
    choosing the strategy already pulled it. A request with no service names no
    workload and no proxy. *)

val image_label_check :
  Strategy.Simple.deploy_input ->
  Docker.Client.image_inspect_response ->
  (unit, Handler_error.t) result
(** Refuse a service whose image declares, in its own [Config.Labels], the
    middlewares of the service's router
    ([traefik.http.routers.<service>.middlewares]), purely, from the pulled
    image's inspect. Bondi writes that label on the container itself, to give
    the router its retry middleware, and a label set at create replaces the
    image's, so the image's middlewares would be dropped without a word. The
    refusal is [Invalid_request], naming the label and the image: the remedy is
    the caller's, in the image. Any other label, and a request naming no service
    or no image, passes. *)

(** One step of a deploy, in the order [deploy] takes them. *)
type deploy_step =
  | Pull_images  (** Every image from {!pull_plan}; changes nothing. *)
  | Check_image_labels
      (** {!image_label_check} on the inspect of the pulled workload image;
          changes nothing. *)
  | Validate_workload
      (** Every refusal the workload can meet, made purely, so a request the
          workload cannot be built from is refused before the proxy is touched;
          changes nothing. *)
  | Gather_workload
      (** What blue-green plans from, including what is under [<name>-new], read
          before anything moves; changes nothing. *)
  | Converge_restart_policy
  | Snapshot_replaced
      (** Record the images the proxy and the workload hold, before either is
          replaced. *)
  | Converge_proxy  (** {!proxy_plan}, under every strategy. *)
  | Deploy_workload
  | Apply_cron
  | Clean_up  (** Image removal; last, and cannot fail the deploy. *)

val deploy_steps : has_service:bool -> deploy_step list
(** The whole deploy's order, purely. {!Pull_images} precedes every step that
    changes the box, on every strategy, {!Check_image_labels},
    {!Validate_workload} and {!Gather_workload} follow it ahead of them all, and
    the proxy converges after the snapshot and before the workload moves. A
    request with no service has no label check, restart-policy write, snapshot,
    proxy or workload step. *)

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
  Strategy.Simple.deploy_input -> traefik_policy_context -> deploy_action list
(** Plan the proxy's restart policy, purely. Nothing is planned when the request
    declares no proxy -- a box running one that the request no longer declares
    is corrected by declaring it again, not by writing to a container the
    request does not claim -- when {!proxy_plan} is about to replace the proxy
    anyway, whatever the strategy, or when the applied policy already matches.
    The correction is written in place rather than by recreating: rebuilding the
    proxy to change one field would drop TLS for every site on the box. *)

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

    A cron job's schedule outside {!Bondi_common.Cron_schedule}'s grammar is
    refused here as well, before it can reach root's crontab. That refusal names
    the job, since a payload can carry several.

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

    Of the steps inside it, three can answer [Invalid_request], because they
    fail on what the caller supplied: the cron plan, {!strategy_choice} on a
    service declaring blue-green with no proxy, made before anything is pulled,
    and {!image_label_check} on the image the caller built. Everything else is
    Bondi acting on the caller's behalf, so its failures are
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
