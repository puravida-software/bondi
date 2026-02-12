open Ppx_yojson_conv_lib.Yojson_conv
module Simple = Strategy.Simple

type deploy_response = { status : string; tag : string } [@@deriving yojson]

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

let tag_from_image image =
  match String.split_on_char ':' image with
  | [ _; tag ] -> tag
  | _ -> "latest"

let parse_cron_image image =
  match String.split_on_char ':' image with
  | [ name; tag ] -> (name, tag)
  | [ name ] -> (name, "latest")
  | _ -> (image, "latest")

(* ------------------------------------------------------------------------- *)
(* Types                                                                     *)
(* ------------------------------------------------------------------------- *)

type deploy_action =
  | DeployWorkload
  | PullCronImages of Simple.cron_job list
  | UpsertCrontab of Simple.cron_job list option

(* ------------------------------------------------------------------------- *)
(* Phase 1: Plan (pure)                                                      *)
(* ------------------------------------------------------------------------- *)

let plan (input : Simple.deploy_input) : deploy_action list =
  let base = [ DeployWorkload ] in
  let cron_actions =
    match input.cron_jobs with
    | None
    | Some [] ->
        [ UpsertCrontab input.cron_jobs ]
    | Some jobs -> [ PullCronImages jobs; UpsertCrontab (Some jobs) ]
  in
  base @ cron_actions

(* ------------------------------------------------------------------------- *)
(* Phase 2: Interpreter                                                      *)
(* ------------------------------------------------------------------------- *)

let ( let* ) = Result.bind

let interpret ~clock ~client ~net input (actions : deploy_action list) :
    (unit, string) result =
  let rec run = function
    | [] -> Ok ()
    | DeployWorkload :: rest ->
        let* () = Simple.deploy ~clock ~client ~net input in
        run rest
    | PullCronImages jobs :: rest ->
        List.iter
          (fun (c : Simple.cron_job) ->
            let image_name, tag = parse_cron_image c.image in
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

let build_response (input : Simple.deploy_input) =
  { status = "Deploy initiated"; tag = tag_from_image input.image }

let run_deploy ~clock ~net input =
  Lwt_eio.run_eio @@ fun () ->
  let client = Docker.Client.create ?registry_auth:(registry_auth input) () in
  let actions = plan input in
  let* () = interpret ~clock ~client ~net input actions in
  Ok (build_response input)

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
