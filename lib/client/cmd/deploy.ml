let ( let* ) = Result.bind

(* Cron job for deploy payload - excludes server (server filters which jobs to send per target) *)
type deploy_cron_job = {
  name : string;
  image : string;
  schedule : string;
  network : string option; [@default None]
  env_vars : Config_file.string_map option; [@default None]
  secret_env_vars : Config_file.string_map option; [@default None]
  registry_user : string option; [@default None]
  registry_pass : string option; [@default None]
  alert_sinks : Bondi_common.Alert.sinks option; [@default None]
  exit_code_severities : Config_file.exit_code_severities option; [@default None]
}
[@@deriving yojson]

type deploy_payload = {
  service_name : string option; [@default None]
  image : string option; [@default None]
  port : int option; [@default None]
  env_vars : Config_file.string_map;
  traefik_domain_name : string option; [@default None]
  traefik_image : string option; [@default None]
  traefik_acme_email : string option; [@default None]
  registry_user : string option; [@default None]
  registry_pass : string option; [@default None]
  force_traefik_redeploy : bool option; [@default None]
  cron_jobs : deploy_cron_job list option; [@default None]
  drain_grace_period : float option; [@default None]
  deployment_strategy : string option; [@default None]
  health_timeout : float option; [@default None]
  poll_interval : float option; [@default None]
  logs : bool option; [@default None]
}
[@@deriving yojson]

let parse_name_tag s : (string * string, string) result =
  match String.split_on_char ':' s with
  | [] -> Error "missing tag (expected name:tag)"
  | [ _ ] -> Error "missing tag (expected name:tag)"
  | name :: tag_parts ->
      let tag = String.concat ":" tag_parts in
      if tag = "" then Error "missing tag (expected name:tag)"
      else Ok (name, tag)

let cron_job_to_deploy (j : Config_file.cron_job) ~image : deploy_cron_job =
  {
    name = j.name;
    image;
    schedule = j.schedule;
    network = j.network;
    env_vars = j.env_vars;
    secret_env_vars = j.secret_env_vars;
    registry_user = j.registry_user;
    registry_pass = j.registry_pass;
    alert_sinks = j.alert_sinks;
    exit_code_severities = j.exit_code_severities;
  }

let cron_jobs_for_server ip_address
    (cron_jobs : Config_file.cron_job list option)
    (deployments : (string * string) list) : deploy_cron_job list option =
  let tag_of_name name = List.assoc_opt name deployments in
  match cron_jobs with
  | None -> None
  | Some jobs ->
      let filtered =
        List.filter
          (fun (j : Config_file.cron_job) -> j.server.ip_address = ip_address)
          jobs
      in
      let with_tags =
        List.filter_map
          (fun (j : Config_file.cron_job) ->
            match tag_of_name j.name with
            | Some tag ->
                Some (cron_job_to_deploy j ~image:(j.image ^ ":" ^ tag))
            | None -> None)
          filtered
      in
      if with_tags = [] then None else Some with_tags

(* The two reads this command makes of its own are both of something already on
   the box -- the crontab and the payload directory -- and a box that is
   answering answers both at once. A minute is generous for either and short
   enough that a box which has stopped answering is not waited on for the
   deploy's own budget. The third read a deploy makes, of the orchestrator's
   image tag, is [Orchestrator_version]'s and is held to that module's bound for
   the reason given there. *)
let read_seconds = 60

(* How long a box may take to answer the deploy itself, which is the one thing
   this command asks for that is not a read. It has to cover what the box does
   with the payload: pulling an image that may not be there yet, over whatever
   link that box has to the registry, and then the wait the strategy makes on
   the new container's health check -- a wait an operator sets in bondi.yaml and
   may set high. Half an hour covers both, where the minute above would expire
   on the pull alone.

   Giving up is not calling it off. The box goes on deploying, because what this
   bound governs is how long this machine watches; the outcome is recoverable
   from the box afterwards. So a bound that is too short costs a report and a
   bound that is too long costs a terminal that sits there, and that asymmetry
   is why this one is the generous of the two. *)
let deploy_seconds = 1800

(* What the gate decides from, as an operator reads a refusal to read it. The
   reading itself is [Orchestrator_version]'s, shared with [Cmd.Status] so that
   the two commands hold their boxes to the same floor from the same answer;
   what is here is the wording, which is a deploy's and would be wrong in a
   status report. *)
