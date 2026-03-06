open Ppx_yojson_conv_lib.Yojson_conv
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
    | [ n ]
    | n :: _ ->
        n
    | [] -> "docker.io"
  in
  match String.split_on_char '/' name with
  | registry :: _ -> registry
  | [] -> "docker.io"

let auth_config_json ~user ~pass ?serveraddress () =
  let base = [ ("username", `String user); ("password", `String pass) ] in
  let entries =
    match serveraddress with
    | Some addr -> ("serveraddress", `String addr) :: base
    | None -> base
  in
  `Assoc entries

let registry_auth (input : Simple.deploy_input) =
  match (input.registry_user, input.registry_pass) with
  | Some user, Some pass ->
      let server = serveraddress_from_image input.image in
      let json = auth_config_json ~user ~pass ~serveraddress:server () in
      Some (Base64.encode_string (Yojson.Safe.to_string json))
  | _ -> None

let registry_auth_for_cron (c : Simple.cron_job) =
  match (c.registry_user, c.registry_pass) with
  | Some user, Some pass ->
      let server = serveraddress_from_image c.image in
      let json = auth_config_json ~user ~pass ~serveraddress:server () in
      Some (Base64.encode_string (Yojson.Safe.to_string json))
  | _ -> None

let image_name_and_tag image =
  match Simple.parse_image_and_tag image with
  | Ok (name, "") -> (name, "latest")
  | Ok (name, tag) -> (name, tag)
  | Error _ -> (image, "latest")

let tag_from_image image = snd (image_name_and_tag image)

(* ------------------------------------------------------------------------- *)
(* Types                                                                     *)
(* ------------------------------------------------------------------------- *)

type deploy_action =
  | PullCronImages of Simple.cron_job list
  | UpsertCrontab of Simple.cron_job list option

(* ------------------------------------------------------------------------- *)
(* Phase 1: Plan (pure)                                                      *)
(* ------------------------------------------------------------------------- *)

let cron_plan (input : Simple.deploy_input) : deploy_action list =
  match input.cron_jobs with
  | None
  | Some [] ->
      []
  | Some jobs -> [ PullCronImages jobs; UpsertCrontab (Some jobs) ]

(* ------------------------------------------------------------------------- *)
(* Phase 2: Interpreter                                                      *)
(* ------------------------------------------------------------------------- *)

let ( let* ) = Result.bind

let interpret ~client ~net (actions : deploy_action list) :
    (unit, string) result =
  let rec run = function
    | [] -> Ok ()
    | PullCronImages jobs :: rest ->
        List.iter
          (fun (c : Simple.cron_job) ->
            let image_name, tag = image_name_and_tag c.image in
            let auth = registry_auth_for_cron c in
            Docker.Client.pull_image client ~net ~image:image_name ~tag
              ~registry_auth:auth)
          jobs;
        run rest
    | UpsertCrontab cron_jobs :: rest -> (
        match Crontab.upsert cron_jobs with
        | Ok () -> run rest
        | Error msg ->
            Error ("Deploy succeeded but crontab update failed: " ^ msg))
  in
  run actions

(* ------------------------------------------------------------------------- *)
(* JSON / HTTP                                                               *)
(* ------------------------------------------------------------------------- *)

let decode_input body =
  try Ok (Simple.deploy_input_of_yojson (Yojson.Safe.from_string body)) with
  | Yojson.Json_error msg -> Error ("invalid JSON: " ^ msg)
  | Of_yojson_error (exn, yojson) ->
      Error
        (Printf.sprintf "invalid deploy payload: %s (json: %s)"
           (Printexc.to_string exn)
           (Yojson.Safe.to_string yojson))
  | exn -> Error (Printexc.to_string exn)

let build_response ~strategy ~strategy_reason (input : Simple.deploy_input) =
  {
    status = "Deploy initiated";
    tag = tag_from_image input.image;
    strategy = string_of_deployment_strategy strategy;
    strategy_reason;
  }

let has_healthcheck ~client ~net ~image =
  let inspect = Docker.Client.inspect_image client ~net ~image in
  Option.is_some inspect.container_config.healthcheck

let pull_main_image ~client ~net input =
  let auth = registry_auth input in
  let image_name, tag = image_name_and_tag input.Simple.image in
  Docker.Client.pull_image client ~net ~image:image_name ~tag
    ~registry_auth:auth

let try_pull_main_image ~client ~net input =
  try
    pull_main_image ~client ~net input;
    Ok ()
  with
  | exn ->
      Error
        (Printf.sprintf "failed to pull image %s: %s" input.Simple.image
           (Printexc.to_string exn))

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
  | None ->
      let* () = try_pull_main_image ~client ~net input in
      if has_healthcheck ~client ~net ~image:input.image then
        Ok (Blue_green, "image has HEALTHCHECK")
      else Ok (Simple, "image has no HEALTHCHECK")

let deploy_workload ~clock ~client ~net ~strategy input =
  match strategy with
  | Blue_green -> Strategy.Blue_green.deploy ~clock ~client ~net ~input
  | Simple -> Simple.deploy ~clock ~client ~net input

let run_deploy ~clock ~net input =
  Lwt_eio.run_eio @@ fun () ->
  let client = Docker.Client.create ?registry_auth:(registry_auth input) () in
  let* strategy, strategy_reason =
    select_strategy_and_prepare ~client ~net input
  in
  let* () = deploy_workload ~clock ~client ~net ~strategy input in
  let* () = interpret ~client ~net (cron_plan input) in
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
              |> yojson_of_deploy_response
              |> Yojson.Safe.to_string
              |> Dream.json
          | Error msg ->
              Dream.respond ~status:`Internal_Server_Error
                ("Error deploying: " ^ msg))
        (fun exn ->
          Dream.respond ~status:`Internal_Server_Error (Printexc.to_string exn))
