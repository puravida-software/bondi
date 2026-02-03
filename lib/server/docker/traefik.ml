let default_traefik_image = "traefik:v3.3.0"

type config = {
  network_name : string;
  domain_name : string;
  traefik_image : string option;
  acme_email : string;
}

type docker_config = {
  container_config : Client.container_config;
  host_config : Client.host_config;
}

let docker_labels : (string * string) list =
  [
    ("traefik.http.middlewares.acme-http.redirectscheme.permanent", "false");
    ( "traefik.http.routers.acme-http.rule",
      "PathPrefix(`/.well-known/acme-challenge/`)" );
    ("traefik.http.routers.acme-http.entrypoints", "web");
    ("traefik.http.routers.acme-http.middlewares", "acme-http");
    ("traefik.http.routers.acme-http.service", "acme-http");
    ("traefik.http.services.acme-http.loadbalancer.server.port", "80");
  ]

let docker_cmd ~acme_email =
  [
    "--providers.docker";
    "--providers.docker.exposedbydefault=false";
    "--entrypoints.web.address=:80";
    "--entrypoints.web.http.redirections.entryPoint.to=websecure";
    "--entrypoints.web.http.redirections.entryPoint.scheme=https";
    "--entrypoints.websecure.address=:443";
    "--certificatesResolvers.bondi_resolver.acme.email=" ^ acme_email;
    "--certificatesResolvers.bondi_resolver.acme.storage=/acme/acme.json";
    "--certificatesResolvers.bondi_resolver.acme.httpchallenge=true";
    "--certificatesResolvers.bondi_resolver.acme.httpchallenge.entrypoint=web";
    "--certificatesresolvers.bondi_resolver.acme.dnschallenge.resolvers=1.1.1.1:53,8.8.8.8:53";
  ]

let docker_port_bindings : Client.port_bindings =
  [
    ("80/tcp", [ { Client.host_ip = Some "0.0.0.0"; host_port = Some "80" } ]);
    ("443/tcp", [ { Client.host_ip = Some "0.0.0.0"; host_port = Some "443" } ]);
  ]

let docker_binds =
  [
    "/var/run/docker.sock:/var/run/docker.sock";
    "/etc/traefik/acme/acme.json:/acme/acme.json";
  ]

let get_docker_config (config : config) : docker_config =
  let image =
    match config.traefik_image with
    | None -> default_traefik_image
    | Some "" -> default_traefik_image
    | Some image -> image
  in
  let container_config : Client.container_config =
    {
      image = Some image;
      env = None;
      cmd = Some (docker_cmd ~acme_email:config.acme_email);
      entrypoint = None;
      hostname = None;
      working_dir = None;
      labels = Some docker_labels;
    }
  in
  let host_config : Client.host_config =
    {
      binds = Some docker_binds;
      port_bindings = Some docker_port_bindings;
      network_mode = None;
      restart_policy = None;
    }
  in
  { container_config; host_config }