let reported_orchestrator_version ?session (server : Config_file.server) =
  match Orchestrator_version.read ?session server with
  (* A server with no [ssh] block is answered from the configuration, before
     anything is spawned, so nothing about it failed to be read. Rendering it
     with the other six sends an operator whose bondi.yaml is missing a block
     looking at the network instead. The kind is a value precisely so this
     caller can separate the two. *)
  | Error (Remote_exec.Not_configured { server = ip_address }) ->
      Error
        (Printf.sprintf
           "a deploy reaches a server by running a command inside its \
            orchestrator over SSH, and server %s has no ssh: block in \
            bondi.yaml to reach it over. Add one, then deploy again."
           ip_address)
  | Error
      (( Remote_exec.Ssh_not_found _ | Remote_exec.Local_failure _
       | Remote_exec.Ssh_failed _ | Remote_exec.Command_failed _
       | Remote_exec.Signalled _ | Remote_exec.Stopped _
       | Remote_exec.Timed_out _ ) as failure) ->
      Error
        (Printf.sprintf
           "the orchestrator's version could not be read, and a deploy is not \
            sent to a server whose image it has not seen: %s"
           (Remote_exec.explain ~subject:"the orchestrator listing" failure))
  | Ok version -> Ok version

(* Which floor a server is held to is decided by the work it is about to be
   given, and every server is held to one: a deploy reaches the box by running a
   subcommand inside the orchestrator's container, and a binary from before
   there were subcommands answers that by ignoring the arguments and starting a
   second server against a port already bound. So there is no deploy that can
   skip the question, and a box is read once whatever the answer is used for.

   A server that is also having cron jobs written to it is held to the higher
   floor alone. Writing the exec-shaped crontab line is the later and stronger
   capability and the release that carries it carries the subcommands by
   construction, so asking the lower question of that server as well would only
   be able to refuse it a second time -- and refusing it against the lower
   number would send an operator to an image that is still going to be refused
   here. One floor per server, and it is the one its work requires.

   The reader is a parameter rather than something called ahead of the decision
   so that this stays a decision made from a value, testable against a box that
   does not exist. It is called once, so a server is read once. *)
let version_gate ~read_version cron_jobs =
  let* version = read_version () in
  match cron_jobs with
  | None
  | Some [] ->
      Server_version.answers_command_surface version
  | Some (_ :: _) -> Server_version.writes_exec_lines version

