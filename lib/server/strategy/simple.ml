open Ppx_yojson_conv_lib.Yojson_conv
open Json_helpers

let ( let* ) = Result.bind
let default_network_name = "bondi-network"
let service_name = "bondi-service"
let traefik_name = "bondi-traefik"

type deploy_input = {
  image_name : string;
  tag : string;
  port : int;
  registry_user : string option;
  registry_pass : string option;
  env_vars : string_map option;
  traefik_domain_name : string option;
  traefik_image : string option;
  traefik_acme_email : string option;
}
[@@deriving yojson]

let default_networking_config : Docker.Client.networking_config =
  let endpoint : Docker.Client.endpoint_config =
    { aliases = None; ipv4_address = None }
  in
  { endpoints_config = Some [ (default_network_name, endpoint) ] }

let env_vars_to_list env_vars =
  List.map (fun (key, value) -> key ^ "=" ^ value) env_vars

let parse_image_and_tag image =
  match String.split_on_char ':' image with
  | [ name; tag ] -> Ok (name, tag)
  | [ name ] -> Ok (name, "")
  | _ -> Error ("invalid image format: " ^ image)

let service_config (input : deploy_input) :
    (Docker.Client.container_config, string) result =
  match input.traefik_domain_name with
  | None -> Error "missing traefik_domain_name for service labels"
  | Some domain_name ->
      let new_image = Printf.sprintf "%s:%s" input.image_name input.tag in
      let labels : string_map =
        [
          ("traefik.enable", "true");
          ( "traefik.http.routers.bondi.rule",
            Printf.sprintf "Host(`%s`) || Host(`www.%s`)" domain_name
              domain_name );
          ("traefik.http.routers.bondi.entrypoints", "websecure");
          ("traefik.http.routers.bondi.tls", "true");
          ("traefik.http.routers.bondi.tls.certresolver", "bondi_resolver");
        ]
      in
      let env = Option.map env_vars_to_list input.env_vars in
      let config : Docker.Client.container_config =
        {
          image = Some new_image;
          env;
          cmd = None;
          entrypoint = None;
          hostname = None;
          working_dir = None;
          labels = Some labels;
        }
      in
      Ok config

let run_traefik ~client ~net (input : deploy_input) : (string, string) result =
  let current_traefik =
    Docker.Client.get_container_by_image_name client ~net ~image_name:"traefik"
  in
  let* requested_image =
    match input.traefik_image with
    | Some image -> Ok image
    | None -> Error "missing traefik_image"
  in
  let* requested_version =
    match parse_image_and_tag requested_image with
    | Ok (_requested_name, tag) -> Ok tag
    | Error msg -> Error msg
  in
  let* existing_id =
    match current_traefik with
    | Some container ->
        let current_version =
          match parse_image_and_tag container.image with
          | Ok (_name, tag) -> tag
          | Error _ -> ""
        in
        if current_version = requested_version then Ok (Some container.id)
        else (
          Docker.Client.stop_container client ~net ~container_id:container.id;
          Docker.Client.remove_container_and_image client ~net ~container;
          Ok None)
    | None -> Ok None
  in
  match existing_id with
  | Some id -> Ok id
  | None -> (
      match (input.traefik_domain_name, input.traefik_acme_email) with
      | Some domain_name, Some acme_email -> (
          match parse_image_and_tag requested_image with
          | Error msg -> Error msg
          | Ok (image_name, image_tag) ->
              Docker.Client.pull_image_no_auth client ~net ~image:image_name
                ~tag:image_tag;
              let traefik_config : Docker.Traefik.config =
                {
                  network_name = default_network_name;
                  domain_name;
                  traefik_image = Some requested_image;
                  acme_email;
                }
              in
              let docker_config =
                Docker.Traefik.get_docker_config traefik_config
              in
              let opts : Docker.Client.run_image_options =
                {
                  container_name = traefik_name;
                  config = docker_config.container_config;
                  host_config = Some docker_config.host_config;
                  networking_conf = Some default_networking_config;
                }
              in
              let container_id =
                Docker.Client.run_image_with_opts client ~net opts
              in
              Ok container_id)
      | _ -> Error "missing required traefik configuration")

let wait_for_traefik ~clock ~client ~net ~container_id : (unit, string) result =
  let max_retries = 30 in
  let rec loop attempt last_state =
    if attempt >= max_retries then
      Error
        (Printf.sprintf "timeout waiting for Traefik to start, last state: %s"
           last_state)
    else
      let state =
        try
          let inspect =
            Docker.Client.inspect_container client ~net ~container_id
          in
          Ok inspect.state.status
        with
        | exn -> Error (Printexc.to_string exn)
      in
      match state with
      | Ok "running" -> Ok ()
      | Ok "created" ->
          Docker.Client.start_container client ~net ~container_id;
          Eio.Time.sleep clock 1.0;
          loop (attempt + 1) "created"
      | Ok "exited" ->
          Docker.Client.start_container client ~net ~container_id;
          Eio.Time.sleep clock 1.0;
          loop (attempt + 1) "exited"
      | Ok status ->
          Eio.Time.sleep clock 1.0;
          loop (attempt + 1) status
      | Error msg -> Error msg
  in
  loop 0 ""

let deploy ~clock ~client ~net (input : deploy_input) : (unit, string) result =
  let should_run_traefik =
    Option.is_some input.traefik_domain_name
    && Option.is_some input.traefik_image
    && Option.is_some input.traefik_acme_email
  in
  let* () =
    if should_run_traefik then (
      Docker.Client.create_network_if_not_exists client ~net
        ~network_name:default_network_name;
      let* traefik_container_id = run_traefik ~client ~net input in
      let* () =
        wait_for_traefik ~clock ~client ~net ~container_id:traefik_container_id
      in
      Ok ())
    else Ok ()
  in
  let current_container =
    Docker.Client.get_container_by_image_name client ~net
      ~image_name:input.image_name
  in
  let* () =
    match current_container with
    | None -> Ok ()
    | Some container ->
        Docker.Client.stop_container client ~net ~container_id:container.id;
        Docker.Client.remove_container_and_image client ~net ~container;
        Ok ()
  in
  Docker.Client.pull_image_with_auth client ~net ~image:input.image_name
    ~tag:input.tag;
  let* config = service_config input in
  let opts : Docker.Client.run_image_options =
    {
      container_name = service_name;
      config;
      host_config = None;
      networking_conf = Some default_networking_config;
    }
  in
  let _ = Docker.Client.run_image_with_opts client ~net opts in
  Ok ()
