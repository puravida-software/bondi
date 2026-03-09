open Json_helpers

let ( let* ) = Result.bind

type t = {
  socket_path : string;
  api_version : string;
  registry_auth : string option;
}

type container = {
  id : string; [@key "Id"]
  image : string; [@key "Image"]
  image_id : string; [@key "ImageID"]
  names : string list; [@key "Names"]
  state : string option; [@default None] [@key "State"]
  status : string option; [@default None] [@key "Status"]
}
[@@deriving yojson { strict = false }]

type health_log_entry = {
  output : string; [@key "Output"]
  exit_code : int; [@key "ExitCode"]
}
[@@deriving yojson { strict = false }]

type health_state = {
  status : string; [@key "Status"]
  failing_streak : int; [@key "FailingStreak"] [@default 0]
  log : health_log_entry list; [@key "Log"] [@default []]
}
[@@deriving yojson { strict = false }]

type inspect_state = {
  status : string; [@key "Status"]
  exit_code : int; [@key "ExitCode"]
  health : health_state option; [@key "Health"] [@default None]
}
[@@deriving yojson { strict = false }]

type inspect_response = {
  created_at : string; [@key "Created"]
  restart_count : int; [@key "RestartCount"]
  state : inspect_state; [@key "State"]
}
[@@deriving yojson { strict = false }]

type restart_policy = {
  name : string; [@key "Name"]
  maximum_retry_count : int option; [@key "MaximumRetryCount"] [@default None]
}
[@@deriving yojson]

type port_binding = {
  host_ip : string option; [@key "HostIp"] [@default None]
  host_port : string option; [@key "HostPort"] [@default None]
}
[@@deriving yojson]

type port_bindings = (string * port_binding list) list

