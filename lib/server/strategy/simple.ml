open Json_helpers
module Alert = Bondi_common.Alert
module Image_reference = Bondi_common.Image_reference

let ( let* ) = Result.bind

(* [exit_code_severities] wraps [Alert.severity_map] only to map its
   [severity_map_error] to the string error [ppx_deriving_yojson] requires;
   [Alert.sinks] already reports a string error and is used directly. *)
type exit_code_severities = Alert.severity_map

let exit_code_severities_of_yojson json =
  Alert.severity_map_of_yojson json
  |> Result.map_error Alert.severity_map_error_to_string

let exit_code_severities_to_yojson = Alert.severity_map_to_yojson

(* The mounts a deploy declares, read by the same [Bind_mount] codec the client
   encodes them with, so a mount the client sends is one this end accepts.

   Only the reason for a refusal differs. The codec's reason quotes the
   rejected path or entry, and this reason becomes the refusal's message, which
   never carries a value from the payload (see [Handler_error.message]). So the
   field is named and the rule restated, and what the payload held is not. *)
type volumes = Bondi_common.Bind_mount.t list

(** Reads the [volumes] field; the refusal names the field and restates the rule
    without echoing the payload. *)
let volumes_of_yojson json =
  Bondi_common.Bind_mount.list_of_yojson json
  |> Result.map_error (fun (_ : string) ->
      "volumes: an entry is not a well-formed bind mount. Each entry is an \
       object of exactly host, container and read_only, with both paths \
       absolute and normalised, and no container path that is / or is declared \
       twice")

(** Writes the [volumes] field. *)
let volumes_to_yojson = Bondi_common.Bind_mount.list_to_yojson

(* The payload fields read by a common module's codec, with a refusal that
   names the field and states the grammar. They live in [Payload_codec], which
   [Run] shares. Each field has its own type only so that its refusal can name
   it. *)
type service_image = Image_reference.t

let service_image_of_yojson = Payload_codec.service_image_of_yojson
let service_image_to_yojson = Image_reference.to_yojson

type traefik_image = Image_reference.t

let traefik_image_of_yojson = Payload_codec.traefik_image_of_yojson
let traefik_image_to_yojson = Image_reference.to_yojson

type cron_image = Image_reference.t

let cron_image_of_yojson = Payload_codec.cron_image_of_yojson
let cron_image_to_yojson = Image_reference.to_yojson

type traefik_acme_ca_server = Bondi_common.Acme_ca_server.t

let traefik_acme_ca_server_of_yojson =
  Payload_codec.traefik_acme_ca_server_of_yojson

let traefik_acme_ca_server_to_yojson = Bondi_common.Acme_ca_server.to_yojson

type service_name = Bondi_common.Router_name.t

let service_name_of_yojson = Payload_codec.service_name_of_yojson
let service_name_to_yojson = Bondi_common.Router_name.to_yojson

(* ------------------------------------------------------------------------- *)
(* Types                                                                     *)
(* ------------------------------------------------------------------------- *)

type cron_job = {
  name : string;
  image : cron_image;
  schedule : string;
  network : string option; [@default None]
  env_vars : string_map option; [@default None]
  secret_env_vars : string_map option; [@default None]
  registry_user : string option; [@default None]
  registry_pass : string option; [@default None]
  alert_sinks : Alert.sinks option; [@default None]
  exit_code_severities : exit_code_severities option; [@default None]
}
[@@deriving yojson]

type deploy_input = {
  service_name : service_name option; [@default None]
  image : service_image option; [@default None]
  port : int option; [@default None]
  registry_user : string option; [@default None]
  registry_pass : string option; [@default None]
  env_vars : string_map option; [@default None]
  traefik_domain_name : string option; [@default None]
  traefik_image : traefik_image option; [@default None]
  traefik_acme_email : string option; [@default None]
  traefik_acme_ca_server : traefik_acme_ca_server option; [@default None]
  force_traefik_redeploy : bool option; [@default None]
  cron_jobs : cron_job list option; [@default None]
  drain_grace_period : float option; [@default None]
  deployment_strategy : string option; [@default None]
  health_timeout : float option; [@default None]
  poll_interval : float option; [@default None]
  logs : bool option; [@default None]
  volumes : volumes option; [@default None]
}
[@@deriving yojson]

type deploy_context = {
  current_traefik : Docker.Client.container option;
  current_workload : Docker.Client.container option;
}

type action =
  | CreateNetwork of { network_name : string }
  | EnsureTraefik of {
      domain_name : string;
      acme_email : string;
      traefik_config : Docker.Traefik.docker_config;
    }
  | StopAndRemoveContainer of Docker.Client.container
  | PullImage of { image : Image_reference.t; with_auth : bool }
  | RunWorkload of {
      container_name : string;
      config : Docker.Client.container_config;
      host_config : Docker.Client.host_config;
      networking_conf : Docker.Client.networking_config;
    }

