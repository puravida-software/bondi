include Bondi_common.Json_utils

(* Both key fields are absent when a manifest declines to carry key material,
   which is a legitimate shape rather than an omission: a developer should not
   paste a private key into a configuration file to use a credential they
   already hold, and a hardware-backed key cannot be carried as a string at all.
   A block naming only a [user] is what such a manifest looks like, and it is
   what `bondi init` now scaffolds.

   Declared optional rather than removed, because parsing is strict and every
   manifest in the estate sets both fields today; a removed field would stop
   every one of them from decoding.

   [None] is the absence of the field, and it is not the same value as
   [Some ""]. The alternative -- a plain [string] defaulted to [""] -- would put
   a sentinel where the absence belongs, which is the distinction between "not
   set" and "set to empty" placed beyond the type's reach and re-derived by
   every reader. Nothing here has to collapse the two: [Private_key.passphrase]
   already answers [None] for the empty string, so an absent field and an empty
   one reach the same resolution without a second emptiness test. *)
type server_ssh = {
  user : string;
  private_key_contents : string option; [@default None]
  private_key_pass : string option; [@default None]
}
[@@deriving yojson]

type server = {
  ip_address : string;
  ssh : server_ssh option; [@default None]
  (* Accepted and never read. Nothing dials the orchestrator any more -- every
     bondi command reaches a box by running the server's subcommands inside its
     container over SSH -- and `bondi setup` publishes no host port for the
     orchestrator at all, so there is no port for this to name. Setting it
     therefore changes nothing.

     It is kept because the deriver decodes strictly: a bondi.yaml written
     before that change and still carrying `port:` under a server would stop
     parsing if the field were removed. Not to be confused with
     [user_service.port] below, which is the port your own container listens
     on and is very much read. *)
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

(* [bind_address] and [api_token] are accepted and do nothing. The orchestrator
   serves nothing over the network -- there is no socket to bind and no request
   to authenticate -- and neither field reaches the command that starts the
   container: no port is published and no environment is passed. Every bondi
   command already reached the orchestrator by running its subcommands inside
   its container over SSH, and so does the crontab, so nothing lost a route.

   They are still parsed rather than dropped from the record because parsing is
   strict: removing the fields would fail the whole read of any bondi.yaml that
   declares one, which is hardest on exactly the boxes most likely to have
   declared them.

   Declaring either is said out loud where the configuration is acted on --
   see Deprecations -- rather than silently accepted here, because a dead knob
   nothing mentions is a dead knob nobody removes. [api_token]'s message also
   says to rotate the value: a credential that sat in a configuration file is
   compromised whether or not anything still reads it. *)
type bondi_server = {
  version : string;
  bind_address : string option; [@default None]
  api_token : string option; [@default None]
}
[@@deriving yojson]

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
  (* Written to a mode-600 file on the box instead of into the crontab line.
     See lib/server/cron_secrets.ml for why the distinction exists. *)
  secret_env_vars : string_map option; [@default None]
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

(* The credentials reach the host as a [KEY=VALUE] environment file, and
   [docker run --env-file] reads one record per line with no quoting or
   escaping syntax. A control character in a value is therefore not data: a
   newline ends the record and whatever follows declares a variable nobody
   wrote. The values are rejected here, where the configuration is read, rather
   than escaped where the file is rendered -- there is no escape --env-file
   would decode -- so every later reader of an [alloy] block holds values it
   can write verbatim. The message names the variable and never the value,
   which is a credential.

   An [=] inside a value is left alone: --env-file takes everything after the
   first [=] to the end of the line as the value, so an [=] beyond it reshapes
   nothing. *)
let validate_alloy_credentials config =
  match config.alloy with
  | None -> Ok config
  | Some alloy -> (
      let offending =
        List.find_opt
          (fun (_, value) -> Bondi_common.String_utils.has_control_char value)
          [
            ("GRAFANA_CLOUD_INSTANCE_ID", alloy.grafana_cloud.instance_id);
            ("GRAFANA_CLOUD_API_KEY", alloy.grafana_cloud.api_key);
          ]
      in
      match offending with
      | None -> Ok config
      | Some (variable, _) ->
          Error
            (Printf.sprintf
               "invalid Grafana Cloud credential for %s: values may not \
                contain control characters"
               variable))

(* An encrypted private key with nothing to unlock it cannot sign, and the key
   file states its own cipher in cleartext, so the configuration is refused
   where it is read rather than at the connection. Left to the connection, ssh
   offers the key -- an OpenSSH key file carries its public half in cleartext --
   the host accepts it, and the signature that never comes is reported by the
   host as an authorization failure: someone else's verdict on a fault that is
   entirely local, which is the thing this refusal exists to stop.

   The rule [validate_alloy_credentials] states holds here too: the message
   names the fields and never their values, one of which is a credential.

   The walk is over [servers], which is the deduplicated list: a cron job whose
   server block repeats an [ip_address] already seen is dropped there, so an
   [ssh] block that differs from the one the first occurrence carried is never
   classified here. What that costs is the early report, not the refusal --
   [Remote_exec] asks [Private_key.identity] again for the server it is about to
   open a session to, and refuses in the same sentence before anything is staged
   or dialled.

   The first refusal ends the read. A file that cannot authenticate to one
   server is a file to fix, not a run to begin, and repeating the same refusal
   once per host says nothing the first one did not. *)
let validate_ssh_identity config =
  let refusal server =
    match server.ssh with
    | None -> None
    | Some ssh -> (
        match
          Private_key.identity ~contents:ssh.private_key_contents
            ~passphrase:ssh.private_key_pass
        with
        | Private_key.Ambient
        | Private_key.Staged_key
        | Private_key.Own_agent _ ->
            None
        | Private_key.Refused { reason } ->
            Some (Private_key.refusal_message ~server:server.ip_address ~reason)
        )
  in
  match List.find_map refusal (servers config) with
  | None -> Ok config
  | Some message -> Error message

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
          let* config = validate_alloy_credentials config in
          let* config = validate_ssh_identity config in
          let* _ = managed_containers config in
          Ok config)
