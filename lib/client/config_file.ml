include Bondi_common.Json_utils

type server_ssh = {
  user : string;
  private_key_contents : string;
  private_key_pass : string;
}
[@@deriving yojson]

type server = { ip_address : string; ssh : server_ssh option [@default None] }
[@@deriving yojson]

type user_service = {
  name : string;
  image : string; (* Base image without tag, e.g. registry.com/app *)
  port : int;
  registry_user : string option; [@default None]
  registry_pass : string option; [@default None]
  env_vars : string_map;
  servers : server list;
  drain_grace_period : int option; [@default None]
  deployment_strategy : string option; [@default None]
  health_timeout : int option; [@default None]
  poll_interval : int option; [@default None]
  logs : bool option; [@default None]
}
[@@deriving yojson]

type bondi_server = { version : string } [@@deriving yojson]

type traefik = { domain_name : string; image : string; acme_email : string }
[@@deriving yojson]

type cron_job = {
  name : string;
  image : string; (* Base image without tag *)
  schedule : string;
  env_vars : string_map option; [@default None]
  registry_user : string option; [@default None]
  registry_pass : string option; [@default None]
  server : server;
}
[@@deriving yojson]

type alloy_grafana_cloud = {
  instance_id : string;
  api_key : string;
  endpoint : string;
}
[@@deriving yojson]

type alloy = {
  image : string option; [@default None]
  grafana_cloud : alloy_grafana_cloud;
  collect : string option; [@default None]
  labels : string_map option; [@default None]
}
[@@deriving yojson]

type t = {
  user_service : user_service option; [@key "service"] [@default None]
  bondi_server : bondi_server; [@key "bondi_server"]
  traefik : traefik option; [@key "traefik"] [@default None]
  cron_jobs : cron_job list option; [@key "cron_jobs"] [@default None]
  alloy : alloy option; [@key "alloy"] [@default None]
}
[@@deriving yojson]

(* Returns all servers: from user_service and from each cron job's server. Deduplicated by ip_address. *)
let servers config =
  let from_service =
    match config.user_service with
    | Some s -> s.servers
    | None -> []
  in
  let from_cron =
    match config.cron_jobs with
    | Some jobs -> List.map (fun j -> j.server) jobs
    | None -> []
  in
  let all = from_service @ from_cron in
  (* Dedupe by ip_address, preserving order (first occurrence wins) *)
  let seen = ref [] in
  List.filter
    (fun s ->
      if List.mem s.ip_address !seen then false
      else (
        seen := s.ip_address :: !seen;
        true))
    all

let config_file_name = "bondi.yaml"

let read_file path =
  try
    let ic = open_in path in
    let length = in_channel_length ic in
    let contents = really_input_string ic length in
    close_in ic;
    Ok contents
  with
  | exn -> Error (Printexc.to_string exn)

let env_map () =
  let entries = Unix.environment () |> Array.to_list in
  let parse_entry entry =
    match String.split_on_char '=' entry with
    | [] -> None
    | key :: rest -> Some (key, String.concat "=" rest)
  in
  List.filter_map parse_entry entries

let apply_env_template contents =
  let env = env_map () in
  let data = `O (List.map (fun (key, value) -> (key, `String value)) env) in
  Mustache.(render (of_string contents) data)

let rec yojson_of_yaml = function
  | `O assoc ->
      `Assoc (List.map (fun (key, value) -> (key, yojson_of_yaml value)) assoc)
  | `A list -> `List (List.map yojson_of_yaml list)
  | `String value -> `String value
  | `Float value ->
      (* YAML does not distinguish int from float; coerce whole numbers *)
      let truncated = Float.trunc value in
      if Float.equal truncated value then `Int (int_of_float value)
      else `Float value
  | `Bool value -> `Bool value
  | `Null -> `Null

let ensure_optional_key key = function
  | `Assoc assoc ->
      let has_key = List.exists (fun (k, _) -> k = key) assoc in
      if has_key then `Assoc assoc else `Assoc (assoc @ [ (key, `Null) ])
  | other -> other

let ensure_cron_jobs_key = ensure_optional_key "cron_jobs"
let ensure_service_key = ensure_optional_key "service"
let ensure_traefik_key = ensure_optional_key "traefik"
let ensure_alloy_key = ensure_optional_key "alloy"

let validate_alloy_collect config =
  match config.alloy with
  | None -> Ok config
  | Some alloy -> (
      match alloy.collect with
      | None -> Ok config
      | Some s -> (
          match Bondi_common.Alloy_river.collect_mode_of_string s with
          | Ok _ -> Ok config
          | Error msg -> Error msg))

let read () =
  match read_file config_file_name with
  | Error message -> Error message
  | Ok contents -> (
      let rendered = apply_env_template contents in
      match Yaml.of_string rendered with
      | Error (`Msg message) -> Error message
      | Ok yaml ->
          let ( let* ) = Result.bind in
          let json =
            yaml
            |> yojson_of_yaml
            |> ensure_cron_jobs_key
            |> ensure_service_key
            |> ensure_traefik_key
            |> ensure_alloy_key
          in
          let* config =
            of_yojson json
            |> Result.map_error (fun msg -> "invalid bondi.yaml: " ^ msg)
          in
          validate_alloy_collect config)
