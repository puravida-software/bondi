let default_traefik_image = Bondi_common.Defaults.traefik_image

type config = {
  network_name : string;
  domain_name : string;
  traefik_image : Bondi_common.Image_reference.t option;
  acme_email : string;
  acme_ca_server : Bondi_common.Acme_ca_server.t option;
}

type docker_config = {
  container_config : Client.container_config;
  host_config : Client.host_config;
}

let docker_labels : (string * string) list =
  let acme = Bondi_common.Router_name.acme_challenge_name in
  let key kind rest = Printf.sprintf "traefik.http.%s.%s.%s" kind acme rest in
  [
    ("bondi.managed", "true");
    ("bondi.type", "infrastructure");
    ("bondi.logs", "true");
    (key "middlewares" "redirectscheme.permanent", "false");
    (key "routers" "rule", "PathPrefix(`/.well-known/acme-challenge/`)");
    (key "routers" "entrypoints", "web");
    (key "routers" "middlewares", acme);
    (key "routers" "service", acme);
    (key "services" "loadbalancer.server.port", "80");
  ]

(* With no certificate server set, no caServer flag is sent, so Traefik's own
   default, Let's Encrypt production, applies. *)
let ca_server_flags = function
  | None -> []
  | Some server ->
      [
        "--certificatesResolvers.bondi_resolver.acme.caServer="
        ^ Bondi_common.Acme_ca_server.to_string server;
      ]

(* How long Traefik waits to open a connection to a backend before it gives the
   attempt up, and the router's retry middleware resends the request. Traefik's
   default is 30 s, so a request that dialled a backend which had just stopped
   hung until the client gave up and nothing was retried.
   [observed -- 2026-11-23, Traefik v3.6.8, Docker Engine 29.10.0, Step A of the
   swap measurement: with this flag at 1s and 2 attempts, the blue-green swap
   lost 59 of 8593 requests (0.69 %), against 89 of 10157 (0.88 %) with it
   unset; the hung requests became dial errors the retry resent.] Together with
   [Simple.retry_attempts] it bounds a lost request's wait at about 4 s. Feature
   0041, NFR-1. The swap arm in scripts/deploy-arms.sh reads this line, so the
   gate's Traefik runs with the flag a Bondi-created one does. *)
let dial_timeout_flag = "--serversTransport.forwardingTimeouts.dialTimeout=1s"

let docker_cmd ~acme_email ~acme_ca_server =
  [
    "--providers.docker";
    "--providers.docker.exposedbydefault=false";
    "--entrypoints.web.address=:80";
    "--entrypoints.web.http.redirections.entryPoint.to=websecure";
    "--entrypoints.web.http.redirections.entryPoint.scheme=https";
    "--entrypoints.websecure.address=:443";
    dial_timeout_flag;
    "--certificatesResolvers.bondi_resolver.acme.email=" ^ acme_email;
    "--certificatesResolvers.bondi_resolver.acme.storage=/acme/acme.json";
    "--certificatesResolvers.bondi_resolver.acme.httpchallenge=true";
    "--certificatesResolvers.bondi_resolver.acme.httpchallenge.entrypoint=web";
  ]
  @ ca_server_flags acme_ca_server

let docker_port_bindings : Client.port_bindings =
  [
    ("80/tcp", [ { Client.host_ip = Some "0.0.0.0"; host_port = Some "80" } ]);
    ("443/tcp", [ { Client.host_ip = Some "0.0.0.0"; host_port = Some "443" } ]);
  ]

let docker_binds =
  [
    "/var/run/docker.sock:/var/run/docker.sock";
    Bondi_common.Defaults.acme_file_path ^ ":/acme/acme.json";
  ]

let get_docker_config (config : config) : docker_config =
  let image =
    match config.traefik_image with
    | None -> default_traefik_image
    | Some image -> Bondi_common.Image_reference.to_string image
  in
  let container_config : Client.container_config =
    {
      image = Some image;
      env = None;
      cmd =
        Some
          (docker_cmd ~acme_email:config.acme_email
             ~acme_ca_server:config.acme_ca_server);
      entrypoint = None;
      hostname = None;
      working_dir = None;
      labels = Some docker_labels;
      exposed_ports = Some [ "80/tcp"; "443/tcp" ];
    }
  in
  let host_config : Client.host_config =
    {
      binds = Some docker_binds;
      port_bindings = Some docker_port_bindings;
      network_mode = None;
      restart_policy = Some Restart_policy.bondi_managed;
      mounts = None;
      log_config = None;
    }
  in
  { container_config; host_config }
