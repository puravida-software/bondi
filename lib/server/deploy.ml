module Simple = Strategy.Simple

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

(* Extract registry host from image name for AuthConfig.serveraddress.
   e.g. registry.gitlab.com/org/repo:tag -> registry.gitlab.com *)
let serveraddress_from_image image =
  let name =
    match String.split_on_char ':' image with
    | n :: _ -> n
    | [] -> image
  in
  match String.split_on_char '/' name with
  | registry :: _ :: _ -> Ok registry
  | _ ->
      Error
        (Printf.sprintf
           "cannot determine registry from image %s — use a fully qualified \
            image (e.g. registry.example.com/org/app)"
           image)

let auth_config_json ~user ~pass ?serveraddress () =
  let base = [ ("username", `String user); ("password", `String pass) ] in
  let entries =
    match serveraddress with
    | Some addr -> ("serveraddress", `String addr) :: base
    | None -> base
  in
  `Assoc entries

let registry_auth (input : Simple.deploy_input) =
  match (input.image, input.registry_user, input.registry_pass) with
  | Some image, Some user, Some pass -> (
      match serveraddress_from_image image with
      | Ok server ->
          let json = auth_config_json ~user ~pass ~serveraddress:server () in
          Some (Base64.encode_string (Yojson.Safe.to_string json))
      | Error _ -> None)
  | _ -> None

(* Secrets never enter the crontab line -- Crontab.run_payload_of_cron_job does
   not carry secret_env_vars, deliberately -- so they are placed on the box
   here, at deploy time, and read back by Run when the job fires.

   Every declared job is written even when it declares no secrets, so that
   withdrawing a credential truncates the file rather than leaving the last one
   behind for the next run to pick up. *)
let write_cron_secrets (cron_jobs : Simple.cron_job list option) :
    (unit, string) result =
  let write (c : Simple.cron_job) =
    Cron_secrets.write_env_file ~name:c.name
      (Option.value c.secret_env_vars ~default:[])
  in
  List.fold_left
    (fun acc job ->
      match acc with
      | Error _ -> acc
      | Ok () -> write job)
    (Ok ())
    (Option.value cron_jobs ~default:[])

let registry_auth_for_cron (c : Simple.cron_job) =
  match (c.registry_user, c.registry_pass) with
  | Some user, Some pass -> (
      match serveraddress_from_image c.image with
      | Ok server ->
          let json = auth_config_json ~user ~pass ~serveraddress:server () in
          Some (Base64.encode_string (Yojson.Safe.to_string json))
      | Error _ -> None)
  | _ -> None

let image_name_and_tag image = Simple.require_image_and_tag image

let tag_from_image image =
  match Simple.parse_image_and_tag image with
  | Ok (_name, "") -> "unknown"
  | Ok (_name, tag) -> tag
  | Error _ -> "unknown"

(* ------------------------------------------------------------------------- *)
(* Types                                                                     *)
(* ------------------------------------------------------------------------- *)

type deploy_action =
  | EnsureCronNetwork
  | PullCronImages of Simple.cron_job list
  | UpsertCrontab of Simple.cron_job list option

type deploy_error = Invalid_request of string | Orchestrator_failure of string

let deploy_error_message = function
  | Invalid_request msg
  | Orchestrator_failure msg ->
      msg

(* The failure class alone picks the status, so the Dream handler carries no
   decision of its own. [Invalid_request] is a value the caller wrote that
   failed a precondition and answers 400, matching what this endpoint already
   returns for a body it cannot decode; [Orchestrator_failure] is a fault on
   Bondi's side of the call and answers 500. The sibling /run endpoint
   classifies the same way. *)
let status_of_deploy_error : deploy_error -> Dream.status = function
  | Invalid_request _ -> `Bad_Request
  | Orchestrator_failure _ -> `Internal_Server_Error

let ( let* ) = Result.bind

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
    (deploy_action list, deploy_error) result =
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
        (Invalid_request
           (Printf.sprintf
              "cron jobs declare networks bondi does not manage (%s). bondi \
               manages only %s: declare that instead, and attach the \
               containers these jobs must reach to %s too"
              (String.concat ", " offenders)
              shared shared))

let cron_plan (input : Simple.deploy_input) :
    (deploy_action list, deploy_error) result =
  match input.cron_jobs with
  | None
  | Some [] ->
      Ok []
  | Some jobs ->
      let* network_actions = cron_network_action jobs in
      Ok (network_actions @ [ PullCronImages jobs; UpsertCrontab (Some jobs) ])

(* ------------------------------------------------------------------------- *)
(* Phase 2: Interpreter                                                      *)
(* ------------------------------------------------------------------------- *)

let interpret ~client ~net (actions : deploy_action list) :
    (unit, string) result =
  let rec pull_cron_images = function
    | [] -> Ok ()
    | (c : Simple.cron_job) :: rest ->
        let* image_name, tag = image_name_and_tag c.image in
        let auth = registry_auth_for_cron c in
        let* () =
          Docker.Client.pull_image client ~net ~image:image_name ~tag
            ~registry_auth:auth
        in
        pull_cron_images rest
  in
  let rec run = function
    | [] -> Ok ()
    | EnsureCronNetwork :: rest ->
        let* () =
          Docker.Client.create_network_if_not_exists client ~net
            ~network_name:Bondi_common.Defaults.network_name
        in
        run rest
    | PullCronImages jobs :: rest ->
        let* () = pull_cron_images jobs in
        run rest
    | UpsertCrontab cron_jobs :: rest -> (
        (* The secret files are written before the crontab, not after: a line
           that fires against a missing file runs the job without its
           credentials, which fails somewhere inside the container and reports
           as the job being broken. Writing first means the only ordering
           failure is a crontab that was not updated, which reports as itself. *)
        match write_cron_secrets cron_jobs with
        | Error msg ->
            Error ("Deploy succeeded but writing cron secrets failed: " ^ msg)
        | Ok () -> (
            match Crontab.upsert cron_jobs with
            | Ok () -> run rest
            | Error msg ->
                Error ("Deploy succeeded but crontab update failed: " ^ msg)))
  in
  run actions

(* ------------------------------------------------------------------------- *)
(* JSON / HTTP                                                               *)
(* ------------------------------------------------------------------------- *)

let decode_input body =
  match Yojson.Safe.from_string body with
  | exception Yojson.Json_error msg -> Error ("invalid JSON: " ^ msg)
  | json ->
      Simple.deploy_input_of_yojson json
      |> Result.map_error (fun msg -> "invalid deploy payload: " ^ msg)

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

let has_healthcheck ~client ~net ~image =
  match Docker.Client.inspect_image client ~net ~image with
  | Ok inspect -> (
      match inspect.container_config with
      | Some cc -> Option.is_some cc.healthcheck
      | None -> false)
  | Error _ -> false

let try_pull_main_image ~client ~net input =
  match input.Simple.image with
  | None -> Error "image is required for service deployment"
  | Some image ->
      let auth = registry_auth input in
      let* image_name, tag = image_name_and_tag image in
      Docker.Client.pull_image client ~net ~image:image_name ~tag
        ~registry_auth:auth
      |> Result.map_error (fun msg ->
          Printf.sprintf "failed to pull image %s: %s" image msg)

let select_strategy_and_prepare ~client ~net input :
    (deployment_strategy * string, string) result =
  match input.Simple.deployment_strategy with
  | Some s -> (
      match deployment_strategy_of_string s with
      | None ->
          Error
            (Printf.sprintf
               "unknown deployment_strategy: %s (valid values: blue-green, \
                simple)"
               s)
      | Some Simple -> Ok (Simple, "configured in bondi.yaml")
      | Some Blue_green ->
          let* () = try_pull_main_image ~client ~net input in
          Ok (Blue_green, "configured in bondi.yaml"))
  | None -> (
      let* () = try_pull_main_image ~client ~net input in
      match input.image with
      | None -> Error "image is required for service deployment"
      | Some image ->
          if has_healthcheck ~client ~net ~image then
            Ok (Blue_green, "image has HEALTHCHECK")
          else Ok (Simple, "image has no HEALTHCHECK"))

let deploy_workload ~clock ~client ~net ~strategy input =
  match strategy with
  | Blue_green -> Strategy.Blue_green.deploy ~clock ~client ~net ~input
  | Simple -> Simple.deploy ~clock ~client ~net input

(* Everything below the plan is Bondi acting on the caller's behalf, so a
   failure there is Bondi's fault by construction. [cron_plan] is the one step
   that can fail on what the caller wrote, and it classifies its own error. *)
let orchestrator_step result =
  Result.map_error (fun m -> Orchestrator_failure m) result

let run_deploy ~clock ~net input =
  Lwt_eio.run_eio @@ fun () ->
  let client = Docker.Client.create ?registry_auth:(registry_auth input) () in
  (* The cron plan is pure and depends only on [input], so it runs before any
     workload is touched: a rejected network declaration must not be discovered
     after the service has already moved to a new tag. *)
  let* actions = cron_plan input in
  match input.Simple.service_name with
  | None ->
      (* Cron-only deploy: skip main image pull and workload deployment *)
      let* () = orchestrator_step (interpret ~client ~net actions) in
      Ok
        (build_response ~strategy:Simple ~strategy_reason:"cron-only deploy"
           input)
  | Some _ ->
      let* strategy, strategy_reason =
        orchestrator_step (select_strategy_and_prepare ~client ~net input)
      in
      let* () =
        orchestrator_step (deploy_workload ~clock ~client ~net ~strategy input)
      in
      let* () = orchestrator_step (interpret ~client ~net actions) in
      Ok (build_response ~strategy ~strategy_reason input)

let route ~clock ~net =
  Dream.post "/deploy" @@ fun req ->
  let open Lwt.Infix in
  let%lwt body = Dream.body req in
  match decode_input body with
  | Error msg -> Dream.respond ~status:`Bad_Request ("Bad request: " ^ msg)
  | Ok input ->
      Lwt.catch
        (fun () ->
          run_deploy ~clock ~net input >>= function
          | Ok response ->
              response
              |> deploy_response_to_yojson
              |> Yojson.Safe.to_string
              |> Dream.json
          | Error err ->
              Dream.respond
                ~status:(status_of_deploy_error err)
                ("Error deploying: " ^ deploy_error_message err))
        (fun exn ->
          Dream.respond ~status:`Internal_Server_Error (Printexc.to_string exn))
