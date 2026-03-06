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

type run_response = { exit_code : int; warning : string option }
[@@deriving yojson]

let env_vars_to_list = function
  | None -> None
  | Some env -> Some (List.map (fun (k, v) -> k ^ "=" ^ v) env)

let parse_image image =
  match Strategy.Simple.parse_image_and_tag image with
  | Ok (name, "") -> (name, "latest")
  | Ok (name, tag) -> (name, tag)
  | Error _ -> (image, "latest")

let temp_container_name job =
  let ts = Unix.gettimeofday () |> Float.to_string in
  Printf.sprintf "%s-%s" job ts

let best_effort_remove_old ~client ~net ~job =
  match Docker.Client.get_container_by_name client ~net ~container_name:job with
  | None -> None
  | Some old -> (
      try
        Docker.Client.remove_container client ~net ~container_id:old.id;
        None
      with
      | exn -> Some ("failed to remove old container: " ^ Printexc.to_string exn)
      )

let best_effort_rename ~client ~net ~container_id ~job =
  try
    Docker.Client.rename_container client ~net ~container_id ~new_name:job;
    None
  with
  | exn -> Some ("failed to rename container: " ^ Printexc.to_string exn)

let combine_warnings w1 w2 =
  match (w1, w2) with
  | None, None -> None
  | Some w, None
  | None, Some w ->
      Some w
  | Some a, Some b -> Some (a ^ "; " ^ b)

let run ~client ~net body =
  let* payload =
    try Ok (run_payload_of_yojson (Yojson.Safe.from_string body)) with
    | Yojson.Json_error msg -> Error ("invalid JSON: " ^ msg)
    | Of_yojson_error _ -> Error "invalid run payload"
  in
  let image_name, tag = parse_image payload.image in
  let full_image = image_name ^ ":" ^ tag in
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
    let container_name = temp_container_name payload.job in
    let opts : Docker.Client.run_image_options =
      { container_name; config; host_config = None; networking_conf = None }
    in
    let container_id = Docker.Client.run_image_with_opts client ~net opts in
    let exit_code = Docker.Client.wait_container client ~net ~container_id in
    let w1 = best_effort_remove_old ~client ~net ~job:payload.job in
    let w2 = best_effort_rename ~client ~net ~container_id ~job:payload.job in
    let warning = combine_warnings w1 w2 in
    Ok { exit_code; warning }
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
