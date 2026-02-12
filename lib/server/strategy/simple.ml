open Ppx_yojson_conv_lib.Yojson_conv
open Json_helpers

let ( let* ) = Result.bind
let default_network_name = "bondi-network"
let service_name = "bondi-workload"
let traefik_name = "bondi-traefik"

(* ------------------------------------------------------------------------- *)
(* Types                                                                     *)
(* ------------------------------------------------------------------------- *)

type cron_job = {
  name : string;
  image : string;
  schedule : string;
  env_vars : string_map option;
  registry_user : string option; [@default None]
  registry_pass : string option; [@default None]
}
[@@deriving yojson]

type deploy_input = {
  image : string; (* Full image string including tag *)
  port : int;
  registry_user : string option;
  registry_pass : string option;
  env_vars : string_map option;
  traefik_domain_name : string option;
  traefik_image : string option;
  traefik_acme_email : string option;
  force_traefik_redeploy : bool option;
  cron_jobs : cron_job list option; [@default None]
}
[@@deriving yojson]

type deploy_context = {
  current_traefik : Docker.Client.container option;
  current_workload : Docker.Client.container option;
}

type action =
  | CreateNetwork of { network_name : string }
  | EnsureTraefik of {
      image : string;
      domain_name : string;
      acme_email : string;
      traefik_config : Docker.Traefik.docker_config;
    }
  | StopAndRemoveContainer of Docker.Client.container
  | PullImage of { image : string; tag : string; with_auth : bool }
  | RunWorkload of {
      container_name : string;
      config : Docker.Client.container_config;
      networking_conf : Docker.Client.networking_config;
    }

(* ------------------------------------------------------------------------- *)
(* Pure helpers                                                              *)
(* ------------------------------------------------------------------------- *)

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
      let new_image =
        match parse_image_and_tag input.image with
        | Ok (name, tag) -> if tag = "" then name ^ ":latest" else input.image
        | Error _ -> input.image
      in
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
          exposed_ports = None;
        }
      in
      Ok config

(* ------------------------------------------------------------------------- *)
(* Phase 1: Gather context (read-only)                                       *)
(* ------------------------------------------------------------------------- *)

let image_name_for_lookup image =
  match parse_image_and_tag image with
  | Ok (name, _) -> name
  | Error _ -> image

let gather_context ~client ~net (input : deploy_input) :
    (deploy_context, string) result =
  try
    let current_traefik =
      Docker.Client.get_container_by_image_name client ~net
        ~image_name:"traefik"
    in
    let current_workload =
      Docker.Client.get_container_by_image_name client ~net
        ~image_name:(image_name_for_lookup input.image)
    in
    Ok { current_traefik; current_workload }
  with
  | exn -> Error (Printexc.to_string exn)

(* ------------------------------------------------------------------------- *)
(* Phase 2: Plan (pure)                                                     *)
(* ------------------------------------------------------------------------- *)

let should_run_traefik (input : deploy_input) =
  Option.is_some input.traefik_domain_name
  && Option.is_some input.traefik_image
  && Option.is_some input.traefik_acme_email

let should_redeploy_traefik (input : deploy_input)
    (current_traefik : Docker.Client.container) : bool =
  let force_redeploy =
    Option.value ~default:false input.force_traefik_redeploy
  in
  if force_redeploy then true
  else
    match (input.traefik_image, parse_image_and_tag current_traefik.image) with
    | None, _ -> false
    | Some requested_image, Ok (_name, current_tag) -> (
        match parse_image_and_tag requested_image with
        | Error _ -> false
        | Ok (_requested_name, requested_tag) -> current_tag <> requested_tag)
    | _ -> false

