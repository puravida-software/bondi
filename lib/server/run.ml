(* POST /api/v1/run - Execute a cron job.
   Request body: {"job":"name","image":"...","env_vars":{...}} *)

open Ppx_yojson_conv_lib.Yojson_conv
open Json_helpers

let ( let* ) = Result.bind

type run_payload = {
  job : string;
  image : string;
  env_vars : string_map option;
}
[@@deriving yojson]

type run_response = { exit_code : int } [@@deriving yojson]

let env_vars_to_list = function
  | None -> None
  | Some env -> Some (List.map (fun (k, v) -> k ^ "=" ^ v) env)

let parse_image image =
  match String.split_on_char ':' image with
  | [ name; tag ] -> (name, tag)
  | [ name ] -> (name, "latest")
  | _ -> (image, "latest")

let run ~client ~net body =
  let* payload =
    try Ok (run_payload_of_yojson (Yojson.Safe.from_string body)) with
    | Yojson.Json_error msg -> Error ("invalid JSON: " ^ msg)
    | Of_yojson_error _ -> Error "invalid run payload"
  in
  let image_name, tag = parse_image payload.image in
  let full_image =
    if tag = "" || tag = "latest" then image_name ^ ":" ^ tag
    else image_name ^ ":" ^ tag
  in
  try
    let config : Docker.Client.container_config =
      {
        image = Some full_image;
        env = env_vars_to_list payload.env_vars;
        cmd = None;
        entrypoint = None;
        hostname = None;
        working_dir = None;
        labels = None;
        exposed_ports = None;
      }
    in
    let container_name =
      Printf.sprintf "bondi-cron-%s-%d" payload.job (Unix.getpid ())
    in
    let opts : Docker.Client.run_image_options =
      { container_name; config; host_config = None; networking_conf = None }
    in
    let container_id = Docker.Client.run_image_with_opts client ~net opts in
    let exit_code = Docker.Client.wait_container client ~net ~container_id in
    Docker.Client.remove_container client ~net ~container_id;
    Ok { exit_code }
  with
  | Docker.Client.Docker_error msg -> Error msg
  | exn -> Error (Printexc.to_string exn)

let route ~client ~net =
  Dream.post "/run" @@ fun req ->
  let%lwt body = Dream.body req in
  match run ~client ~net body with
  | Ok response ->
      response |> yojson_of_run_response |> Yojson.Safe.to_string |> Dream.json
  | Error msg -> Dream.respond ~status:`Not_Found ("Run failed: " ^ msg)