let port_bindings_to_yojson bindings =
  assoc_of_list
    (fun values -> `List (List.map port_binding_to_yojson values))
    bindings

let port_bindings_of_yojson json =
  match json with
  | `Assoc entries ->
      let rec parse = function
        | [] -> Ok []
        | (key, `List values) :: rest ->
            let rec parse_bindings acc = function
              | [] -> Ok (List.rev acc)
              | v :: vs ->
                  let* pb = port_binding_of_yojson v in
                  parse_bindings (pb :: acc) vs
            in
            let* bindings = parse_bindings [] values in
            let* rest_bindings = parse rest in
            Ok ((key, bindings) :: rest_bindings)
        | (key, _) :: _ ->
            Error (Printf.sprintf "expected list for port binding key %s" key)
      in
      parse entries
  | `Null -> Ok []
  | _ -> Error "expected object for PortBindings"

type exposed_ports = string list

let exposed_ports_to_yojson ports =
  let entries = List.map (fun port -> (port, ())) ports in
  assoc_of_list (fun () -> `Assoc []) entries

let exposed_ports_of_yojson json =
  let* entries = list_of_assoc ~field:"ExposedPorts" (fun _ -> ()) json in
  Ok (List.map fst entries)

type endpoint_config = {
  aliases : string list option; [@key "Aliases"] [@default None]
  ipv4_address : string option; [@key "IPv4Address"] [@default None]
}
[@@deriving yojson]

type endpoints_config = (string * endpoint_config) list

let endpoints_config_to_yojson configs =
  assoc_of_list endpoint_config_to_yojson configs

let endpoints_config_of_yojson json =
  match json with
  | `Assoc entries ->
      let rec parse = function
        | [] -> Ok []
        | (key, value) :: rest ->
            let* ec = endpoint_config_of_yojson value in
            let* rest_configs = parse rest in
            Ok ((key, ec) :: rest_configs)
      in
      parse entries
  | `Null -> Ok []
  | _ -> Error "expected object for EndpointsConfig"

type container_config = {
  image : string option; [@key "Image"] [@default None]
  env : string list option; [@key "Env"] [@default None]
  cmd : string list option; [@key "Cmd"] [@default None]
  entrypoint : string list option; [@key "Entrypoint"] [@default None]
  hostname : string option; [@key "Hostname"] [@default None]
  working_dir : string option; [@key "WorkingDir"] [@default None]
  labels : string_map option; [@key "Labels"] [@default None]
  exposed_ports : exposed_ports option; [@key "ExposedPorts"] [@default None]
}
[@@deriving yojson]

type host_config = {
  binds : string list option; [@key "Binds"] [@default None]
  port_bindings : port_bindings option; [@key "PortBindings"] [@default None]
  network_mode : string option; [@key "NetworkMode"] [@default None]
  restart_policy : restart_policy option; [@key "RestartPolicy"] [@default None]
}
[@@deriving yojson]

type networking_config = {
  endpoints_config : endpoints_config option;
      [@key "EndpointsConfig"] [@default None]
}
[@@deriving yojson]

type image_healthcheck = { test : string list [@key "Test"] }
[@@deriving yojson { strict = false }]

type image_container_config = {
  healthcheck : image_healthcheck option; [@key "Healthcheck"] [@default None]
}
[@@deriving yojson { strict = false }]

type image_inspect_response = {
  container_config : image_container_config option;
      [@key "ContainerConfig"] [@default None]
}
[@@deriving yojson { strict = false }]

type run_image_options = {
  container_name : string;
  config : container_config;
  host_config : host_config option;
  networking_conf : networking_config option;
}

type create_container_request = {
  image : string option; [@key "Image"] [@default None]
  env : string list option; [@key "Env"] [@default None]
  cmd : string list option; [@key "Cmd"] [@default None]
  entrypoint : string list option; [@key "Entrypoint"] [@default None]
  hostname : string option; [@key "Hostname"] [@default None]
  working_dir : string option; [@key "WorkingDir"] [@default None]
  labels : string_map option; [@key "Labels"] [@default None]
  exposed_ports : exposed_ports option; [@key "ExposedPorts"] [@default None]
  host_config : host_config option; [@key "HostConfig"] [@default None]
  networking_config : networking_config option;
      [@key "NetworkingConfig"] [@default None]
}
[@@deriving yojson]

let default_socket_path : string = "/var/run/docker.sock"
let default_api_version : string = "v1.53"

let create :
    ?socket_path:string ->
    ?api_version:string ->
    ?registry_auth:string ->
    unit ->
    t =
 fun ?(socket_path = default_socket_path) ?(api_version = default_api_version)
     ?registry_auth () ->
  { socket_path; api_version; registry_auth }

let uri_for : t -> string -> (string * string list) list -> Uri.t =
 fun t path query ->
  let full_path = "/" ^ t.api_version ^ path in
  Uri.make ~scheme:"httpunix" ~host:t.socket_path ~path:full_path ~query ()

let ensure_success :
    resp:Cohttp.Response.t -> body_str:string -> (unit, string) result =
 fun ~resp ~body_str ->
  let status = Cohttp.Response.status resp in
  let code = Cohttp.Code.code_of_status status in
  if code < 200 || (code >= 300 && code <> 304) then
    Error (Printf.sprintf "docker http %d: %s" code (String.trim body_str))
  else Ok ()

let ensure_success_or_allowed :
    allowed:int list ->
    resp:Cohttp.Response.t ->
    body_str:string ->
    (unit, string) result =
 fun ~allowed ~resp ~body_str ->
  let status = Cohttp.Response.status resp in
  let code = Cohttp.Code.code_of_status status in
  if (code >= 200 && code < 300) || List.mem code allowed then Ok ()
  else Error (Printf.sprintf "docker http %d: %s" code (String.trim body_str))

let read_body_string : Cohttp_eio.Body.t -> string =
 fun body -> Eio.Buf_read.(of_flow ~max_size:max_int body |> take_all)

let query_param : string -> string -> string * string list =
 fun key value -> (key, [ value ])

let with_client :
    net:_ Eio.Net.t -> (sw:Eio.Switch.t -> Cohttp_eio.Client.t -> 'a) -> 'a =
 fun ~net f ->
  let client = Cohttp_eio.Client.make ~https:None net in
  Eio.Switch.run (fun sw -> f ~sw client)

let call :
    ?headers:Cohttp.Header.t ->
    ?body:Cohttp_eio.Body.t ->
    t ->
    net:_ Eio.Net.t ->
    Cohttp.Code.meth ->
    string ->
    (string * string list) list ->
    (string, string) result =
 fun ?(headers = Cohttp.Header.init ()) ?body t ~net meth path query ->
  with_client ~net (fun ~sw client ->
      let uri = uri_for t path query in
      let response, body =
        Cohttp_eio.Client.call client ~sw ~headers ?body meth uri
      in
      let body_str = read_body_string body in
      let* () = ensure_success ~resp:response ~body_str in
      Ok body_str)

let call_allow_status :
    allowed:int list ->
    ?headers:Cohttp.Header.t ->
    ?body:Cohttp_eio.Body.t ->
    t ->
    net:_ Eio.Net.t ->
    Cohttp.Code.meth ->
    string ->
    (string * string list) list ->
    (string, string) result =
 fun ~allowed ?(headers = Cohttp.Header.init ()) ?body t ~net meth path query ->
  with_client ~net (fun ~sw client ->
      let uri = uri_for t path query in
      let response, body =
        Cohttp_eio.Client.call client ~sw ~headers ?body meth uri
      in
      let body_str = read_body_string body in
      let* () = ensure_success_or_allowed ~allowed ~resp:response ~body_str in
      Ok body_str)

let start_container :
    t -> net:_ Eio.Net.t -> container_id:string -> (unit, string) result =
 fun t ~net ~container_id ->
  let* _ =
    call_allow_status ~allowed:[ 304 ] t ~net `POST
      ("/containers/" ^ container_id ^ "/start")
      []
  in
  Ok ()

let call_json :
    ?headers:Cohttp.Header.t ->
    ?body:Cohttp_eio.Body.t ->
    t ->
    net:_ Eio.Net.t ->
    Cohttp.Code.meth ->
    string ->
    (string * string list) list ->
    (Yojson.Safe.t, string) result =
 fun ?headers ?body t ~net meth path query ->
  let* body_str = call ?headers ?body t ~net meth path query in
  Ok (Yojson.Safe.from_string body_str)

let json_body : Yojson.Safe.t -> Cohttp.Header.t * Cohttp_eio.Body.t =
 fun json ->
  let body_str = Yojson.Safe.to_string json in
  let headers = Cohttp.Header.init_with "Content-Type" "application/json" in
  (headers, Cohttp_eio.Body.of_string body_str)

let normalize_container_name : string -> string =
 fun name ->
  if String.length name > 0 && name.[0] = '/' then
    String.sub name 1 (String.length name - 1)
  else name

let container_of_json : Yojson.Safe.t -> (container, string) result =
 fun json ->
  container_of_yojson json
  |> Result.map_error (fun msg -> "failed to parse container: " ^ msg)

let list_containers :
    t -> net:_ Eio.Net.t -> ?all:bool -> unit -> (container list, string) result
    =
 fun t ~net ?(all = true) () ->
  let query = [ query_param "all" (if all then "true" else "false") ] in
  let* json = call_json t ~net `GET "/containers/json" query in
  match json with
  | `List values ->
      let rec parse_all acc = function
        | [] -> Ok (List.rev acc)
        | v :: rest -> (
            match container_of_json v with
            | Ok c -> parse_all (c :: acc) rest
            | Error _ as e -> e)
      in
      parse_all [] values
  | _ -> Error "expected JSON array from /containers/json"

let get_container_by_image_name :
    t ->
    net:_ Eio.Net.t ->
    image_name:string ->
    (container option, string) result =
 fun t ~net ~image_name ->
  let* containers = list_containers t ~net ~all:true () in
  Ok
    (List.find_opt
       (fun c ->
         let image = (c : container).image in
         Bondi_common.String_utils.contains ~needle:image_name image)
       containers)

let get_container_by_name :
    t ->
    net:_ Eio.Net.t ->
    container_name:string ->
    (container option, string) result =
 fun t ~net ~container_name ->
  let* containers = list_containers t ~net ~all:true () in
  Ok
    (List.find_opt
       (fun c ->
         List.exists
           (fun name -> normalize_container_name name = container_name)
           c.names)
       containers)

let get_container_by_id :
    t ->
    net:_ Eio.Net.t ->
    container_id:string ->
    (container option, string) result =
 fun t ~net ~container_id ->
  let* containers = list_containers t ~net ~all:false () in
  Ok (List.find_opt (fun c -> c.id = container_id) containers)

let create_network_if_not_exists :
    t -> net:_ Eio.Net.t -> network_name:string -> (unit, string) result =
 fun t ~net ~network_name ->
  let* json = call_json t ~net `GET "/networks" [] in
  let open Yojson.Safe.Util in
  let networks =
    json |> to_list |> List.map (fun n -> n |> member "Name" |> to_string)
  in
  if List.exists (fun name -> name = network_name) networks then Ok ()
  else
    let payload =
      `Assoc [ ("Name", `String network_name); ("Driver", `String "bridge") ]
    in
    let headers, body = json_body payload in
    let* _ = call ~headers ~body t ~net `POST "/networks/create" [] in
    Ok ()

let pull_image :
    t ->
    net:_ Eio.Net.t ->
    image:string ->
    tag:string ->
    registry_auth:string option ->
    (unit, string) result =
 fun t ~net ~image ~tag ~registry_auth ->
  let query = [ query_param "fromImage" image; query_param "tag" tag ] in
  let headers =
    match registry_auth with
    | None -> Cohttp.Header.init ()
    | Some auth -> Cohttp.Header.init_with "X-Registry-Auth" auth
  in
  let* _ =
    call_allow_status ~allowed:[ 304 ] ~headers t ~net `POST "/images/create"
      query
  in
  Ok ()

let pull_image_with_auth :
    t -> net:_ Eio.Net.t -> image:string -> tag:string -> (unit, string) result
    =
 fun t ~net ~image ~tag ->
  pull_image t ~net ~image ~tag ~registry_auth:t.registry_auth

let pull_image_no_auth :
    t -> net:_ Eio.Net.t -> image:string -> tag:string -> (unit, string) result
    =
 fun t ~net ~image ~tag -> pull_image t ~net ~image ~tag ~registry_auth:None

let remove_container :
    t -> net:_ Eio.Net.t -> container_id:string -> (unit, string) result =
 fun t ~net ~container_id ->
  let query = [ query_param "force" "true"; query_param "v" "true" ] in
  let* _ = call t ~net `DELETE ("/containers/" ^ container_id) query in
  Ok ()

let rename_container :
    t ->
    net:_ Eio.Net.t ->
    container_id:string ->
    new_name:string ->
    (unit, string) result =
 fun t ~net ~container_id ~new_name ->
  let query = [ query_param "name" new_name ] in
  let* _ =
    call t ~net `POST ("/containers/" ^ container_id ^ "/rename") query
  in
  Ok ()

let remove_container_and_image :
    t -> net:_ Eio.Net.t -> container:container -> (unit, string) result =
 fun t ~net ~container ->
  let* () = remove_container t ~net ~container_id:container.id in
  let image_query =
    [ query_param "force" "true"; query_param "noprune" "false" ]
  in
  let* _ = call t ~net `DELETE ("/images/" ^ container.image_id) image_query in
  Ok ()

let run_image_with_opts :
    t -> net:_ Eio.Net.t -> run_image_options -> (string, string) result =
 fun t ~net opts ->
  let payload =
    create_container_request_to_yojson
      {
        image = opts.config.image;
        env = opts.config.env;
        cmd = opts.config.cmd;
        entrypoint = opts.config.entrypoint;
        hostname = opts.config.hostname;
        working_dir = opts.config.working_dir;
        labels = opts.config.labels;
        exposed_ports = opts.config.exposed_ports;
        host_config = opts.host_config;
        networking_config = opts.networking_conf;
      }
  in
  let headers, body = json_body payload in
  let query =
    if opts.container_name = "" then []
    else [ query_param "name" opts.container_name ]
  in
  let* json =
    call_json ~headers ~body t ~net `POST "/containers/create" query
  in
  let open Yojson.Safe.Util in
  let container_id = json |> member "Id" |> to_string in
  let* () = start_container t ~net ~container_id in
  Ok container_id

let stop_container :
    t -> net:_ Eio.Net.t -> container_id:string -> (unit, string) result =
 fun t ~net ~container_id ->
  let query = [ query_param "t" "10" ] in
  let* _ = call t ~net `POST ("/containers/" ^ container_id ^ "/stop") query in
  Ok ()

let inspect_container :
    t ->
    net:_ Eio.Net.t ->
    container_id:string ->
    (inspect_response, string) result =
 fun t ~net ~container_id ->
  let* json =
    call_json t ~net `GET ("/containers/" ^ container_id ^ "/json") []
  in
  inspect_response_of_yojson json
  |> Result.map_error (fun msg ->
      Printf.sprintf "failed to parse inspect response for container %s: %s"
        container_id msg)

type wait_response = { status_code : int [@key "StatusCode"] }
[@@deriving yojson]

let wait_container :
    t -> net:_ Eio.Net.t -> container_id:string -> (int, string) result =
 fun t ~net ~container_id ->
  let* json =
    call_json t ~net `POST ("/containers/" ^ container_id ^ "/wait") []
  in
  let* resp =
    wait_response_of_yojson json
    |> Result.map_error (fun msg ->
        Printf.sprintf "failed to parse wait response for container %s: %s"
          container_id msg)
  in
  Ok resp.status_code

let inspect_image :
    t ->
    net:_ Eio.Net.t ->
    image:string ->
    (image_inspect_response, string) result =
 fun t ~net ~image ->
  let* json = call_json t ~net `GET ("/images/" ^ image ^ "/json") [] in
  image_inspect_response_of_yojson json
  |> Result.map_error (fun msg ->
      Printf.sprintf "failed to parse inspect response for image %s: %s" image
        msg)

let disconnect_from_network :
    t ->
    net:_ Eio.Net.t ->
    container_id:string ->
    network_name:string ->
    (unit, string) result =
 fun t ~net ~container_id ~network_name ->
  let payload =
    `Assoc [ ("Container", `String container_id); ("Force", `Bool true) ]
  in
  let headers, body = json_body payload in
  let* _ =
    call ~headers ~body t ~net `POST
      ("/networks/" ^ network_name ^ "/disconnect")
      []
  in
  Ok ()
