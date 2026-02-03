exception Docker_error of string

open Ppx_yojson_conv_lib.Yojson_conv

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
  state : string option; [@key "State"]
  status : string option; [@key "Status"]
}
[@@deriving yojson] [@@yojson.allow_extra_fields]

type inspect_state = { status : string [@key "Status"] }
[@@deriving yojson] [@@yojson.allow_extra_fields]

type inspect_response = {
  created_at : string; [@key "Created"]
  restart_count : int; [@key "RestartCount"]
  state : inspect_state; [@key "State"]
}
[@@deriving yojson] [@@yojson.allow_extra_fields]

type restart_policy = {
  name : string; [@key "Name"]
  maximum_retry_count : int option; [@key "MaximumRetryCount"] [@yojson.option]
}
[@@deriving yojson]

type empty_object = (string * string) list [@@deriving yojson]
type exposed_ports = (string * empty_object) list [@@deriving yojson]
type labels = (string * string) list [@@deriving yojson]

type port_binding = {
  host_ip : string option; [@key "HostIp"] [@yojson.option]
  host_port : string option; [@key "HostPort"] [@yojson.option]
}
[@@deriving yojson]

type port_bindings = (string * port_binding list) list [@@deriving yojson]

type endpoint_config = {
  aliases : string list option; [@key "Aliases"] [@yojson.option]
  ipv4_address : string option; [@key "IPv4Address"] [@yojson.option]
}
[@@deriving yojson]

type endpoints_config = (string * endpoint_config) list [@@deriving yojson]

type container_config = {
  image : string option; [@key "Image"] [@yojson.option]
  env : string list option; [@key "Env"] [@yojson.option]
  cmd : string list option; [@key "Cmd"] [@yojson.option]
  entrypoint : string list option; [@key "Entrypoint"] [@yojson.option]
  exposed_ports : exposed_ports option; [@key "ExposedPorts"] [@yojson.option]
  hostname : string option; [@key "Hostname"] [@yojson.option]
  working_dir : string option; [@key "WorkingDir"] [@yojson.option]
  labels : labels option; [@key "Labels"] [@yojson.option]
}
[@@deriving yojson]

type host_config = {
  binds : string list option; [@key "Binds"] [@yojson.option]
  port_bindings : port_bindings option; [@key "PortBindings"] [@yojson.option]
  network_mode : string option; [@key "NetworkMode"] [@yojson.option]
  restart_policy : restart_policy option; [@key "RestartPolicy"] [@yojson.option]
}
[@@deriving yojson]

type networking_config = {
  endpoints_config : endpoints_config option;
      [@key "EndpointsConfig"] [@yojson.option]
}
[@@deriving yojson]

type run_image_options = {
  container_name : string;
  config : container_config;
  host_config : host_config option;
  networking_conf : networking_config option;
}

type create_container_request = {
  image : string option; [@key "Image"] [@yojson.option]
  env : string list option; [@key "Env"] [@yojson.option]
  cmd : string list option; [@key "Cmd"] [@yojson.option]
  entrypoint : string list option; [@key "Entrypoint"] [@yojson.option]
  exposed_ports : exposed_ports option; [@key "ExposedPorts"] [@yojson.option]
  hostname : string option; [@key "Hostname"] [@yojson.option]
  working_dir : string option; [@key "WorkingDir"] [@yojson.option]
  labels : labels option; [@key "Labels"] [@yojson.option]
  host_config : host_config option; [@key "HostConfig"] [@yojson.option]
  networking_config : networking_config option;
      [@key "NetworkingConfig"] [@yojson.option]
}
[@@deriving yojson]

let default_socket_path : string = "/var/run/docker.sock"
let default_api_version : string = "v1.41"

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

let ensure_success : resp:Cohttp.Response.t -> body_str:string -> unit =
 fun ~resp ~body_str ->
  let status = Cohttp.Response.status resp in
  let code = Cohttp.Code.code_of_status status in
  if code < 200 || code >= 300 then
    let msg = Printf.sprintf "docker http %d: %s" code (String.trim body_str) in
    raise (Docker_error msg)

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
    string =
 fun ?(headers = Cohttp.Header.init ()) ?body t ~net meth path query ->
  with_client ~net (fun ~sw client ->
      let uri = uri_for t path query in
      let response, body =
        Cohttp_eio.Client.call client ~sw ~headers ?body meth uri
      in
      let body_str = read_body_string body in
      ensure_success ~resp:response ~body_str;
      body_str)

let call_json :
    ?headers:Cohttp.Header.t ->
    ?body:Cohttp_eio.Body.t ->
    t ->
    net:_ Eio.Net.t ->
    Cohttp.Code.meth ->
    string ->
    (string * string list) list ->
    Yojson.Safe.t =
 fun ?headers ?body t ~net meth path query ->
  let body_str = call ?headers ?body t ~net meth path query in
  Yojson.Safe.from_string body_str

let json_body : Yojson.Safe.t -> Cohttp.Header.t * Cohttp_eio.Body.t =
 fun json ->
  let body_str = Yojson.Safe.to_string json in
  let headers = Cohttp.Header.init_with "Content-Type" "application/json" in
  (headers, Cohttp_eio.Body.of_string body_str)