(* What the box's two cron sources say about each other, as the lines to print,
   for the servers this invocation is about to write cron jobs to.

   The comparison is asked only when this server has cron jobs to write, so a
   service-only deploy neither consults the box nor pays for the round trips --
   which is why the readers are parameters rather than something called ahead of
   the decision. The gate above takes its reader for the other reason a reader
   is a parameter: it asks its question of every server, and what the parameter
   buys there is a decision made from a value rather than from a host.

   That scope is a stated limit, not an oversight. Withdraw a job from
   bondi.yaml and its files stay behind on the box; if it was the last cron job
   for that server, or the operator deploys the service alone, [cron_jobs] is
   [None] here and neither source is read, so no deploy can see the orphan it
   left. Seeing it would mean reading both sources on every deploy, charging two
   round trips per server to runs that have no cron jobs at all. [bondi status]
   reads both unconditionally and is where the withdrawn job is caught; what
   deploy owes is the state of the servers it is about to write to.

   It answers lines and never a verdict. A divergence does not change the exit
   code and does not stop the deploy: refusing would block the very command that
   repairs it, and would refuse on the strength of a remote read that can itself
   fail. What an operator is owed here is the state of the box in the output
   they are already watching, and an exit code is not what makes that visible.

   Each read is handed over as its own outcome and each goes to the module that
   owns it, so a spool the host refused stays distinguishable from a host that
   answered "no section", and a directory that could not be listed stays
   distinguishable from one that is empty. Neither reader is told what the other
   answered; that they are two reads of two artifacts is the whole of what makes
   this a comparison rather than a restatement. The section is read first so a
   run's two commands leave in the order the report names them. *)
let cron_divergence_report ~server ~read_crontab ~read_payloads cron_jobs =
  match cron_jobs with
  | None
  | Some [] ->
      []
  | Some (_ :: _) ->
      let crontab = Crontab_listing.of_read_output (read_crontab ()) in
      let listing = Cron_payload.of_listing_output (read_payloads ()) in
      Cron_payload.report ~server ~crontab listing

(* The readers the report is handed in production. Both run over the connection
   the caller opened for this server, which is the same one the deploy itself
   goes over, so what the comparison costs on a path that was already connecting
   is the two commands and no second handshake.

   The session is the caller's rather than this function's because it is not
   this function's decision: it is one connection per server, taken by whatever
   walks the server list, and a session opened here would be a second one for
   the same box in the same breath. A server with no cron jobs reads nothing --
   the guard is still the one in the comparison above -- and pays neither
   command. *)
let reported_cron_divergence ?session (server : Config_file.server) cron_jobs =
  cron_divergence_report ~server:server.ip_address
    ~read_crontab:(fun () ->
      Remote_exec.command_output ?session ~timeout_seconds:read_seconds
        ~command:Crontab_listing.read_command server)
    ~read_payloads:(fun () ->
      Remote_exec.command_output ?session ~timeout_seconds:read_seconds
        ~command:Cron_payload.listing_command server)
    cron_jobs

(* The command the box runs for a deploy: the orchestrator's own binary, as a
   subcommand, inside the container it runs in. [-i] is what keeps this
   machine's standard input open through to it, which is how the payload gets
   there -- the payload is never an argument, because it carries registry
   credentials and environment values and a command line is readable by every
   process on the box.

   The [docker] is not spelled here. The runner supplies it, so that no call
   site can spell it differently. *)
let deploy_exec_command =
  Printf.sprintf "exec -i %s bondi-server deploy"
    Bondi_common.Builtin_container.orchestrator

(* What the box answered, as an operator reads it.

   Its own words are carried rather than replaced. An orchestrator that refused
   says why on its error stream and the runner brings that back; a container
   that is not there, a daemon that refused, an image whose binary knows no such
   subcommand each answer in words no orchestrator would have written, and those
   are exactly the words that name the problem. A client that put its own
   account of not having understood them in their place would drop the only
   evidence there was and point the operator at their own machine.

   What the box wrote is not otherwise read. The exit code is the verdict -- the
   box writes its report and exits zero, or writes why it refused and exits
   non-zero -- and a client that parsed the report would begin refusing deploys
   that had succeeded the first time that report gained a field. *)
let deploy_outcome ~ip_address = function
  | Ok (_ : string) -> Ok ()
  | Error failure ->
      Error
        (Printf.sprintf "Error on server %s: %s" ip_address
           (Remote_exec.explain ~subject:"the deploy" failure))

let post_deploy ?session (server : Config_file.server) payload =
  deploy_outcome ~ip_address:server.ip_address
    (Remote_exec.docker_command_output ?session ~timeout_seconds:deploy_seconds
       ~input:(payload |> deploy_payload_to_yojson |> Yojson.Safe.to_string)
       ~command:deploy_exec_command server)

(* Everything this command does to one server once that server has been let
   through the gate, over one connection: the two reads the cron comparison
   makes and the deploy itself. One session, because it is one server's worth of
   work and the key is on disk for as long as the work lasts rather than for
   each call within it.

   The comparison is read before this server is deployed to, so what it reports
   is the state the deploy found rather than the state it just made. It is not
   read before every *other* server is deployed to, which it was when the reads
   had a loop of their own -- but a deploy to another box writes neither this
   box's crontab nor its payload directory, so the property that was worth
   having is per server and it is the one held here.

   A session that could not be staged is not a deploy that half happened: the
   body never ran, so the work is re-derived without one and every call in it
   answers with the failure the staging returned.

   The number it is opened at bounds nothing here either, for the same reason:
   the two reads ask for a minute and the deploy asks for half an hour, and
   [Remote_exec] gives each of them what it asked for. The deploy's bound is
   what is stated because a call over this session that named none of its own
   would be the deploy. *)
let deploy_to_server (server : Config_file.server) cron_jobs payload =
  let work ?session () =
    List.iter print_endline (reported_cron_divergence ?session server cron_jobs);
    print_endline (Printf.sprintf "Deploying to server: %s" server.ip_address);
    post_deploy ?session server payload
  in
  match
    Remote_exec.with_session ~timeout_seconds:deploy_seconds server
      (fun session -> work ~session ())
  with
  | Ok outcome -> outcome
  | Error _ -> work ()

(* The whole of what this command does to the servers it was given: every one of
   them is gated, and only then is any one of them deployed to. A refusal that
   arrived after the first box had been written to would not be a refusal, and
   the order of these two loops is the only thing that makes it one -- so the
   reader and the deployer are parameters and the order is observable without a
   box to run against.

   Every refusal is reported rather than only the first, and so is every failed
   deploy: an operator who has two boxes to upgrade, or two boxes that refused
   the payload, should learn that from one run. Every server is still attempted,
   because a box that has already been deployed to is not made better by
   abandoning the next -- so the run already holds every outcome by the time it
   reports, and the terminal these lines are printed to shows all of them. *)
let deploy_servers ~read_version ~deploy servers_with_jobs =
  let refusals =
    List.filter_map
      (fun ((server : Config_file.server), cron_jobs) ->
        match
          version_gate ~read_version:(fun () -> read_version server) cron_jobs
        with
        | Ok () -> None
        | Error message ->
            Some
              (Printf.sprintf "Error on server %s: %s" server.ip_address message))
      servers_with_jobs
  in
  match refusals with
  | _ :: _ -> Error refusals
  | [] -> (
      (* Folded left rather than mapped: each of these prints as it goes, and
         the order they print in is the order the operator's servers are named
         in, which a map is not obliged to preserve. *)
      let outcomes =
        List.rev
          (List.fold_left
             (fun taken (server, cron_jobs) -> deploy server cron_jobs :: taken)
             [] servers_with_jobs)
      in
      match
        List.filter_map
          (function
            | Error message -> Some message
            | Ok () -> None)
          outcomes
      with
      | _ :: _ as failures -> Error failures
      | [] -> Ok ())

let validate_deployments (config : Config_file.t) deployments :
    ((string * string) list, string) result =
  let service_names =
    match config.user_service with
    | Some s -> [ s.name ]
    | None -> []
  in
  let cron_names =
    match config.cron_jobs with
    | Some jobs -> List.map (fun (j : Config_file.cron_job) -> j.name) jobs
    | None -> []
  in
  let valid_names = service_names @ cron_names in
  let check (name, _tag) =
    if List.mem name valid_names then None
    else Some (Printf.sprintf "Unknown deployment target: %s" name)
  in
  match List.find_map check deployments with
  | Some msg -> Error msg
  | None -> Ok deployments

let run force_traefik_redeploy deployments =
  print_endline "Deployment process initiated...";
  let deployments =
    match deployments with
    | [] ->
        prerr_endline
          "Error: no deployments specified. Use name:tag (e.g. \
           my-service:v1.2.3)";
        exit 1
    | _ :: _ -> (
        match
          List.fold_left
            (fun acc s ->
              match acc with
              | Error _ -> acc
              | Ok acc -> (
                  match parse_name_tag s with
                  | Error msg ->
                      prerr_endline ("Error: " ^ msg);
                      exit 1
                  | Ok pair -> Ok (pair :: acc)))
            (Ok []) deployments
        with
        | Error _ -> exit 1
        | Ok parsed -> List.rev parsed)
  in
  match Config_file.read () with
  | Error message ->
      prerr_endline ("Error reading configuration: " ^ message);
      exit 1
  | Ok config -> (
      (match validate_deployments config deployments with
      | Error msg ->
          prerr_endline msg;
          exit 1
      | Ok _ -> ());
      let servers = Config_file.servers config in
      if servers = [] then (
        prerr_endline
          "Error: no servers configured. Add servers to bondi.yaml under \
           service or each cron job.";
        exit 1);
      (* What this invocation has for a server is fixed for the whole run, and
         three phases below ask for it: the version gate, the divergence report
         and the payload. Derived once and carried beside its server, so the
         three cannot drift into reading different answers. *)
      let cron_jobs_per_server =
        List.map
          (fun (server : Config_file.server) ->
            ( server,
              cron_jobs_for_server server.ip_address config.cron_jobs
                deployments ))
          servers
      in
      let tag_of_name name = List.assoc_opt name deployments in
      let is_service_server ip =
        match config.user_service with
        | Some s ->
            List.exists
              (fun (x : Config_file.server) -> x.ip_address = ip)
              s.servers
        | None -> false
      in
      let payload_for (server : Config_file.server) cron_jobs =
        let ip_address = server.ip_address in
        (* The decision carries the service and its tag rather than a bool:
           the payload needs both, and a bool would leave the builder
           re-deriving them from options the decision has already
           inspected. *)
        let service_and_tag =
          match config.user_service with
          | None -> None
          | Some service -> (
              match tag_of_name service.name with
              | None -> None
              | Some tag ->
                  if is_service_server ip_address then Some (service, tag)
                  else None)
        in
        match service_and_tag with
        | Some ((service : Config_file.user_service), tag) ->
            {
              service_name = Some service.name;
              image = Some (service.image ^ ":" ^ tag);
              port = Some service.port;
              env_vars = service.env_vars;
              traefik_domain_name =
                Option.map
                  (fun (tr : Config_file.traefik) -> tr.domain_name)
                  config.traefik;
              traefik_image =
                Option.map
                  (fun (tr : Config_file.traefik) -> tr.image)
                  config.traefik;
              traefik_acme_email =
                Option.map
                  (fun (tr : Config_file.traefik) -> tr.acme_email)
                  config.traefik;
              registry_user = service.registry_user;
              registry_pass = service.registry_pass;
              force_traefik_redeploy = Some force_traefik_redeploy;
              cron_jobs;
              drain_grace_period =
                Option.map float_of_int service.drain_grace_period;
              deployment_strategy = service.deployment_strategy;
              health_timeout = Option.map float_of_int service.health_timeout;
              poll_interval = Option.map float_of_int service.poll_interval;
              logs = service.logs;
            }
        | None ->
            {
              service_name = None;
              image = None;
              port = None;
              env_vars = [];
              traefik_domain_name = None;
              traefik_image = None;
              traefik_acme_email = None;
              registry_user = None;
              registry_pass = None;
              force_traefik_redeploy = Some force_traefik_redeploy;
              cron_jobs;
              drain_grace_period = None;
              deployment_strategy = None;
              health_timeout = None;
              poll_interval = None;
              logs = None;
            }
      in
      (* The gate's read is the only thing this server has been asked for when
         it is made, so a session that could not be staged is the same failure
         the read itself would have reported, worded by the reader rather than
         a second time here. The body never ran.

         It is a session of its own and not the one the deploy runs over
         because every server is gated before any server is deployed to:
         holding one connection open across both would mean holding every
         server's key on disk for the length of the run.

         The number it is opened at bounds nothing. [Remote_exec] holds a call
         to the bound the call names rather than to its session's, and the one
         call made over this session names [Orchestrator_version]'s. The
         argument is required so that a session cannot be opened without saying
         what a call over it that named no bound would wait for, and what such a
         call would be waiting on here is a read, so the read bound is what is
         stated. *)
      let read_version (server : Config_file.server) =
        match
          Remote_exec.with_session ~timeout_seconds:read_seconds server
            (fun session -> reported_orchestrator_version ~session server)
        with
        | Ok answer -> answer
        | Error _ -> reported_orchestrator_version server
      in
      let deploy (server : Config_file.server) cron_jobs =
        deploy_to_server server cron_jobs (payload_for server cron_jobs)
      in
      match deploy_servers ~read_version ~deploy cron_jobs_per_server with
      | Error messages ->
          List.iter prerr_endline messages;
          exit 1
      | Ok () ->
          List.iter
            (fun (server : Config_file.server) ->
              print_endline
                (Printf.sprintf "Deployment initiated on server %s"
                   server.ip_address))
            servers)

let force_traefik_redeploy_arg =
  let doc = "Force Traefik to be redeployed to pick up config changes." in
  Cmdliner.Arg.(value & flag & info [ "redeploy-traefik" ] ~doc)

let deployments_arg =
  let doc = "Deployments as name:tag (e.g. my-service:v1.2.3 backup:v2)." in
  Cmdliner.Arg.(value & pos_all string [] & info [] ~docv:"NAME:TAG" ~doc)

let cmd =
  let term =
    Cmdliner.Term.(const run $ force_traefik_redeploy_arg $ deployments_arg)
  in
  let info =
    Cmdliner.Cmd.info "deploy"
      ~doc:"Deploy services and cron jobs. Specify name:tag for each target."
  in
  Cmdliner.Cmd.v info term
