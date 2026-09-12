(** The [deploy] command: what each configured server is asked to run, and what
    it is asked over.

    The command's own wiring and the decisions it makes before it reaches a
    host. What a version means lives in {!Server_version}, what the box's two
    cron sources say about each other lives in {!Crontab_listing} and
    {!Cron_payload}, how the orchestrator's version is read lives in
    {!Orchestrator_version}, and how a command reaches a box lives in
    {!Remote_exec} — every one of them testable without a server. What is
    exposed here is what a test needs in order to pin this command's own
    decisions against hosts that do not exist: the payload it builds, the gate
    it applies, and the order it does the two in. The reads themselves, the
    bounds they are held to, and the sessions they are made over are this
    module's business and are not exposed. *)

type deploy_cron_job = {
  name : string;
  image : string;
  schedule : string;
  network : string option;
  env_vars : Config_file.string_map option;
  secret_env_vars : Config_file.string_map option;
  registry_user : string option;
  registry_pass : string option;
  alert_sinks : Bondi_common.Alert.sinks option;
  exit_code_severities : Config_file.exit_code_severities option;
}
(** One cron job as the server is told about it.

    Distinct from {!Config_file.cron_job}, which carries the server the job runs
    on: by the time a job is in a payload it has already been filtered to the
    server that payload is going to, so naming the server again would be sending
    a box a field it cannot disagree with. The image carries its tag, which the
    configuration's does not — the tag comes from the command line. *)

type deploy_payload = {
  service_name : string option;
  image : string option;
  port : int option;
  env_vars : Config_file.string_map;
  traefik_domain_name : string option;
  traefik_image : string option;
  traefik_acme_email : string option;
  registry_user : string option;
  registry_pass : string option;
  force_traefik_redeploy : bool option;
  cron_jobs : deploy_cron_job list option;
  drain_grace_period : float option;
  deployment_strategy : string option;
  health_timeout : float option;
  poll_interval : float option;
  logs : bool option;
}
(** Everything one server is asked to converge to, as the orchestrator's
    [deploy] subcommand reads it off its standard input.

    Every field is optional because a deploy is not obliged to name a service: a
    run that deploys cron jobs alone sends a payload whose service half is
    absent, and a box that received one changes nothing about the service it is
    already running. *)

val deploy_cron_job_to_yojson : deploy_cron_job -> Yojson.Safe.t
(** [deploy_cron_job_to_yojson job] is [job] as the orchestrator reads it.

    Exposed so a test can assert what actually goes over the wire for one job,
    field by field, rather than asserting the record it was built from — the
    record is this client's, and the JSON is the contract. *)

val deploy_payload_to_yojson : deploy_payload -> Yojson.Safe.t
(** [deploy_payload_to_yojson payload] is [payload] as the orchestrator reads
    it. Exposed for the same reason {!deploy_cron_job_to_yojson} is. *)

val deploy_payload_of_yojson : Yojson.Safe.t -> (deploy_payload, string) result
(** [deploy_payload_of_yojson json] reads a payload back.

    The client never decodes a payload in production — it only ever writes one.
    It is exposed so a test can round-trip what it encoded and show that the
    fields survive, which is what catches a field renamed on one side of the
    derivation only. *)

val parse_name_tag : string -> (string * string, string) result
(** [parse_name_tag s] splits a command-line [name:tag] into its two halves.

    A tag may itself contain colons, so the split is on the first one and the
    rest is the tag. An empty tag is a refusal rather than a default: [latest]
    is a moving target and deploying one by accident is how a box ends up
    running something nobody chose. *)

val cron_job_to_deploy : Config_file.cron_job -> image:string -> deploy_cron_job
(** [cron_job_to_deploy job ~image] is [job] as the server is told about it,
    with [image] carrying the tag this run was given. *)

val cron_jobs_for_server :
  string ->
  Config_file.cron_job list option ->
  (string * string) list ->
  deploy_cron_job list option
(** [cron_jobs_for_server ip_address cron_jobs deployments] is the jobs this run
    sends to the server at [ip_address].

    Two filters, in order: a job whose own server is a different box is not this
    box's to run, and a job this run was given no tag for is not being deployed
    at all. [None] and an empty list are the same thing to a caller and are
    answered as [None], because "this server has no cron jobs in this run" is
    what every later decision asks. *)

val validate_deployments :
  Config_file.t ->
  (string * string) list ->
  ((string * string) list, string) result
(** [validate_deployments config deployments] refuses a [name:tag] naming
    nothing in [config].

    Checked before any server is reached, because a mistyped target is a run
    that would otherwise deploy the targets it did recognise and report the typo
    afterwards. The first unknown name is enough: they are all the same mistake
    at the same keyboard, and the run stops either way. *)

val version_gate :
  read_version:(unit -> (string, string) result) ->
  deploy_cron_job list option ->
  (unit, string) result
(** [version_gate ~read_version cron_jobs] decides whether one server's
    orchestrator is new enough for the work it is about to be given.

    Every server is held to a floor, because a deploy reaches a box by running a
    subcommand inside the orchestrator's container and a binary from before
    there were subcommands answers that by ignoring its arguments and starting a
    second server against a port already bound. A server that is also having
    cron jobs written to it is held to the higher floor alone — writing the
    exec-shaped crontab line is the later capability and the release that
    carries it carries the subcommands by construction, so asking the lower
    question as well could only refuse the same box against a number that sends
    the operator to an image which is still going to be refused.

    [read_version] is a parameter rather than something called ahead of the
    decision so that this is a decision made from a value, testable against a
    box that does not exist. It is called once, so a server is read once. *)

val reported_orchestrator_version :
  ?session:Remote_exec.session -> Config_file.server -> (string, string) result
(** [reported_orchestrator_version server] is the reader {!version_gate} is
    handed in production: {!Orchestrator_version.read}, worded as a deploy
    reports a box it could not read.

    A server with no [ssh] block is answered from the configuration before
    anything is spawned, and is told so — nothing about it failed to be read,
    and rendering it with the failures of the network would send an operator
    whose bondi.yaml is missing a block looking in the wrong place. Every other
    refusal says the version could not be read and that no deploy is sent to a
    server whose image has not been seen.

    [session] is the staged key the read is made over, optional so that a caller
    which has not opened one still gets its answer. *)

val cron_divergence_report :
  server:string ->
  read_crontab:(unit -> (string, Remote_exec.failure) result) ->
  read_payloads:(unit -> (string, Remote_exec.failure) result) ->
  deploy_cron_job list option ->
  string list
(** [cron_divergence_report ~server ~read_crontab ~read_payloads cron_jobs] is
    what the box's two cron sources say about each other, as the lines to print.

    Asked only when this server has cron jobs to write, which is why the readers
    are parameters rather than something called ahead of the decision: a
    service-only deploy neither consults the box nor pays for the round trips.
    That scope is a stated limit — a job withdrawn from bondi.yaml leaves its
    files behind and no deploy that sends no cron jobs can see them;
    [bondi status] reads both sources unconditionally and is where that is
    caught.

    It answers lines and never a verdict. A divergence changes no exit code and
    stops no deploy: refusing would block the very command that repairs it, and
    would refuse on the strength of a remote read that can itself fail. Each
    reader's outcome is handed to the module that owns it, so a spool the host
    refused stays distinguishable from a host that answered "no section". *)

val deploy_exec_command : string
(** The [docker] argument list that runs the orchestrator's own [deploy]
    subcommand inside the container it runs in.

    [-i] is what keeps this machine's standard input open through to it, which
    is how the payload gets there — the payload is never an argument, because it
    carries registry credentials and environment values and a command line is
    readable by every process on the box. The [docker] is not spelled here: the
    runner supplies it, so no call site can spell it differently. *)

val deploy_outcome :
  ip_address:string ->
  (string, Remote_exec.failure) result ->
  (unit, string) result
(** [deploy_outcome ~ip_address outcome] is what the box at [ip_address]
    answered, as an operator reads it.

    The box's own words are carried rather than replaced. An orchestrator that
    refused says why on its error stream; a container that is not there, a
    daemon that refused, or an image whose binary knows no such subcommand each
    answer in words no orchestrator would have written, and those are exactly
    the words that name the problem.

    What the box wrote on success is not read. The exit code is the verdict, and
    a client that parsed the report would begin refusing deploys that had
    succeeded the first time that report gained a field. *)

val deploy_servers :
  read_version:(Config_file.server -> (string, string) result) ->
  deploy:
    (Config_file.server -> deploy_cron_job list option -> (unit, string) result) ->
  (Config_file.server * deploy_cron_job list option) list ->
  (unit, string list) result
(** [deploy_servers ~read_version ~deploy servers_with_jobs] is the whole of
    what this command does to the servers it was given: every one of them is
    gated, and only then is any one of them deployed to.

    A refusal that arrived after the first box had been written to would not be
    a refusal, and the order of those two phases is the only thing that makes it
    one — so the reader and the deployer are parameters and the order is
    observable without a box to run against.

    Every refusal is reported, and so is every failed deploy: an operator with
    two boxes to upgrade, or two boxes that refused the payload, should learn
    that from one run, and the terminal these lines are printed to shows all of
    them. Every server is still attempted, because a box that has already been
    deployed to is not made better by abandoning the next. *)

val cmd : unit Cmdliner.Cmd.t
(** The command as [bondi deploy]. *)
