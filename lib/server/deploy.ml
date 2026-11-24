module Simple = Strategy.Simple
module Image_reference = Bondi_common.Image_reference

let ( let* ) = Result.bind

type deploy_response = {
  status : string;
  tag : string;
  strategy : string;
  strategy_reason : string;
}
[@@deriving yojson]

type deployment_strategy = Simple | Blue_green

let string_of_deployment_strategy = function
  | Simple -> "simple"
  | Blue_green -> "blue-green"

let deployment_strategy_of_string = function
  | "blue-green" -> Some Blue_green
  | "simple" -> Some Simple
  | _ -> None

(* ------------------------------------------------------------------------- *)
(* Pure helpers (testable)                                                   *)
(* ------------------------------------------------------------------------- *)

let auth_config_json ~user ~pass ~serveraddress =
  `Assoc
    [
      ("serveraddress", `String serveraddress);
      ("username", `String user);
      ("password", `String pass);
    ]

(* The registry is the reference's own, as the one parser both ends share reads
   it, so the credentials go to the registry the pull goes to, a port included.

   A reference that names no registry but has a namespace, as a private Docker
   Hub repository's [myorg/app] does, keeps what earlier releases sent: the
   credentials, with the first path component ([myorg]) as serveraddress, so the
   Engine is handed them for the Docker Hub pull exactly as before. A
   single-component name ([nginx]) never sent credentials and sends none.

   The Engine reads the header as base64url, so a credential whose standard
   encoding carries '+' or '/' would reach it as something else. Padding is
   kept, as Python's urlsafe_b64encode keeps it. *)
let registry_auth reference ~user ~pass =
  let serveraddress =
    match Image_reference.registry reference with
    | Some registry -> Some registry
    | None -> (
        let name = Image_reference.name reference in
        match String.index_opt name '/' with
        | Some slash -> Some (String.sub name 0 slash)
        | None -> None)
  in
  match (serveraddress, user, pass) with
  | Some serveraddress, Some user, Some pass ->
      let json = auth_config_json ~user ~pass ~serveraddress in
      Some
        (Base64.encode_string ~pad:true ~alphabet:Base64.uri_safe_alphabet
           (Yojson.Safe.to_string json))
  | None, _, _
  | _, None, _
  | _, _, None ->
      None

let registry_auth_for_service (input : Simple.deploy_input) =
  match input.image with
  | Some image ->
      registry_auth image ~user:input.registry_user ~pass:input.registry_pass
  | None -> None

(* Both of the job's files are placed on the box here, at deploy time, and read
   back when the job fires: the run payload the crontab line points at, and the
   secrets that payload deliberately does not carry --
   Crontab.run_payload_of_cron_job omits secret_env_vars so that no credential
   travels with the definition, and Run reads them from the env file instead.

   Every declared job is written even when it declares no secrets, so that
   withdrawing a credential truncates the file rather than leaving the last one
   behind for the next run to pick up.

   Neither write is guarded here. The name that makes both paths safe is checked
   in cron_plan, before anything on the box has moved; a check repeated here
   would be a second answer to the same question, given after the deploy. *)
let write_cron_files (cron_jobs : Simple.cron_job list option) :
    (unit, string) result =
  let write (c : Simple.cron_job) =
    let* () =
      Cron_secrets.write_env_file ~name:c.name
        (Option.value c.secret_env_vars ~default:[])
    in
    Cron_secrets.write_run_file ~name:c.name (Crontab.run_payload_of_cron_job c)
  in
  List.fold_left
    (fun acc job ->
      match acc with
      | Error _ -> acc
      | Ok () -> write job)
    (Ok ())
    (Option.value cron_jobs ~default:[])

let registry_auth_for_cron (c : Simple.cron_job) =
  registry_auth c.image ~user:c.registry_user ~pass:c.registry_pass

let tag_from_image reference =
  match Image_reference.tag reference with
  | Some tag -> tag
  | None -> "unknown"

(* ------------------------------------------------------------------------- *)
(* Types                                                                     *)
(* ------------------------------------------------------------------------- *)

type deploy_action =
  | EnsureCronNetwork
  | UpsertCrontab of Simple.cron_job list option
  | UpdateRestartPolicy of {
      container_id : string;
      restart_policy : Docker.Client.restart_policy;
    }

(* ------------------------------------------------------------------------- *)
(* Phase 1: Plan (pure)                                                      *)
(* ------------------------------------------------------------------------- *)

(* Bondi ensures only the network it owns. Creating a network under any other
   declared name would succeed and hand the job an empty network it can reach
   nothing through — a failure discovered only at run time — so an unmanaged
   name is rejected here, in the plan, naming what was declared. Measured: a
   container on a separately created bridge network cannot resolve a peer on
   another one (getent exits 2, no address) while the same lookup from within
   the peer's network resolves. The ensure is idempotent and carries the one
   name it can carry, so any number of jobs declaring it plan a single action.

   The check is config-based, not Docker-based: this function receives the
   declared cron jobs and nothing else, and compares against a single accepted
   constant. It cannot observe which networks exist on the server, so a network
   the operator creates by hand stays invisible to it and the next deploy fails
   identically. Every remedy the message offers must therefore be one the
   operator can apply in bondi.yaml — a "docker network create" suggestion here
   reads as actionable and is a dead end.

   Every offending job is named in one message. The whole declared set is in
   hand and the check is pure, so stopping at the first would make the operator
   rediscover the next bad name on a later deploy. *)
let cron_network_action (jobs : Simple.cron_job list) :
    (deploy_action list, Handler_error.t) result =
  let shared = Bondi_common.Defaults.network_name in
  let declares_shared (job : Simple.cron_job) =
    match job.network with
    | None -> false
    | Some network -> String.equal network shared
  in
  let unmanaged =
    List.filter_map
      (fun (job : Simple.cron_job) ->
        match job.network with
        | None -> None
        | Some network ->
            if String.equal network shared then None
            else Some (Printf.sprintf "%s declares %s" job.name network))
      jobs
  in
  match unmanaged with
  | [] ->
      Ok
        (if List.exists declares_shared jobs then [ EnsureCronNetwork ] else [])
  | offenders ->
      Error
        (Handler_error.Invalid_request
           (Printf.sprintf
              "cron jobs declare networks bondi does not manage (%s). bondi \
               manages only %s: declare that instead, and attach the \
               containers these jobs must reach to %s too"
              (String.concat ", " offenders)
              shared shared))

(* A job's name is interpolated into the path of its run file and its env file,
   and into the crontab line that reads the first of them, so a name carrying a
   separator or a leading dot could name its way out of the job's own directory.
   Cron_secrets.write_run_file refuses such a name, but it refuses it while the
   deploy is already running; the refusal belongs here, where nothing on the box
   has moved yet and the caller can still be told the request was wrong.

   Cron_secrets.is_valid_name is the check itself rather than a second copy of
   its rule, so this cannot drift from the guard that actually protects the
   path. Every offending job is named in one message, for the reason
   cron_network_action gives.

   Jobs are refused, never filtered: a plan that dropped the names it did not
   like would write a section that does not match what was deployed, and say
   nothing. *)
let cron_name_check (jobs : Simple.cron_job list) :
    (unit, Handler_error.t) result =
  match
    List.filter
      (fun (job : Simple.cron_job) -> not (Cron_secrets.is_valid_name job.name))
      jobs
  with
  | [] -> Ok ()
  | offenders ->
      Error
        (Handler_error.Invalid_request
           (Printf.sprintf
              "cron job names must be safe to place in a file path (%s). A \
               name must begin with a letter or a digit and may hold only \
               letters, digits, '.', '_' and '-': rename these jobs in \
               bondi.yaml"
              (String.concat ", "
                 (List.map (fun (job : Simple.cron_job) -> job.name) offenders))))

let cron_plan (input : Simple.deploy_input) :
    (deploy_action list, Handler_error.t) result =
  match input.cron_jobs with
  | None
  | Some [] ->
      Ok []
  | Some jobs ->
      let* () = cron_name_check jobs in
      let* network_actions = cron_network_action jobs in
      Ok (network_actions @ [ UpsertCrontab (Some jobs) ])

(* The proxy's input, when the request declares a proxy: a domain, a Traefik
   image and an ACME email, which the client sends together or not at all. A
   request without them converges no proxy, so there is nothing here that can
   be missing and no proxy plan that can fail. *)
let proxy_input (input : Simple.deploy_input) : Proxy.input option =
  match
    (input.traefik_image, input.traefik_domain_name, input.traefik_acme_email)
  with
  | Some image, Some domain_name, Some acme_email ->
      Some
        {
          Proxy.image;
          domain_name;
          acme_email;
          acme_ca_server = input.traefik_acme_ca_server;
          force_redeploy =
            Option.value ~default:false input.force_traefik_redeploy;
        }
  | None, _, _
  | _, None, _
  | _, _, None ->
      None

(* The proxy is a property of the box, not of how the service is rolled
   forward, so it is converged here, from the request, under every strategy. *)
let proxy_plan (input : Simple.deploy_input)
    ~(current_traefik : Docker.Client.container option) : Proxy.action list =
  match proxy_input input with
  | None -> []
  | Some proxy -> Proxy.plan proxy (Proxy.decide proxy ~current:current_traefik)

(* The reverse proxy's restart policy is decided here rather than inside a
   strategy, for the reason the proxy itself is: it is a property of the box.

   Converged in place, never by recreating: rebuilding the proxy to change one
   mutable field would drop TLS for every site on the box. *)
type traefik_policy_context = {
  traefik : Docker.Client.container option;
  applied_policy : Docker.Client.restart_policy option;
      (* The policy the daemon reports on the running proxy, not the one it was
         asked for. [None] when there is no proxy, when the daemon reports no
         policy, and when the read failed. *)
}

(* A proxy that is about to be replaced is left alone: the proxy step creates
   its successor with the policy already on it, and it does so under every
   strategy. *)
let traefik_will_be_replaced (proxy : Proxy.input)
    (traefik : Docker.Client.container) =
  match Proxy.decide proxy ~current:(Some traefik) with
  | Proxy.Keep -> false
  | Proxy.Create
  | Proxy.Replace _ ->
      true

(* The gate is the one the deploy path already applied: a bondi.yaml that
   declares no reverse proxy converges none, even on a box that is running one.
   That box is corrected by declaring the proxy again, and widening the gate
   would have Bondi write to a container the configuration in hand does not
   claim. *)
let traefik_policy_plan (input : Simple.deploy_input)
    (context : traefik_policy_context) : deploy_action list =
  match context.traefik with
  | None -> []
  | Some traefik -> (
      match proxy_input input with
      | None -> []
      | Some proxy ->
          if traefik_will_be_replaced proxy traefik then []
          else if Docker.Restart_policy.applied_matches context.applied_policy
          then []
          else
            [
              UpdateRestartPolicy
                {
                  container_id = traefik.id;
                  restart_policy = Docker.Restart_policy.bondi_managed;
                };
            ])

type pull =
  | PullWorkload of Image_reference.t
  | PullTraefik of Image_reference.t
  | PullCronImage of Simple.cron_job

(* Every image the deploy will run, named before anything on the box moves.
   Ordering is a decision made here, not by the interpreters: [deploy] runs this
   list to its end ahead of the restart-policy write, the snapshot, the
   workload's stop and create, and the crontab write, so a pull that fails
   leaves the box exactly as it was.

   The proxy is pulled whenever the proxy step will create or replace it,
   whatever the strategy, and a proxy that is kept is not recreated. A cron-only
   deploy has no service, so it has no workload and no proxy. [workload_pulled]
   is true when selecting the strategy already pulled the workload, which it
   must do to read the image's healthcheck. *)
let pull_plan ~workload_pulled (input : Simple.deploy_input)
    ~(current_traefik : Docker.Client.container option) : pull list =
  let has_service = Option.is_some input.service_name in
  let traefik =
    match proxy_input input with
    | Some proxy when has_service -> (
        match Proxy.decide proxy ~current:current_traefik with
        | Proxy.Keep -> []
        | Proxy.Create
        | Proxy.Replace _ ->
            [ PullTraefik proxy.image ])
    | Some _
    | None ->
        []
  in
  let workload =
    match input.image with
    | Some image when has_service && not workload_pulled ->
        [ PullWorkload image ]
    | Some _
    | None ->
        []
  in
  let cron =
    List.map
      (fun job -> PullCronImage job)
      (Option.value ~default:[] input.cron_jobs)
  in
  traefik @ workload @ cron

(* ------------------------------------------------------------------------- *)
(* Phase 2: Interpreter                                                      *)
(* ------------------------------------------------------------------------- *)

let interpret_pulls ~client ~net (input : Simple.deploy_input)
    (pulls : pull list) : (unit, string) result =
  let pull_one = function
    | PullWorkload reference ->
        Docker.Client.pull_image client ~net ~reference
          ~registry_auth:(registry_auth_for_service input)
    | PullTraefik reference ->
        Docker.Client.pull_image_no_auth client ~net ~reference
    | PullCronImage c ->
        let* reference = Payload_codec.require_tag_or_digest c.image in
        Docker.Client.pull_image client ~net ~reference
          ~registry_auth:(registry_auth_for_cron c)
  in
  List.fold_left
    (fun acc pull ->
      let* () = acc in
      pull_one pull)
    (Ok ()) pulls

let interpret ~clock ~client ~net (actions : deploy_action list) :
    (unit, string) result =
  let rec run = function
    | [] -> Ok ()
    | EnsureCronNetwork :: rest ->
        let* () =
          Docker.Client.create_network_if_not_exists client ~net
            ~network_name:Bondi_common.Defaults.network_name
        in
        run rest
    | UpsertCrontab cron_jobs :: rest -> (
        (* The job's files are written before the crontab, not after: a line
           that fires against a missing run file does not run the job at all,
           and one that fires against a missing env file runs it without its
           credentials, which fails somewhere inside the container and reports
           as the job being broken. Writing first means the only ordering
           failure is a crontab that was not updated, which reports as itself. *)
        match write_cron_files cron_jobs with
        | Error msg ->
            Error ("Deploy succeeded but writing cron job files failed: " ^ msg)
        | Ok () -> (
            match Crontab.upsert cron_jobs with
            | Ok () -> run rest
            | Error msg ->
                Error ("Deploy succeeded but crontab update failed: " ^ msg)))
    | UpdateRestartPolicy { container_id; restart_policy } :: rest ->
        let* () =
          Docker.Client.update_container client ~net ~clock ~container_id
            ~restart_policy
        in
        run rest
  in
  run actions

(* ------------------------------------------------------------------------- *)
(* JSON                                                                      *)
(* ------------------------------------------------------------------------- *)

(* The decode is a decision this module makes, so it answers in the same
   vocabulary as the rest of it: a body that did not decode is a value the
   caller wrote that failed a precondition, which is [Invalid_request] and
   carries that class's exit code. The two messages are unchanged: they were
   written to be read after a caller-supplied prefix and are still worded that
   way. An image reference that does not parse is refused by the deploy input's
   own codec, so it arrives here as a payload that did not decode. *)
let decode_input body : (Simple.deploy_input, Handler_error.t) result =
  match Yojson.Safe.from_string body with
  | exception Yojson.Json_error msg ->
      Error (Handler_error.Invalid_request ("invalid JSON: " ^ msg))
  | json ->
      Simple.deploy_input_of_yojson json
      |> Result.map_error (fun msg ->
          Handler_error.Invalid_request ("invalid deploy payload: " ^ msg))

let build_response ~strategy ~strategy_reason (input : Simple.deploy_input) =
  {
    status = "Deploy initiated";
    tag =
      (match input.image with
      | Some image -> tag_from_image image
      | None -> "n/a");
    strategy = string_of_deployment_strategy strategy;
    strategy_reason;
  }

(* The Engine runs a probe only for a [Test] whose first word is [CMD] or
   [CMD-SHELL]. [NONE] (written by [HEALTHCHECK NONE]) and an empty [Test] run
   none, and blue-green would wait for a health that never comes. Any other
   first word is not one this decode knows, so it selects simple under a reason
   of its own that names the word, and is not folded into "no HEALTHCHECK".
   [inferred from the Engine's probe selection, not observed] *)
let auto_selection (inspect : Docker.Client.image_inspect_response) =
  match inspect.config.healthcheck with
  | Some { test = ("CMD" | "CMD-SHELL") :: _ } ->
      (Blue_green, "image has HEALTHCHECK")
  | Some { test = [] | "NONE" :: _ }
  | None ->
      (Simple, "image has no HEALTHCHECK")
  | Some { test = word :: _ } ->
      ( Simple,
        Printf.sprintf "unrecognised health check `%s`, selected simple" word )

let auto_strategy inspect = fst (auto_selection inspect)

let try_pull_main_image ~client ~net input =
  match input.Simple.image with
  | None -> Error "image is required for service deployment"
  | Some reference ->
      let auth = registry_auth_for_service input in
      (* [pull_image] names the reference in its failure itself. The reference
         has a tag or a digest: decode refused one that has neither. *)
      Docker.Client.pull_image client ~net ~reference ~registry_auth:auth

(* What a service deploy reads of its image, once, after the pull that makes the
   read possible and before anything moves: the strategy it will run under, why,
   and the inspect that the label check reads too. The image is pulled here
   whether or not the request declares a strategy, because the label check needs
   it either way, so [pull_plan] is told the workload is already pulled. An
   inspect that fails is not folded into a strategy: it fails the deploy, as the
   label check would have on the same error. A declared strategy that is not one
   is refused before the pull, so nothing is fetched for a request that cannot
   run. *)
type image_gather = {
  selected : deployment_strategy;
  selection_reason : string;
  image_inspect : Docker.Client.image_inspect_response;
}

let gather_image ~clock ~client ~net input : (image_gather, string) result =
  let* declared =
    match input.Simple.deployment_strategy with
    | None -> Ok None
    | Some s -> (
        match deployment_strategy_of_string s with
        | None ->
            Error
              (Printf.sprintf
                 "unknown deployment_strategy: %s (valid values: blue-green, \
                  simple)"
                 s)
        | Some declared -> Ok (Some declared))
  in
  let* () = try_pull_main_image ~client ~net input in
  match input.image with
  | None -> Error "image is required for service deployment"
  | Some image ->
      let* inspect =
        Docker.Client.inspect_image client ~net ~clock
          ~image:(Image_reference.to_string image)
      in
      let strategy, strategy_reason =
        match declared with
        | Some declared -> (declared, "configured in bondi.yaml")
        | None -> auto_selection inspect
      in
      Ok
        {
          selected = strategy;
          selection_reason = strategy_reason;
          image_inspect = inspect;
        }

(* Every refusal the workload can meet, which is every one [Simple.service_config]
   makes and, under blue-green, [Blue_green.config_of_input]. The proxy is
   converged ahead of the workload, so these are run before it, not found by the
   workload's own step afterwards. *)
let workload_refusals ~strategy input : (unit, string) result =
  let* _ = Simple.service_config input in
  match strategy with
  | Simple -> Ok ()
  | Blue_green ->
      let* _ = Strategy.Blue_green.config_of_input input in
      Ok ()

(* What a blue-green deploy read, and the configuration it was built with,
   before the proxy moved. *)
type gathered_workload =
  | Nothing_gathered
  | Blue_green_gathered of
      Strategy.Blue_green.blue_green_config
      * Strategy.Blue_green.blue_green_context

let gather_workload ~clock ~client ~net ~strategy input :
    (gathered_workload, string) result =
  match strategy with
  | Simple -> Ok Nothing_gathered
  | Blue_green ->
      let* config, context =
        Strategy.Blue_green.gather ~clock ~client ~net ~input
      in
      Ok (Blue_green_gathered (config, context))

let deploy_workload ~clock ~client ~net ~strategy ~gathered input =
  match (strategy, gathered) with
  | Blue_green, Blue_green_gathered (config, context) ->
      Strategy.Blue_green.deploy ~clock ~client ~net config context
  | Blue_green, Nothing_gathered ->
      Error "the blue-green workload was deployed before it was gathered"
  | Simple, (Nothing_gathered | Blue_green_gathered _) ->
      Simple.deploy ~client ~net input

(* Phase 1 for the proxy: the container under its reserved name. One whose
   image merely mentions Traefik belongs to someone else and is never taken for
   it. *)
let find_proxy ~client ~net =
  Docker.Client.get_container_by_name client ~net
    ~container_name:Bondi_common.Builtin_container.traefik

(* The container listing carries no [HostConfig], so the applied policy comes
   from an inspect of the id the listing returned. An inspect Bondi could not
   make reports no policy rather than failing the run: the deploy must not be
   blocked by a read of a policy field, and reporting nothing already counts as
   non-compliant, so the proxy is converged instead. The failure is logged where
   it happens, so an inspect failing on every deploy is discoverable rather than
   invisible. *)
let gather_traefik_policy ~clock ~client ~net
    ~(traefik : Docker.Client.container option) :
    (traefik_policy_context, string) result =
  match traefik with
  | None -> Ok { traefik = None; applied_policy = None }
  | Some container ->
      let inspection =
        Docker.Client.inspect_container client ~net ~clock
          ~container_id:container.id
      in
      (match inspection with
      | Ok _ -> ()
      | Error msg ->
          Diagnostics.write
            (Printf.sprintf
               "could not read the restart policy of container %s: %s -- \
                treating it as non-compliant"
               container.id msg));
      Ok
        {
          traefik = Some container;
          applied_policy = Docker.Restart_policy.of_inspect inspection;
        }

let converge_traefik_restart_policy ~clock ~client ~net ~current_traefik input :
    (unit, string) result =
  let* context =
    gather_traefik_policy ~clock ~client ~net ~traefik:current_traefik
  in
  interpret ~clock ~client ~net (traefik_policy_plan input context)

let converge_proxy ~clock ~client ~net ~current_traefik input :
    (unit, string) result =
  Proxy.interpret ~clock ~client ~net (proxy_plan input ~current_traefik)

(* Everything below the plan is Bondi acting on the caller's behalf, so a
   failure there is Bondi's fault by construction. [cron_plan] and
   [image_label_check] are the steps in [deploy] that can fail on what the
   caller supplied, and each classifies its own error; [decode_input] refused
   the rest before [deploy] was called. *)
let orchestrator_step result =
  Result.map_error (fun m -> Handler_error.Orchestrator_failure m) result

(* Bondi writes the router's middlewares itself, to give it the retry
   middleware, and a label set at create replaces the image's [observed --
   2026-11-22, Docker Engine 29.10.0: created with Bondi's labels, the container
   carried Bondi's value; created with none, the image's]. An image declaring
   the key would lose its middlewares without a word, so the deploy is refused
   instead. The remedy is in the image the caller built, which makes it the
   caller's mistake and not Bondi's fault. *)
let image_label_check (input : Simple.deploy_input)
    (inspect : Docker.Client.image_inspect_response) :
    (unit, Handler_error.t) result =
  match (input.service_name, input.image) with
  | Some name, Some image -> (
      let label = Simple.router_middlewares_label name in
      match
        Option.bind inspect.config.labels (fun labels ->
            List.assoc_opt label labels)
      with
      | None -> Ok ()
      | Some _ ->
          Error
            (Handler_error.Invalid_request
               (Printf.sprintf
                  "the image %s declares the label %s. Bondi sets that label \
                   on the service's router itself, to retry requests the old \
                   container refuses while a deploy replaces it, and would \
                   drop the image's value: remove the label from the image and \
                   deploy again"
                  (Image_reference.to_string image)
                  label)))
  | None, _
  | _, None ->
      Ok ()

(* [None] is a deploy that gathered no image, which is a cron-only one: it has
   nothing for the check to read. *)
let check_gathered_image input inspect =
  match inspect with
  | None -> Ok ()
  | Some inspect -> image_label_check input inspect

(* The order of the whole deploy, as a value. [deploy] only interprets it, so
   where a pull sits relative to every change is decided here and can be read
   and tested without a daemon. Every image is pulled first, the workload image
   is inspected once and checked for labels it may not declare, and every
   refusal the workload can meet is made, and what the blue-green strategy plans
   from is read, before anything is changed. The restart-policy write, the
   snapshot, the proxy, the workload and the crontab follow; cleanup is last.
   The snapshot precedes the proxy step because it records the image the
   running proxy holds, which is gone once the proxy is replaced. *)
type deploy_step =
  | Pull_images
  | Check_image_labels
  | Validate_workload
  | Gather_workload
  | Converge_restart_policy
  | Snapshot_replaced
  | Converge_proxy
  | Deploy_workload
  | Apply_cron
  | Clean_up

let deploy_steps ~has_service =
  if has_service then
    [
      Pull_images;
      Check_image_labels;
      Validate_workload;
      Gather_workload;
      Converge_restart_policy;
      Snapshot_replaced;
      Converge_proxy;
      Deploy_workload;
      Apply_cron;
      Clean_up;
    ]
  else [ Pull_images; Apply_cron; Clean_up ]

(* The whole decision, naming no transport. [decode_input] runs above it and
   the response encoder below it, and neither is this function's business.

   The catch-all is deliberately not narrowed to exclude [Stdlib.Exit]: nothing
   on this path calls [exit], and answering a raised [Exit] differently than
   this function answers it today would change what the caller reads. The JSON
   encoding is outside it, on the caller's side of the seam; the encoder walks a
   record of four strings and has no input on which it can raise.

   [Eio.Cancel.Cancelled] is the one exception it is wrong to absorb, because
   this catch runs inside the fiber that would be cancelled: swallowing the
   cancellation would let a cancelled deploy return normally and break
   structured concurrency. It is re-raised rather than classified. *)
let deploy ~clock ~net input : (deploy_response, Handler_error.t) result =
  try
    let client =
      let unnegotiated =
        Docker.Client.create ?registry_auth:(registry_auth_for_service input) ()
      in
      match Docker.Client.negotiate unnegotiated ~net with
      | Ok client -> client
      | Error msg ->
          Eio.traceln
            "docker api version not negotiated, using the compiled default: %s"
            msg;
          unnegotiated
    in
    (* The cron plan is pure and depends only on [input], so it runs before any
       workload is touched: a rejected network declaration must not be discovered
       after the service has already moved to a new tag. *)
    let* actions = cron_plan input in
    (* Last, and only once every step before it has returned [Ok]: an image is
       removed only when the new service is running and the crontab names the
       new tags, so a failed deploy removes nothing. It returns unit, so nothing
       it meets can fail the deploy. *)
    let clean_up ~replaced =
      Image_cleanup.run ~client ~net ~clock ~replaced
        ~declared:(Image_cleanup.declared_of_input input)
    in
    let* strategy, strategy_reason, image_inspect =
      match input.Simple.service_name with
      | None -> Ok (Simple, "cron-only deploy", None)
      | Some _ ->
          let* gathered =
            orchestrator_step (gather_image ~clock ~client ~net input)
          in
          Ok
            ( gathered.selected,
              gathered.selection_reason,
              Some gathered.image_inspect )
    in
    let workload_pulled = Option.is_some image_inspect in
    (* The proxy as found once, read-only, before anything moves. The pull
       plan, the restart-policy plan and the proxy plan all decide from this
       one reading, so they cannot disagree about the box. *)
    let* current_traefik =
      match input.Simple.service_name with
      | None -> Ok None
      | Some _ -> orchestrator_step (find_proxy ~client ~net)
    in
    let gathered_workload = ref Nothing_gathered in
    let service_name = input.service_name in
    let replaced = ref [] in
    let run_step = function
      | Pull_images ->
          (* Every image the deploy needs, before the first thing changes. A
             pull that fails here has moved nothing. Reading the box to plan
             it is read-only. *)
          orchestrator_step
            (interpret_pulls ~client ~net input
               (pull_plan ~workload_pulled input ~current_traefik))
      | Check_image_labels ->
          (* The inspect gathered with the strategy, after every pull has
             succeeded and before the first change. *)
          check_gathered_image input image_inspect
      | Validate_workload ->
          (* Pure, and ahead of the proxy: [Converge_proxy] can remove the
             running one, which interrupts every site on the box. *)
          orchestrator_step (workload_refusals ~strategy input)
      | Gather_workload ->
          (* Read-only: what the strategy plans from, read before anything
             moves, so a read that fails stops the deploy with the box as it
             was. *)
          let* gathered =
            orchestrator_step
              (gather_workload ~clock ~client ~net ~strategy input)
          in
          gathered_workload := gathered;
          Ok ()
      | Converge_restart_policy ->
          orchestrator_step
            (converge_traefik_restart_policy ~clock ~client ~net
               ~current_traefik input)
      | Snapshot_replaced ->
          (* Immediately before the proxy and the workload move, because
             afterwards the replaced containers are gone and so is the record of
             what they ran. A snapshot that fails removes only the replaced
             images from cleanup and must not block the deploy. *)
          Option.iter
            (fun name ->
              replaced :=
                Image_cleanup.snapshot_replaced ~client ~net ~clock
                  ~service_name:(Bondi_common.Router_name.to_string name))
            service_name;
          Ok ()
      | Converge_proxy ->
          orchestrator_step
            (converge_proxy ~clock ~client ~net ~current_traefik input)
      | Deploy_workload ->
          orchestrator_step
            (deploy_workload ~clock ~client ~net ~strategy
               ~gathered:!gathered_workload input)
      | Apply_cron -> orchestrator_step (interpret ~clock ~client ~net actions)
      | Clean_up ->
          clean_up ~replaced:!replaced;
          Ok ()
    in
    let* () =
      List.fold_left
        (fun acc step ->
          let* () = acc in
          run_step step)
        (Ok ())
        (deploy_steps ~has_service:(Option.is_some service_name))
    in
    Ok (build_response ~strategy ~strategy_reason input)
  with
  | Eio.Cancel.Cancelled _ as cancelled -> raise cancelled
  | exn -> Error (Handler_error.Orchestrator_failure (Printexc.to_string exn))