let string_contains : substring:string -> string -> bool =
 fun ~substring str ->
  let sub_len = String.length substring in
  let str_len = String.length str in
  if sub_len = 0 then true
  else if sub_len > str_len then false
  else
    let rec loop idx =
      if idx + sub_len > str_len then false
      else if String.sub str idx sub_len = substring then true
      else loop (idx + 1)
    in
    loop 0

let normalize_container_name : string -> string =
 fun name ->
  if String.length name > 0 && name.[0] = '/' then
    String.sub name 1 (String.length name - 1)
  else name

let container_of_json : Yojson.Safe.t -> container =
 fun json -> container_of_yojson json

let list_containers :
    t -> net:_ Eio.Net.t -> ?all:bool -> unit -> container list =
 fun t ~net ?(all = true) () ->
  let query = [ query_param "all" (if all then "true" else "false") ] in
  let json = call_json t ~net `GET "/containers/json" query in
  match json with
  | `List values -> List.map container_of_json values
  | _ -> raise (Docker_error "invalid containers list json")

let get_container_by_image_name :
    t -> net:_ Eio.Net.t -> image_name:string -> container option =
 fun t ~net ~image_name ->
  let containers = list_containers t ~net ~all:true () in
  List.find_opt
    (fun c ->
      let image = (c : container).image in
      string_contains ~substring:image_name image)
    containers

let get_container_by_name :
    t -> net:_ Eio.Net.t -> container_name:string -> container option =
 fun t ~net ~container_name ->
  let containers = list_containers t ~net ~all:true () in
  List.find_opt
    (fun c ->
      List.exists
        (fun name -> normalize_container_name name = container_name)
        c.names)
    containers

let get_container_by_id :
    t -> net:_ Eio.Net.t -> container_id:string -> container option =
 fun t ~net ~container_id ->
  let containers = list_containers t ~net ~all:false () in
  List.find_opt (fun c -> c.id = container_id) containers

let create_network_if_not_exists :
    t -> net:_ Eio.Net.t -> network_name:string -> unit =
 fun t ~net ~network_name ->
  let json = call_json t ~net `GET "/networks" [] in
  let open Yojson.Safe.Util in
  let networks =
    json |> to_list |> List.map (fun n -> n |> member "Name" |> to_string)
  in
  if List.exists (fun name -> name = network_name) networks then ()
  else
    let payload =
      `Assoc [ ("Name", `String network_name); ("Driver", `String "bridge") ]
    in
    let headers, body = json_body payload in
    let _ = call ~headers ~body t ~net `POST "/networks/create" [] in
    ()

let pull_image :
    t ->
    net:_ Eio.Net.t ->
    image:string ->
    tag:string ->
    registry_auth:string option ->
    unit =
 fun t ~net ~image ~tag ~registry_auth ->
  let query = [ query_param "fromImage" image; query_param "tag" tag ] in
  let headers =
    match registry_auth with
    | None -> Cohttp.Header.init ()
    | Some auth -> Cohttp.Header.init_with "X-Registry-Auth" auth
  in
  let _ = call ~headers t ~net `POST "/images/create" query in
  ()

let pull_image_with_auth :
    t -> net:_ Eio.Net.t -> image:string -> tag:string -> unit =
 fun t ~net ~image ~tag ->
  pull_image t ~net ~image ~tag ~registry_auth:t.registry_auth

let pull_image_no_auth :
    t -> net:_ Eio.Net.t -> image:string -> tag:string -> unit =
 fun t ~net ~image ~tag -> pull_image t ~net ~image ~tag ~registry_auth:None

let remove_container_and_image :
    t -> net:_ Eio.Net.t -> container:container -> unit =
 fun t ~net ~container ->
  let query = [ query_param "force" "true"; query_param "v" "true" ] in
  let _ = call t ~net `DELETE ("/containers/" ^ container.id) query in
  let image_query =
    [ query_param "force" "true"; query_param "noprune" "false" ]
  in
  let _ = call t ~net `DELETE ("/images/" ^ container.image_id) image_query in
  ()

let run_image_with_opts : t -> net:_ Eio.Net.t -> run_image_options -> string =
 fun t ~net opts ->
  let payload =
    yojson_of_create_container_request
      {
        image = opts.config.image;
        env = opts.config.env;
        cmd = opts.config.cmd;
        entrypoint = opts.config.entrypoint;
        exposed_ports = opts.config.exposed_ports;
        hostname = opts.config.hostname;
        working_dir = opts.config.working_dir;
        labels = opts.config.labels;
        host_config = opts.host_config;
        networking_config = opts.networking_conf;
      }
  in
  let headers, body = json_body payload in
  let query =
    if opts.container_name = "" then []
    else [ query_param "name" opts.container_name ]
  in
  let json = call_json ~headers ~body t ~net `POST "/containers/create" query in
  let open Yojson.Safe.Util in
  json |> member "Id" |> to_string

let stop_container : t -> net:_ Eio.Net.t -> container_id:string -> unit =
 fun t ~net ~container_id ->
  let query = [ query_param "t" "10" ] in
  let _ = call t ~net `POST ("/containers/" ^ container_id ^ "/stop") query in
  ()

let inspect_container :
    t -> net:_ Eio.Net.t -> container_id:string -> inspect_response =
 fun t ~net ~container_id ->
  let json =
    call_json t ~net `GET ("/containers/" ^ container_id ^ "/json") []
  in
  inspect_response_of_yojson json
