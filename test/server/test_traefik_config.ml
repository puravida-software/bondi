module Traefik = Bondi_server__Docker__Traefik

let base_config : Traefik.config =
  {
    network_name = "bondi-network";
    domain_name = "example.com";
    traefik_image = None;
    acme_email = "ops@example.com";
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
    ]
