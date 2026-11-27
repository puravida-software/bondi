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

(* A cron job's fields, with the schedule's type left open. A field's decoder
   sees only its own field, so a schedule read by one could not say which job
   it belongs to, and a payload can carry several. The derived decoder
   therefore keeps the schedule as the JSON it arrived as, and
   [cron_job_of_yojson] reads it once the job's name is in hand. *)
type 'schedule cron_job_fields = {
  name : string;
  image : cron_image;
  schedule : 'schedule;
  network : string option; [@default None]
  env_vars : string_map option; [@default None]
  secret_env_vars : string_map option; [@default None]
  registry_user : string option; [@default None]
  registry_pass : string option; [@default None]
  alert_sinks : Alert.sinks option; [@default None]
  exit_code_severities : exit_code_severities option; [@default None]
}
[@@deriving yojson]

type cron_job = Bondi_common.Cron_schedule.t cron_job_fields

let cron_job_to_yojson =
  cron_job_fields_to_yojson Bondi_common.Cron_schedule.to_yojson

(** Reads a cron job, refusing a schedule outside the grammar with a message
    that names the job. *)
let cron_job_of_yojson json : (cron_job, string) result =
  let* (fields : Yojson.Safe.t cron_job_fields) =
    cron_job_fields_of_yojson (fun schedule -> Ok schedule) json
  in
  let* schedule =
    Payload_codec.cron_schedule_of_yojson ~job:fields.name fields.schedule
  in
  Ok { fields with schedule }

(* How many times a service router sends a request: the first try and the
   resends. A resend goes to a backend that may be the one that just stopped, and
   the Traefik Bondi creates abandons a dial to it after 1 s
   ([Traefik.dial_timeout_flag]), so each lost try costs about 1 s.
   [observed -- 2026-11-23, Traefik v3.6.8, Docker Engine 29.10.0, Step B of the
   swap measurement, 1 s dial timeout on the gate's Traefik: 2 attempts lost
   59 of 8593 swap requests (0.69 %, 1 of 10 runs over 1 in 100); 3 attempts
   22 of 8378 (0.26 %, 0 of 10 over); 4 attempts 10 of 8355 (0.12 %, 0 of 10
   over). At 4 attempts the longest exhausted request took 4.006 s before its
   504, and the rescued ones a median of 1.046 s, at most 3.048 s.] *)
let retry_attempts = "4"

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
  (* Read nowhere. Kept because the decode is strict, and an older client still
     sends it: dropping it would refuse every deploy such a client makes. *)
  drain_grace_period : float option; [@default None]
  deployment_strategy : string option; [@default None]
  health_timeout : float option; [@default None]
  poll_interval : float option; [@default None]
  logs : bool option; [@default None]
  volumes : volumes option; [@default None]
}
[@@deriving yojson]

(* The proxy the request declares, decoded once, or [None]. A domain is what
   makes a service proxied: the router labels, blue-green's traffic switch and
   the network all follow from it. The Traefik image and ACME email, which the
   client sends with it, are what let the deploy converge the proxy itself;
   without them the request adopts the Traefik already on the box, and
   [converge] is [None]. Every decision about the proxy reads this one value, so
   no place can take a domain alone for "no proxy" while another takes it for
   one. *)
type proxy_request = { domain_name : string; converge : Proxy.input option }

let proxy_request (input : deploy_input) : proxy_request option =
  Option.map
    (fun domain_name ->
      let converge =
        match (input.traefik_image, input.traefik_acme_email) with
        | Some image, Some acme_email ->
            Some
              {
                Proxy.image;
                domain_name;
                acme_email;
                acme_ca_server = input.traefik_acme_ca_server;
                force_redeploy =
                  Option.value ~default:false input.force_traefik_redeploy;
              }
        | None, _
        | _, None ->
            None
      in
      { domain_name; converge })
    input.traefik_domain_name

(* The workload alone: the proxy is converged by the deploy, ahead of this
   strategy and of every other. *)
type deploy_context = { current_workload : Docker.Client.container option }

type action =
  | EnsureNetwork of { network_name : string }
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

(** The label naming the middlewares of the service's router. Bondi writes it on
    every service container, so it is also the key a deploy refuses to find
    declared by the image itself. *)
let router_middlewares_label name =
  "traefik.http.routers."
  ^ Bondi_common.Router_name.to_string name
  ^ ".middlewares"

(** The service's name, as checked, with the container config built for it. The
    name comes back with the config so that a caller needing both holds one that
    cannot be missing. The Traefik labels are written only when a domain is
    declared, and only then is a port required: without a proxy nothing routes
    to the port, so the service keeps its [bondi.*] labels alone. *)
