include Bondi_common.Json_utils

type server_ssh = {
  user : string;
  private_key_contents : string;
  private_key_pass : string;
}
[@@deriving yojson]

type server = {
  ip_address : string;
  ssh : server_ssh option; [@default None]
  port : int option; [@default None]
}
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

module Alert = Bondi_common.Alert

(* Both alert fields reuse the [Alert] codecs so the config record holds
   validated, illegal-state-free values (a sink is https by construction, a
   severity map has no ambiguous code). [Alert.sinks] is used directly because
   [Alert.sinks_of_yojson] already reports a string error the derived record can
   carry; [severity_map_of_yojson] reports a [severity_map_error], which it
   cannot, so this wrapper maps it to its message. *)
type exit_code_severities = Alert.severity_map

let exit_code_severities_of_yojson json =
  Alert.severity_map_of_yojson json
  |> Result.map_error Alert.severity_map_error_to_string

let exit_code_severities_to_yojson = Alert.severity_map_to_yojson

type cron_job = {
  name : string;
  image : string; (* Base image without tag *)
  schedule : string;
  network : string option; [@default None]
  env_vars : string_map option; [@default None]
  registry_user : string option; [@default None]
  registry_pass : string option; [@default None]
  alert_sinks : Alert.sinks option; [@default None]
  exit_code_severities : exit_code_severities option; [@default None]
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

type managed_container = {
  name : string;
  image : string; (* Base image without tag *)
  tag : string;
  restart : string;
  network : string option; [@default None]
  ports : string list option; [@default None]
  env_vars : string_map option; [@default None]
  secret_env_vars : string_map option; [@default None]
}
[@@deriving yojson]

type t = {
  user_service : user_service option; [@key "service"] [@default None]
  bondi_server : bondi_server; [@key "bondi_server"]
  traefik : traefik option; [@key "traefik"] [@default None]
  cron_jobs : cron_job list option; [@key "cron_jobs"] [@default None]
  alloy : alloy option; [@key "alloy"] [@default None]
  managed_containers : managed_container list option;
      [@key "managed_containers"] [@default None]
}
[@@deriving yojson]

module Managed_container = Bondi_common.Managed_container

(* Plain and secret values become one env list distinguished by constructor;
   a key declared in both maps is rejected by [Managed_container.create]. *)
let env_of_managed_container entry =
  let tagged constructor = function
    | None -> []
    | Some vars -> List.map (fun (key, value) -> (key, constructor value)) vars
  in
  tagged (fun value -> Managed_container.Plain value) entry.env_vars
  @ tagged (fun value -> Managed_container.Secret value) entry.secret_env_vars

let spec_of_managed_container entry =
  let ( let* ) = Result.bind in
  let* restart = Managed_container.restart_policy_of_string entry.restart in
  let* ports =
    Managed_container.ports_of_strings (Option.value entry.ports ~default:[])
  in
  Managed_container.create ~name:entry.name ~image:entry.image ~tag:entry.tag
    ~restart ~network:entry.network ~ports
    ~env:(env_of_managed_container entry)

let managed_containers config =
  let ( let* ) = Result.bind in
  let collect acc entry =
    let* specs = acc in
    let* spec = spec_of_managed_container entry in
    Ok (spec :: specs)
  in
  List.fold_left collect (Ok [])
    (Option.value config.managed_containers ~default:[])
  |> Result.map List.rev
  |> Result.map_error Managed_container.error_to_string

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
let ensure_managed_containers_key = ensure_optional_key "managed_containers"

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
            |> ensure_managed_containers_key
          in
          let* config =
            of_yojson json
            |> Result.map_error (fun msg -> "invalid bondi.yaml: " ^ msg)
          in
          let* config = validate_alloy_collect config in
          let* _ = managed_containers config in
          Ok config)
