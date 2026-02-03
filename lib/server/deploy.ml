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

let run_deploy ~clock ~net input =
  Lwt_eio.run_eio @@ fun () ->
  let client = Docker.Client.create ?registry_auth:(registry_auth input) () in
  Simple.deploy ~clock ~client ~net input

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
          | Ok () ->
              { status = "Deploy initiated"; tag = input.tag }
              |> yojson_of_deploy_response
              |> Yojson.Safe.to_string
              |> Dream.json
          | Error msg ->
              Dream.respond ~status:`Internal_Server_Error
                ("Error deploying: " ^ msg))
        (fun exn ->
          Dream.respond ~status:`Internal_Server_Error (Printexc.to_string exn))
