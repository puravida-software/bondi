open Ppx_yojson_conv_lib.Yojson_conv
module Simple = Strategy.Simple

type deploy_response = { status : string; tag : string } [@@deriving yojson]

let registry_auth (input : Simple.deploy_input) =
  match (input.registry_user, input.registry_pass) with
  | Some user, Some pass ->
      let json =
        `Assoc [ ("Username", `String user); ("Password", `String pass) ]
      in
      Some (Base64.encode_string (Yojson.Safe.to_string json))
  | _ -> None

let decode_input body =
  try Ok (Simple.deploy_input_of_yojson (Yojson.Safe.from_string body)) with
  | Yojson.Json_error msg -> Error ("invalid JSON: " ^ msg)
  | Of_yojson_error (exn, yojson) ->
      Error
        (Printf.sprintf "invalid deploy payload: %s (json: %s)"
           (Printexc.to_string exn)
           (Yojson.Safe.to_string yojson))
  | exn -> Error (Printexc.to_string exn)

let parse_cron_image image =
  match String.split_on_char ':' image with
  | [ name; tag ] -> (name, tag)
  | [ name ] -> (name, "latest")
  | _ -> (image, "latest")

let pull_cron_images ~client ~net = function
  | None
  | Some [] ->
      ()
  | Some jobs ->
      List.iter
        (fun (c : Simple.cron_job) ->
          let image_name, tag = parse_cron_image c.image in
          Docker.Client.pull_image_no_auth client ~net ~image:image_name ~tag)
        jobs

let ( let* ) = Result.bind

let run_deploy ~clock ~net input =
  Lwt_eio.run_eio @@ fun () ->
  let client = Docker.Client.create ?registry_auth:(registry_auth input) () in
  let* () = Simple.deploy ~clock ~client ~net input in
  pull_cron_images ~client ~net input.cron_jobs;
  match Crontab.upsert input.cron_jobs with
  | Ok () -> Ok { status = "Deploy initiated"; tag = input.tag }
  | Error msg -> Error ("Deploy succeeded but crontab update failed: " ^ msg)

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
