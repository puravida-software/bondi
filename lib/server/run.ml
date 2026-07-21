(* POST /api/v1/run - Execute a cron job.
   Request body: {"job":"name","image":"...","env_vars":{...}} *)

open Json_helpers

let ( let* ) = Result.bind

type run_payload = {
  job : string;
  image : string;
  network : string option; [@default None]
  env_vars : string_map option; [@default None]
}
[@@deriving yojson]

type run_response = { exit_code : int; warning : string option [@default None] }
[@@deriving yojson]

let env_vars_to_list = function
  | None -> None
  | Some env -> Some (List.map (fun (k, v) -> k ^ "=" ^ v) env)

let networking_conf_of_network :
    string option -> Docker.Client.networking_config option = function
  | None -> None
  | Some network ->
      let endpoint : Docker.Client.endpoint_config =
        { aliases = None; ipv4_address = None }
      in
      Some { endpoints_config = Some [ (network, endpoint) ] }

let parse_image image = Strategy.Simple.require_image_and_tag image

let temp_container_name job =
  let ts = Unix.gettimeofday () |> Float.to_string in
  Printf.sprintf "%s-%s" job ts

let best_effort_remove_old ~client ~net ~job =
  match Docker.Client.get_container_by_name client ~net ~container_name:job with
  | Error msg -> Some ("failed to look up old container: " ^ msg)
  | Ok None -> None
  | Ok (Some old) -> (
      match Docker.Client.remove_container client ~net ~container_id:old.id with
      | Ok () -> None
      | Error msg -> Some ("failed to remove old container: " ^ msg))

let best_effort_rename ~client ~net ~container_id ~job =
  match
    Docker.Client.rename_container client ~net ~container_id ~new_name:job
  with
  | Ok () -> None
  | Error msg -> Some ("failed to rename container: " ^ msg)

let combine_warnings w1 w2 =
  match (w1, w2) with
  | None, None -> None
  | Some w, None
  | None, Some w ->
      Some w
  | Some a, Some b -> Some (a ^ "; " ^ b)

let run_opts ~container_name ~full_image payload :
    Docker.Client.run_image_options =
  let config : Docker.Client.container_config =
    {
      image = Some full_image;
      env = env_vars_to_list payload.env_vars;
      cmd = None;
      entrypoint = None;
      hostname = None;
      working_dir = None;
      labels =
        Some
          [
            ("bondi.managed", "true");
            ("bondi.type", "cron");
            ("bondi.logs", "true");
          ];
      exposed_ports = None;
    }
  in
  {
    container_name;
    config;
    host_config = None;
    networking_conf = networking_conf_of_network payload.network;
  }

let run ~client ~net body =
  let* payload =
    match Yojson.Safe.from_string body with
    | exception Yojson.Json_error msg -> Error ("invalid JSON: " ^ msg)
    | json ->
        run_payload_of_yojson json
        |> Result.map_error (fun msg -> "invalid run payload: " ^ msg)
  in
  let* image_name, tag = parse_image payload.image in
  let full_image = image_name ^ ":" ^ tag in
  let container_name = temp_container_name payload.job in
  let opts = run_opts ~container_name ~full_image payload in
  let* container_id = Docker.Client.run_image_with_opts client ~net opts in
  let* exit_code = Docker.Client.wait_container client ~net ~container_id in
  let w1 = best_effort_remove_old ~client ~net ~job:payload.job in
  let w2 = best_effort_rename ~client ~net ~container_id ~job:payload.job in
  let warning = combine_warnings w1 w2 in
  Ok { exit_code; warning }

let route ~client ~net =
  Dream.post "/run" @@ fun req ->
  let%lwt body = Dream.body req in
  match run ~client ~net body with
  | Ok response ->
      response |> run_response_to_yojson |> Yojson.Safe.to_string |> Dream.json
  | Error msg -> Dream.respond ~status:`Not_Found ("Run failed: " ^ msg)
