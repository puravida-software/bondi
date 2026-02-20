open Ppx_yojson_conv_lib.Yojson_conv
include Bondi_common.Json_utils

let int_of_yojson json =
  match json with
  | `Int value -> value
  | `Float value ->
      let truncated = Float.trunc value in
      if Float.equal truncated value then int_of_float value
      else
        raise_error (Printf.sprintf "expected integer, got float %f" value) json
  | `String value -> int_of_string value
  | _ -> raise_error "expected integer" json

type server_ssh = {
  user : string;
  private_key_contents : string;
  private_key_pass : string;
}
[@@deriving yojson]

type server = { ip_address : string; ssh : server_ssh option }
[@@deriving yojson]

type user_service = {
  name : string;
  image : string; (* Base image without tag, e.g. registry.com/app *)
  port : int;
  registry_user : string option;
  registry_pass : string option;
  env_vars : string_map;
  servers : server list;
}
[@@deriving yojson]

type bondi_server = { version : string } [@@deriving yojson]

type traefik = { domain_name : string; image : string; acme_email : string }
[@@deriving yojson]

type cron_job = {
  name : string;
  image : string; (* Base image without tag *)
  schedule : string;
  env_vars : string_map option;
  registry_user : string option; [@default None]
  registry_pass : string option; [@default None]
  server : server;
}
[@@deriving yojson]

type t = {
  user_service : user_service option; [@key "service"]
  bondi_server : bondi_server; [@key "bondi_server"]
  traefik : traefik option; [@key "traefik"]
  cron_jobs : cron_job list option; [@key "cron_jobs"]
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
  | `Float value -> `Float value
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

let read () =
  match read_file config_file_name with
  | Error message -> Error message
  | Ok contents -> (
      let rendered = apply_env_template contents in
      match Yaml.of_string rendered with
      | Error (`Msg message) -> Error message
      | Ok yaml -> (
          let json =
            yaml
            |> yojson_of_yaml
            |> ensure_cron_jobs_key
            |> ensure_service_key
            |> ensure_traefik_key
          in
          try Ok (t_of_yojson json) with
          | Ppx_yojson_conv_lib.Yojson_conv.Of_yojson_error (exn, _) ->
              Error (Printexc.to_string exn)
          | exn -> Error (Printexc.to_string exn)))