(* ------------------------------------------------------------------------- *)
(* Pure helpers                                                              *)
(* ------------------------------------------------------------------------- *)

let default_networking_config : Docker.Client.networking_config =
  let endpoint : Docker.Client.endpoint_config =
    { aliases = None; ipv4_address = None }
  in
  { endpoints_config = Some [ (Bondi_common.Defaults.network_name, endpoint) ] }

let env_vars_to_list env_vars =
  List.map (fun (key, value) -> key ^ "=" ^ value) env_vars

(** The reference the service container's image is tagged with: an image with
    neither a tag nor a digest runs as [name:latest], and any other is kept as
    written. *)
let service_image_reference image =
  match (Image_reference.tag image, Image_reference.digest image) with
  | None, None -> Image_reference.name image ^ ":latest"
  | Some _, _
  | None, Some _ ->
      Image_reference.to_string image

(** The service's name, as checked, with the container config built for it. The
    name comes back with the config so that a caller needing both holds one that
    cannot be missing. *)
let service_config (input : deploy_input) :
    (service_name * Docker.Client.container_config, string) result =
  match input.image with
  | None -> Error "image is required when deploying a service (got null)"
  | Some image -> (
      match input.port with
      | None -> Error "port is required when deploying a service (got null)"
      | Some port -> (
          match input.traefik_domain_name with
          | None -> Error "missing traefik_domain_name for service labels"
          | Some domain_name -> (
              match input.service_name with
              | None -> Error "service_name required when deploying a service"
              | Some name ->
                  let new_image = service_image_reference image in
                  (* The service name, not the container name: blue-green
                     starts the incoming colour under a temporary name. The
                     router and its load-balancer service are named after it
                     too, so two services behind one Traefik are two routers
                     feeding two load balancers. The name was checked to be a
                     router name at decode. *)
                  let name_string = Bondi_common.Router_name.to_string name in
                  let router = "traefik.http.routers." ^ name_string in
                  let labels : string_map =
                    [
                      ("bondi.managed", "true");
                      ("bondi.type", "service");
                      ( "bondi.logs",
                        string_of_bool (Option.value ~default:true input.logs)
                      );
                      ("traefik.enable", "true");
                      ( router ^ ".rule",
                        Printf.sprintf "Host(`%s`) || Host(`www.%s`)"
                          domain_name domain_name );
                      (router ^ ".entrypoints", "websecure");
                      (router ^ ".tls", "true");
                      (router ^ ".tls.certresolver", "bondi_resolver");
                      ( "traefik.http.services." ^ name_string
                        ^ ".loadbalancer.server.port",
                        string_of_int port );
                      ("bondi.name", name_string);
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
                  Ok (name, config))))

(* ------------------------------------------------------------------------- *)
(* Phase 1: Gather context (read-only)                                       *)
(* ------------------------------------------------------------------------- *)

let gather_context ~client ~net (input : deploy_input) :
    (deploy_context, string) result =
  let* current_traefik =
    Docker.Client.get_container_by_image_name client ~net ~image_name:"traefik"
  in
  let* current_workload =
    match input.service_name with
    | Some name ->
        Docker.Client.get_container_by_name client ~net
          ~container_name:(Bondi_common.Router_name.to_string name)
    | None -> Ok None
  in
  Ok { current_traefik; current_workload }

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
    (* The version is compared and the name is not, so a Traefik already running
       the requested version under another spelling of its name is left alone.
       A digest is a version as a tag is, so a new pin redeploys. A bare image
       id parses, as name [sha256] with the hex as its tag, and is compared
       like any other version, so it redeploys. Only an image that does not
       parse at all is never redeployed over. *)
    let same_version a b =
      Option.equal String.equal (Image_reference.tag a) (Image_reference.tag b)
      && Option.equal String.equal (Image_reference.digest a)
           (Image_reference.digest b)
    in
    match
      (input.traefik_image, Image_reference.of_string current_traefik.image)
    with
    | None, _ -> false
    | Some requested, Ok current -> not (same_version current requested)
    | Some _, Error (Image_reference.Empty | Malformed _) -> false

(* What the plan does about the running Traefik. A replacement carries the
   container it stops, and keeping one carries nothing, so there is no state
   that stops a container without deploying a new one. *)
type traefik_decision =
  | Traefik_absent
  | Traefik_replace of Docker.Client.container
  | Traefik_keep

let traefik_decision input (context : deploy_context) =
  match context.current_traefik with
  | None -> Traefik_absent
  | Some container ->
      if should_redeploy_traefik input container then Traefik_replace container
      else Traefik_keep

let traefik_actions (input : deploy_input) (context : deploy_context) :
    (action list, string) result =
  if not (should_run_traefik input) then Ok []
  else
    let network =
      CreateNetwork { network_name = Bondi_common.Defaults.network_name }
    in
    let deploy ~stop =
      match
        ( input.traefik_image,
          input.traefik_domain_name,
          input.traefik_acme_email )
      with
      | Some image, Some domain_name, Some acme_email ->
          let traefik_config : Docker.Traefik.config =
            {
              network_name = Bondi_common.Defaults.network_name;
              domain_name;
              traefik_image = Some image;
              acme_email;
              acme_ca_server = input.traefik_acme_ca_server;
            }
          in
          let docker_config = Docker.Traefik.get_docker_config traefik_config in
          (* The pull comes before the stop, so a Traefik image that cannot be
             pulled leaves the running proxy in place and serving. *)
          Ok
            ((network :: PullImage { image; with_auth = false } :: stop)
            @ [
                EnsureTraefik
                  { domain_name; acme_email; traefik_config = docker_config };
              ])
      | None, _, _
      | _, None, _
      | _, _, None ->
          Error "missing required traefik configuration"
    in
    match traefik_decision input context with
    | Traefik_keep -> Ok [ network ]
    | Traefik_absent -> deploy ~stop:[]
    | Traefik_replace container ->
        deploy ~stop:[ StopAndRemoveContainer container ]

let workload_actions (input : deploy_input) (context : deploy_context) :
    (action list, string) result =
  match input.traefik_domain_name with
  | None -> Ok []
  | Some _ -> (
      match input.image with
      | None ->
          Error
            "image is required when deploying a service (traefik_domain_name \
             is set but image is null)"
      | Some image ->
          let* name, service_cfg = service_config input in
          (* The pull comes before the stop, so a pull that fails leaves the
             old service running and the outage is only the stop, remove and
             start. It is planned on every service deploy: the reference parsed
             at decode, so there is no reading of it under which the pull could
             be skipped. *)
          let stop =
            match context.current_workload with
            | None -> []
            | Some container -> [ StopAndRemoveContainer container ]
          in
          Ok
            (PullImage { image; with_auth = Option.is_some input.registry_user }
             :: stop
            @ [
                RunWorkload
                  {
                    container_name = Bondi_common.Router_name.to_string name;
                    config = service_cfg;
                    host_config = Workload_host_config.of_volumes input.volumes;
                    networking_conf = default_networking_config;
                  };
              ]))

let plan (input : deploy_input) (context : deploy_context) :
    (action list, string) result =
  let* traefik = traefik_actions input context in
  let* workload = workload_actions input context in
  Ok (traefik @ workload)

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
        Result.map
          (fun (inspect : Docker.Client.inspect_response) ->
            inspect.state.status)
          (Docker.Client.inspect_container client ~net ~clock ~container_id)
      in
      match state with
      | Ok "running" -> Ok ()
      | Ok "created" ->
          let* () = Docker.Client.start_container client ~net ~container_id in
          Eio.Time.sleep clock 1.0;
          loop (attempt + 1) "created"
      | Ok "exited" ->
          let* () = Docker.Client.start_container client ~net ~container_id in
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
        let* () =
          Docker.Client.create_network_if_not_exists client ~net ~network_name
        in
        run rest
    | EnsureTraefik { traefik_config; domain_name = _; acme_email = _ } :: rest
      ->
        let opts : Docker.Client.run_image_options =
          {
            container_name = Bondi_common.Builtin_container.traefik;
            config = traefik_config.container_config;
            host_config = Some traefik_config.host_config;
            networking_conf = Some default_networking_config;
          }
        in
        let* container_id =
          Docker.Client.run_image_with_opts client ~net opts
        in
        let* () = wait_for_traefik ~clock ~client ~net ~container_id in
        run rest
    | StopAndRemoveContainer container :: rest ->
        let* () =
          Docker.Client.stop_container client ~net ~container_id:container.id
        in
        let* () =
          Docker.Client.remove_container client ~net ~container_id:container.id
        in
        run rest
    | PullImage { image; with_auth } :: rest ->
        let* () =
          if with_auth then
            Docker.Client.pull_image_with_auth client ~net ~reference:image
          else Docker.Client.pull_image_no_auth client ~net ~reference:image
        in
        run rest
    | RunWorkload { container_name; config; host_config; networking_conf }
      :: rest ->
        let opts : Docker.Client.run_image_options =
          {
            container_name;
            config;
            host_config = Some host_config;
            networking_conf = Some networking_conf;
          }
        in
        let* _ = Docker.Client.run_image_with_opts client ~net opts in
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
