module Traefik = Bondi_server__Docker__Traefik

let base_config : Traefik.config =
  {
    network_name = "bondi-network";
    domain_name = "example.com";
    traefik_image = None;
    acme_email = "ops@example.com";
    acme_ca_server = None;
  }

let test_traefik_declares_unless_stopped () =
  let docker = Traefik.get_docker_config base_config in
  match docker.host_config.restart_policy with
  | None -> Alcotest.fail "traefik host_config declares no restart policy"
  | Some policy ->
      Alcotest.check Alcotest.string "restart policy name" "unless-stopped"
        policy.name;
      Alcotest.check
        (Alcotest.option Alcotest.int)
        "no maximum retry count" None policy.maximum_retry_count

let test_traefik_host_config_keeps_binds_and_ports () =
  let docker = Traefik.get_docker_config base_config in
  (match docker.host_config.binds with
  | None -> Alcotest.fail "traefik host_config declares no binds"
  | Some binds ->
      Alcotest.check Alcotest.bool "mounts the docker socket" true
        (List.exists
           (fun bind ->
             Bondi_common.String_utils.contains ~needle:"/var/run/docker.sock"
               bind)
           binds);
      Alcotest.check Alcotest.bool "mounts the acme store" true
        (List.exists
           (fun bind ->
             Bondi_common.String_utils.contains ~needle:"acme.json" bind)
           binds));
  match docker.host_config.port_bindings with
  | None -> Alcotest.fail "traefik host_config declares no port bindings"
  | Some bindings ->
      Alcotest.check Alcotest.bool "publishes 80/tcp" true
        (List.mem_assoc "80/tcp" bindings);
      Alcotest.check Alcotest.bool "publishes 443/tcp" true
        (List.mem_assoc "443/tcp" bindings)

let ca_server_flag = "--certificatesResolvers.bondi_resolver.acme.caServer="

(* Every flag of Traefik's command that names a certificate server. *)
let ca_server_flags (config : Traefik.config) =
  let docker = Traefik.get_docker_config config in
  match docker.container_config.cmd with
  | None -> Alcotest.fail "traefik container_config declares no command"
  | Some cmd -> List.filter (String.starts_with ~prefix:ca_server_flag) cmd

(* A certificate server that is set reaches Traefik as one flag carrying it, so
   the resolver orders from that server and from no other. *)
let test_traefik_cmd_ca_server () =
  let url = "https://pebble:14000/dir" in
  match Bondi_common.Acme_ca_server.of_string url with
  | Error msg -> Alcotest.failf "the fixture URL was refused: %s" msg
  | Ok server ->
      Alcotest.check
        Alcotest.(list string)
        "exactly one caServer flag, carrying the URL"
        [ ca_server_flag ^ url ]
        (ca_server_flags { base_config with acme_ca_server = Some server })

(* With no certificate server set, Traefik is sent no caServer flag, so its own
   default applies, which is Let's Encrypt production. *)
let test_traefik_cmd_no_ca_server () =
  Alcotest.check
    Alcotest.(list string)
    "no caServer flag" []
    (ca_server_flags { base_config with acme_ca_server = None })

(* The router, middleware and service names in the labels on Bondi's own
   Traefik container are all in [Router_name.reserved], so a service cannot be
   named one and the list cannot drift from this module. *)
let test_reserved_covers_traefik_labels () =
  let segments =
    List.filter_map
      (fun (key, _) ->
        match String.split_on_char '.' key with
        | "traefik"
          :: "http"
          :: ("routers" | "middlewares" | "services")
          :: name
          :: _ ->
            Some name
        | _ -> None)
      Traefik.docker_labels
  in
  Alcotest.(check bool) "the container defines names" true (segments <> []);
  List.iter
    (fun name ->
      Alcotest.(check bool)
        (Printf.sprintf "%S is reserved" name)
        true
        (List.mem name Bondi_common.Router_name.reserved))
    segments

(* The dial timeout reaches the container Bondi creates as exactly this flag,
   once: a dial to a backend that no longer answers is abandoned after 1 s and
   the router's retry resends it, instead of waiting out Traefik's 30 s default. *)
let test_traefik_cmd_dial_timeout () =
  let docker = Traefik.get_docker_config base_config in
  match docker.container_config.cmd with
  | None -> Alcotest.fail "traefik container_config declares no command"
  | Some cmd ->
      Alcotest.check
        (Alcotest.list Alcotest.string)
        "exactly one dialTimeout flag, of 1s"
        [ "--serversTransport.forwardingTimeouts.dialTimeout=1s" ]
        (List.filter
           (String.starts_with
              ~prefix:"--serversTransport.forwardingTimeouts.dialTimeout")
           cmd)

let () =
  Alcotest.run "Traefik config"
    [
      ( "host config",
        [
          Alcotest.test_case "declares unless-stopped" `Quick
            test_traefik_declares_unless_stopped;
          Alcotest.test_case "keeps binds and port bindings" `Quick
            test_traefik_host_config_keeps_binds_and_ports;
        ] );
      ( "labels",
        [
          Alcotest.test_case "reserved names cover the labels" `Quick
            test_reserved_covers_traefik_labels;
        ] );
      ( "command",
        [
          Alcotest.test_case "a set certificate server is one caServer flag"
            `Quick test_traefik_cmd_ca_server;
          Alcotest.test_case "no certificate server is no caServer flag" `Quick
            test_traefik_cmd_no_ca_server;
          Alcotest.test_case "the dial timeout is one flag of 1s" `Quick
            test_traefik_cmd_dial_timeout;
        ] );
    ]
