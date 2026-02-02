exception Docker_error of string

type t = {
  socket_path : string;
  api_version : string;
  registry_auth : string option;
}

type container = {
  id : string;
  image : string;
  image_id : string;
  names : string list;
  state : string option;
  status : string option;
}

type run_image_options = {
  container_name : string;
  config : Yojson.Safe.t;
  host_config : Yojson.Safe.t option;
  networking_conf : Yojson.Safe.t option;
}

let default_socket_path = "/var/run/docker.sock"
let default_api_version = "v1.41"

let create ?(socket_path = default_socket_path)
    ?(api_version = default_api_version) ?registry_auth () =
  { socket_path; api_version; registry_auth }

let uri_for t path query =
  let full_path = "/" ^ t.api_version ^ path in
  Uri.make ~scheme:"httpunix" ~host:t.socket_path ~path:full_path ~query ()

let ensure_success ~resp ~body_str =
  let status = Cohttp.Response.status resp in
  let code = Cohttp.Code.code_of_status status in
  if code < 200 || code >= 300 then
    let msg = Printf.sprintf "docker http %d: %s" code (String.trim body_str) in
    raise (Docker_error msg)

let read_body_string body =
  Eio.Buf_read.(of_flow ~max_size:max_int body |> take_all)

let query_param key value = (key, [ value ])

let with_client ~net f =
  let client = Cohttp_eio.Client.make ~https:None net in
  Eio.Switch.run (fun sw -> f ~sw client)

let call ?(headers = Cohttp.Header.init ()) ?body t ~net meth path query =
  with_client ~net (fun ~sw client ->
      let uri = uri_for t path query in
      let response, body =
        Cohttp_eio.Client.call client ~sw ~headers ?body meth uri
      in
      let body_str = read_body_string body in
      ensure_success ~resp:response ~body_str;
      body_str)

let call_json ?headers ?body t ~net meth path query =
  let body_str = call ?headers ?body t ~net meth path query in
  Yojson.Safe.from_string body_str

let json_body json =
  let body_str = Yojson.Safe.to_string json in
  let headers = Cohttp.Header.init_with "Content-Type" "application/json" in
  (headers, Cohttp_eio.Body.of_string body_str)

let string_contains ~substring str =
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

let normalize_container_name name =
  if String.length name > 0 && name.[0] = '/' then
    String.sub name 1 (String.length name - 1)
  else name

let container_of_json json =
  let open Yojson.Safe.Util in
  {
    id = json |> member "Id" |> to_string;
    image = json |> member "Image" |> to_string;
    image_id = json |> member "ImageID" |> to_string;
    names = json |> member "Names" |> to_list |> List.map to_string;
    state = json |> member "State" |> to_string_option;
    status = json |> member "Status" |> to_string_option;
  }

let list_containers t ~net ?(all = true) () =
  let query = [ query_param "all" (if all then "true" else "false") ] in
  let json = call_json t ~net `GET "/containers/json" query in
  let open Yojson.Safe.Util in
  json |> to_list |> List.map container_of_json

let get_container_by_image_name t ~net ~image_name =
  let containers = list_containers t ~net ~all:true () in
  List.find_opt
    (fun c -> string_contains ~substring:image_name c.image)
    containers

let get_container_by_name t ~net ~container_name =
  let containers = list_containers t ~net ~all:true () in
  List.find_opt
    (fun c ->
      List.exists
        (fun name -> normalize_container_name name = container_name)
        c.names)
    containers

let get_container_by_id t ~net ~container_id =
  let containers = list_containers t ~net ~all:false () in
  List.find_opt (fun c -> c.id = container_id) containers

let create_network_if_not_exists t ~net ~network_name =
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

let pull_image t ~net ~image ~tag ~registry_auth =
  let query = [ query_param "fromImage" image; query_param "tag" tag ] in
  let headers =
    match registry_auth with
    | None -> Cohttp.Header.init ()
    | Some auth -> Cohttp.Header.init_with "X-Registry-Auth" auth
  in
  let _ = call ~headers t ~net `POST "/images/create" query in
  ()

let pull_image_with_auth t ~net ~image ~tag =
  pull_image t ~net ~image ~tag ~registry_auth:t.registry_auth

let pull_image_no_auth t ~net ~image ~tag =
  pull_image t ~net ~image ~tag ~registry_auth:None

let remove_container_and_image t ~net ~container =
  let query = [ query_param "force" "true"; query_param "v" "true" ] in
  let _ = call t ~net `DELETE ("/containers/" ^ container.id) query in
  let image_query =
    [ query_param "force" "true"; query_param "noprune" "false" ]
  in
  let _ = call t ~net `DELETE ("/images/" ^ container.image_id) image_query in
  ()

let run_image_with_opts t ~net opts =
  let payload =
    match opts.config with
    | `Assoc fields ->
        `Assoc
          (fields
          @
          match opts.host_config with
          | None -> []
          | Some host_config -> (
              [ ("HostConfig", host_config) ]
              @
              match opts.networking_conf with
              | None -> []
              | Some net_conf -> [ ("NetworkingConfig", net_conf) ]))
    | _ -> raise (Docker_error "container config must be a JSON object")
  in
  let headers, body = json_body payload in
  let query =
    if opts.container_name = "" then []
    else [ query_param "name" opts.container_name ]
  in
  let json = call_json ~headers ~body t ~net `POST "/containers/create" query in
  let open Yojson.Safe.Util in
  json |> member "Id" |> to_string

let stop_container t ~net ~container_id =
  let query = [ query_param "t" "10" ] in
  let _ = call t ~net `POST ("/containers/" ^ container_id ^ "/stop") query in
  ()

let inspect_container t ~net ~container_id =
  call_json t ~net `GET ("/containers/" ^ container_id ^ "/json") []