let service_config (input : deploy_input) :
    (service_name * Docker.Client.container_config, string) result =
  match input.image with
  | None -> Error "image is required when deploying a service (got null)"
  | Some image -> (
      match input.service_name with
      | None -> Error "service_name required when deploying a service"
      | Some name ->
          let new_image = service_image_reference image in
          (* The service name, not the container name: blue-green starts the
             incoming colour under a temporary name. The router and its
             load-balancer service are named after it too, so two services
             behind one Traefik are two routers feeding two load balancers. The
             name was checked to be a router name at decode. *)
          let name_string = Bondi_common.Router_name.to_string name in
          let* traefik_labels =
            match proxy_request input with
            | None ->
                (* Docker merges an image's labels into the container's, and a
                   label given at create replaces the image's of the same key
                   [docs.docker.com/engine/manage-resources/labels/,
                   Containers: "Override or add labels when starting a
                   container"; observed -- 2026-11-22, Docker Engine 29.10.0].
                   A Traefik on the box would otherwise route an image that
                   ships [traefik.enable=true], reaching a service that is to
                   be unreachable from outside. *)
                Ok [ ("traefik.enable", "false") ]
            | Some { domain_name; converge = _ } -> (
                match input.port with
                | None ->
                    Error "port is required when deploying a service (got null)"
                | Some port ->
                    let router = "traefik.http.routers." ^ name_string in
                    (* Each service's router retries a request its old
                       container refused while exiting, against the one still
                       serving. A request a backend had read, in full or in
                       part, is not retried, so none an application received is
                       sent twice [observed -- 2026-11-22, traefik v3.6.8: a
                       POST read in full and an upload cut off mid-body each
                       answered 502 with no retry, and the other backend
                       received nothing]. The interval is Traefik v3.6's
                       documented default, 0 (retry at once), written out so a
                       change of that default changes nothing here. Named after
                       the service: two services sharing one name would declare
                       one middleware twice. *)
                    let retry =
                      "traefik.http.middlewares." ^ name_string ^ "-retry"
                    in
                    Ok
                      [
                        ("traefik.enable", "true");
                        ( router ^ ".rule",
                          Printf.sprintf "Host(`%s`) || Host(`www.%s`)"
                            domain_name domain_name );
                        (router ^ ".entrypoints", "websecure");
                        (router ^ ".tls", "true");
                        (router ^ ".tls.certresolver", "bondi_resolver");
                        (router_middlewares_label name, name_string ^ "-retry");
                        (retry ^ ".retry.attempts", retry_attempts);
                        (retry ^ ".retry.initialinterval", "0");
                        ( "traefik.http.services." ^ name_string
                          ^ ".loadbalancer.server.port",
                          string_of_int port );
                      ])
          in
          let labels : string_map =
            [
              ("bondi.managed", "true");
              ("bondi.type", "service");
              ( "bondi.logs",
                string_of_bool (Option.value ~default:true input.logs) );
            ]
            @ traefik_labels
            @ [ ("bondi.name", name_string) ]
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
          Ok (name, config))

(* ------------------------------------------------------------------------- *)
(* Phase 1: Gather context (read-only)                                       *)
(* ------------------------------------------------------------------------- *)

let gather_context ~client ~net (input : deploy_input) :
    (deploy_context, string) result =
  let* current_workload =
    match input.service_name with
    | Some name ->
        Docker.Client.get_container_by_name client ~net
          ~container_name:(Bondi_common.Router_name.to_string name)
    | None -> Ok None
  in
  Ok { current_workload }

(* ------------------------------------------------------------------------- *)
(* Phase 2: Plan (pure)                                                     *)
(* ------------------------------------------------------------------------- *)

let workload_actions (input : deploy_input) (context : deploy_context) :
    (action list, string) result =
  match input.service_name with
  | None -> Ok []
  | Some _ -> (
      match input.image with
      | None ->
          Error
            "image is required when deploying a service (service_name is set \
             but image is null)"
      | Some image ->
          let* name, service_cfg = service_config input in
          (* When the deploy converges a proxy it does so first and the proxy plan
             creates the network. Otherwise, with no proxy declared or one
             adopted from the box, nothing else on the deploy path does, and the service joins that network all the same, so its
             plan makes sure of it before anything is pulled or stopped. *)
          let network =
            match proxy_request input with
            | Some { converge = Some _; _ } -> []
            | Some { converge = None; _ }
            | None ->
                [
                  EnsureNetwork
                    { network_name = Bondi_common.Defaults.network_name };
                ]
          in
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
            (network
            @ PullImage
                { image; with_auth = Option.is_some input.registry_user }
              :: stop
            @ [
                RunWorkload
                  {
                    container_name = Bondi_common.Router_name.to_string name;
                    config = service_cfg;
                    host_config = Workload_host_config.of_volumes input.volumes;
                    networking_conf = Docker.Client.default_networking_config;
                  };
              ]))

let plan (input : deploy_input) (context : deploy_context) :
    (action list, string) result =
  workload_actions input context

(* ------------------------------------------------------------------------- *)
(* Phase 3: Interpreter                                                     *)
(* ------------------------------------------------------------------------- *)

let interpret ~client ~net (actions : action list) : (unit, string) result =
  let rec run = function
    | [] -> Ok ()
    | EnsureNetwork { network_name } :: rest ->
        let* () =
          Docker.Client.create_network_if_not_exists client ~net ~network_name
        in
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

let deploy ~client ~net (input : deploy_input) : (unit, string) result =
  let* context = gather_context ~client ~net input in
  let* actions = plan input context in
  interpret ~client ~net actions