let plan (input : deploy_input) (context : deploy_context) :
    (action list, string) result =
  let actions = ref [] in
  (* Traefik path *)
  let* () =
    if should_run_traefik input then (
      actions :=
        CreateNetwork { network_name = default_network_name } :: !actions;
      let need_traefik_deploy =
        match context.current_traefik with
        | None -> true
        | Some container ->
            if should_redeploy_traefik input container then (
              actions := StopAndRemoveContainer container :: !actions;
              true)
            else false
      in
      if need_traefik_deploy then
        match
          ( input.traefik_image,
            input.traefik_domain_name,
            input.traefik_acme_email )
        with
        | Some image, Some domain_name, Some acme_email -> (
            match parse_image_and_tag image with
            | Error msg -> Error msg
            | Ok (image_name, _image_tag) ->
                let traefik_config : Docker.Traefik.config =
                  {
                    network_name = default_network_name;
                    domain_name;
                    traefik_image = Some image;
                    acme_email;
                  }
                in
                let docker_config =
                  Docker.Traefik.get_docker_config traefik_config
                in
                actions :=
                  EnsureTraefik
                    {
                      image = image_name;
                      domain_name;
                      acme_email;
                      traefik_config = docker_config;
                    }
                  :: !actions;
                Ok ())
        | _ -> Error "missing required traefik configuration"
      else Ok ())
    else Ok ()
  in
  (* Workload path - only when we have a service (traefik_domain_name) *)
  (match input.traefik_domain_name with
  | None -> ()
  | Some _ -> (
      match service_config input with
      | Error _ -> ()
      | Ok service_cfg ->
          (match context.current_workload with
          | None -> ()
          | Some container ->
              actions := StopAndRemoveContainer container :: !actions);
          (match parse_image_and_tag input.image with
          | Ok (image_name, image_tag) ->
              actions :=
                PullImage
                  {
                    image = image_name;
                    tag = (if image_tag = "" then "latest" else image_tag);
                    with_auth = Option.is_some input.registry_user;
                  }
                :: !actions
          | Error _ -> ());
          actions :=
            RunWorkload
              {
                container_name = service_name;
                config = service_cfg;
                networking_conf = default_networking_config;
              }
            :: !actions));
  Ok (List.rev !actions)

(* ------------------------------------------------------------------------- *)
(* Phase 3: Interpreter                                                     *)
(* ------------------------------------------------------------------------- *)

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

let interpret ~clock ~client ~net (actions : action list) :
    (unit, string) result =
  let rec run = function
    | [] -> Ok ()
    | CreateNetwork { network_name } :: rest ->
        Docker.Client.create_network_if_not_exists client ~net ~network_name;
        run rest
    | EnsureTraefik { image; traefik_config; domain_name = _; acme_email = _ }
      :: rest ->
        let full_image =
          match traefik_config.container_config.image with
          | Some img -> img
          | None -> image
        in
        let image_name, image_tag =
          match parse_image_and_tag full_image with
          | Ok (n, t) -> (n, t)
          | Error _ -> (image, "")
        in
        Docker.Client.pull_image_no_auth client ~net ~image:image_name
          ~tag:image_tag;
        let opts : Docker.Client.run_image_options =
          {
            container_name = traefik_name;
            config = traefik_config.container_config;
            host_config = Some traefik_config.host_config;
            networking_conf = Some default_networking_config;
          }
        in
        let container_id = Docker.Client.run_image_with_opts client ~net opts in
        let* () = wait_for_traefik ~clock ~client ~net ~container_id in
        run rest
    | StopAndRemoveContainer container :: rest ->
        Docker.Client.stop_container client ~net ~container_id:container.id;
        Docker.Client.remove_container_and_image client ~net ~container;
        run rest
    | PullImage { image; tag; with_auth } :: rest ->
        if with_auth then
          Docker.Client.pull_image_with_auth client ~net ~image ~tag
        else Docker.Client.pull_image_no_auth client ~net ~image ~tag;
        run rest
    | RunWorkload { container_name; config; networking_conf } :: rest ->
        let opts : Docker.Client.run_image_options =
          {
            container_name;
            config;
            host_config = None;
            networking_conf = Some networking_conf;
          }
        in
        let _ = Docker.Client.run_image_with_opts client ~net opts in
        run rest
  in
  run actions

(* ------------------------------------------------------------------------- *)
(* Entry point                                                               *)
(* ------------------------------------------------------------------------- *)

let deploy ~clock ~client ~net (input : deploy_input) : (unit, string) result =
  let* context = gather_context ~client ~net input in
  let* actions = plan input context in
  interpret ~clock ~client ~net actions
