module Image_reference = Bondi_common.Image_reference

let ( let* ) = Result.bind

type input = {
  image : Image_reference.t;
  domain_name : string;
  acme_email : string;
  acme_ca_server : Bondi_common.Acme_ca_server.t option;
  force_redeploy : bool;
}

type decision = Keep | Create | Replace of Docker.Client.container

type action =
  | CreateNetwork of { network_name : string }
  | PullImage of { image : Image_reference.t }
  | StopAndRemove of { container_id : string }
  | EnsureTraefik of { traefik_config : Docker.Traefik.docker_config }

(* ------------------------------------------------------------------------- *)
(* Plan (pure)                                                               *)
(* ------------------------------------------------------------------------- *)

let is_the_proxy (container : Docker.Client.container) =
  List.exists
    (fun name ->
      Docker.Client.normalize_container_name name
      = Bondi_common.Builtin_container.traefik)
    container.names

(* The version is compared and the name is not, so a Traefik already running
   the requested version under another spelling of its name is left alone. A
   digest is a version as a tag is, so a new pin redeploys. A bare image id
   parses, as name [sha256] with the hex as its tag, and is compared like any
   other version, so it redeploys. Only an image that does not parse at all is
   never redeployed over. *)
let version_differs ~requested (current : Docker.Client.container) =
  let same_version a b =
    Option.equal String.equal (Image_reference.tag a) (Image_reference.tag b)
    && Option.equal String.equal (Image_reference.digest a)
         (Image_reference.digest b)
  in
  match Image_reference.of_string current.image with
  | Ok running -> not (same_version running requested)
  | Error (Image_reference.Empty | Malformed _) -> false

let decide (input : input) ~(current : Docker.Client.container option) =
  match current with
  | None -> Create
  | Some container ->
      if not (is_the_proxy container) then Create
      else if
        input.force_redeploy || version_differs ~requested:input.image container
      then Replace container
      else Keep

let plan (input : input) decision =
  let network =
    CreateNetwork { network_name = Bondi_common.Defaults.network_name }
  in
  let deploy ~stop =
    let traefik_config =
      Docker.Traefik.get_docker_config
        {
          network_name = Bondi_common.Defaults.network_name;
          domain_name = input.domain_name;
          traefik_image = Some input.image;
          acme_email = input.acme_email;
          acme_ca_server = input.acme_ca_server;
        }
    in
    (* The pull comes before the stop, so a Traefik image that cannot be pulled
       leaves the running proxy in place and serving. *)
    (network :: PullImage { image = input.image } :: stop)
    @ [ EnsureTraefik { traefik_config } ]
  in
  match decision with
  | Keep -> [ network ]
  | Create -> deploy ~stop:[]
  | Replace container ->
      deploy ~stop:[ StopAndRemove { container_id = container.id } ]

(* ------------------------------------------------------------------------- *)
(* Interpreter                                                               *)
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
    | PullImage { image } :: rest ->
        let* () =
          Docker.Client.pull_image_no_auth client ~net ~reference:image
        in
        run rest
    | StopAndRemove { container_id } :: rest ->
        let* () = Docker.Client.stop_container client ~net ~container_id in
        let* () = Docker.Client.remove_container client ~net ~container_id in
        run rest
    | EnsureTraefik { traefik_config } :: rest ->
        let opts : Docker.Client.run_image_options =
          {
            container_name = Bondi_common.Builtin_container.traefik;
            config = traefik_config.container_config;
            host_config = Some traefik_config.host_config;
            networking_conf = Some Docker.Client.default_networking_config;
          }
        in
        let* container_id =
          Docker.Client.run_image_with_opts client ~net opts
        in
        let* () = wait_for_traefik ~clock ~client ~net ~container_id in
        run rest
  in
  run actions
