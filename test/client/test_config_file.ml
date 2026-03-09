open Alcotest
module Config_file = Bondi_client.Config_file

let with_temp_config contents f =
  let dir =
    let path =
      Filename.temp_file
        ~temp_dir:(Filename.get_temp_dir_name ())
        "bondi-test-" ""
    in
    Sys.remove path;
    Unix.mkdir path 0o700;
    path
  in
  let path = Filename.concat dir "bondi.yaml" in
  let oc = open_out path in
  output_string oc contents;
  close_out oc;
  let cwd = Sys.getcwd () in
  match
    Fun.protect
      ~finally:(fun () ->
        Sys.chdir cwd;
        Sys.remove path;
        Unix.rmdir dir)
      (fun () ->
        Sys.chdir dir;
        f ())
  with
  | value -> value
  | exception exn -> raise exn

let test_read_config_success () =
  Unix.putenv "REGISTRY_USER" "registry-user";
  Unix.putenv "REGISTRY_PASS" "registry-pass";
  Unix.putenv "DATABASE_URL" "postgres://example";
  Unix.putenv "SSH_PRIVATE_KEY_CONTENTS" "ssh-key";
  Unix.putenv "SSH_PRIVATE_KEY_PASS" "ssh-pass";
  let yaml =
    {|service:
  name: my-app
  image: registry.example.com/app
  port: 8080
  registry_user: "{{REGISTRY_USER}}"
  registry_pass: "{{REGISTRY_PASS}}"
  env_vars:
    DATABASE_URL: "{{DATABASE_URL}}"
  servers:
    - ip_address: 1.2.3.4
      ssh:
        user: root
        private_key_contents: "{{SSH_PRIVATE_KEY_CONTENTS}}"
        private_key_pass: "{{SSH_PRIVATE_KEY_PASS}}"

bondi_server:
  version: 0.1.0

traefik:
  domain_name: example.com
  image: traefik:v3.3.3
  acme_email: admin@example.com
|}
  in
  with_temp_config yaml (fun () ->
      match Config_file.read () with
      | Error message -> fail message
      | Ok config ->
          (match config.user_service with
          | None -> fail "expected service"
          | Some service -> (
              check string "name" "my-app" service.name;
              check string "image" "registry.example.com/app" service.image;
              check int "port" 8080 service.port;
              check (option string) "registry user" (Some "registry-user")
                service.registry_user;
              check (option string) "registry pass" (Some "registry-pass")
                service.registry_pass;
              check
                (list (pair string string))
                "env vars"
                [ ("DATABASE_URL", "postgres://example") ]
                service.env_vars;
              check int "server count" 1 (List.length service.servers);
              match service.servers with
              | [] -> fail "expected at least one server"
              | server :: _ -> (
                  check string "server ip" "1.2.3.4" server.ip_address;
                  match server.ssh with
                  | None -> fail "expected ssh config"
                  | Some ssh ->
                      check string "ssh user" "root" ssh.user;
                      check string "ssh key" "ssh-key" ssh.private_key_contents;
                      check string "ssh pass" "ssh-pass" ssh.private_key_pass)));
          check string "bondi version" "0.1.0" config.bondi_server.version;
          (match config.traefik with
          | None -> fail "expected traefik"
          | Some t ->
              check string "traefik domain" "example.com" t.domain_name;
              check string "traefik image" "traefik:v3.3.3" t.image;
              check string "traefik email" "admin@example.com" t.acme_email);
          check bool "cron_jobs absent defaults to None" true
            (config.cron_jobs = None))

let test_read_config_with_cron_jobs () =
  Unix.putenv "REGISTRY_USER" "registry-user";
  Unix.putenv "REGISTRY_PASS" "registry-pass";
  Unix.putenv "DATABASE_URL" "postgres://example";
  Unix.putenv "SSH_PRIVATE_KEY_CONTENTS" "ssh-key";
  Unix.putenv "SSH_PRIVATE_KEY_PASS" "ssh-pass";
  let yaml =
    {|service:
  name: my-app
  image: registry.example.com/app
  port: 8080
  registry_user: "{{REGISTRY_USER}}"
  registry_pass: "{{REGISTRY_PASS}}"
  env_vars:
    DATABASE_URL: "{{DATABASE_URL}}"
  servers:
    - ip_address: 1.2.3.4
      ssh:
        user: root
        private_key_contents: "{{SSH_PRIVATE_KEY_CONTENTS}}"
        private_key_pass: "{{SSH_PRIVATE_KEY_PASS}}"

bondi_server:
  version: 0.1.0

traefik:
  domain_name: example.com
  image: traefik:v3.3.3
  acme_email: admin@example.com

cron_jobs:
  - name: my-job
    image: ghcr.io/org/my-job
    schedule: "0 14 * * 3"
    env_vars:
      API_KEY: "{{REGISTRY_USER}}"
    registry_user: "{{REGISTRY_USER}}"
    registry_pass: "{{REGISTRY_PASS}}"
    server:
      ip_address: 1.2.3.4
      ssh:
        user: root
        private_key_contents: "{{SSH_PRIVATE_KEY_CONTENTS}}"
        private_key_pass: "{{SSH_PRIVATE_KEY_PASS}}"
|}
  in
  with_temp_config yaml (fun () ->
      match Config_file.read () with
      | Error message -> fail message
      | Ok config -> (
          match config.cron_jobs with
          | None -> fail "expected cron_jobs"
          | Some jobs -> (
              check int "cron job count" 1 (List.length jobs);
              match jobs with
              | [] -> fail "expected at least one cron job"
              | job :: _ -> (
                  check string "cron job name" "my-job" job.name;
                  check string "cron job image" "ghcr.io/org/my-job" job.image;
                  check string "cron job schedule" "0 14 * * 3" job.schedule;
                  check (option string) "cron job registry user"
                    (Some "registry-user") job.registry_user;
                  check (option string) "cron job registry pass"
                    (Some "registry-pass") job.registry_pass;
                  match job.env_vars with
                  | None -> fail "expected env_vars"
                  | Some env ->
                      check
                        (list (pair string string))
                        "cron job env"
                        [ ("API_KEY", "registry-user") ]
                        env))))

let test_read_config_cron_only () =
  Unix.putenv "SSH_PRIVATE_KEY_CONTENTS" "ssh-key";
  Unix.putenv "SSH_PRIVATE_KEY_PASS" "ssh-pass";
  let yaml =
    {|bondi_server:
  version: 0.1.0

cron_jobs:
  - name: my-cron
    image: ghcr.io/org/cron
    schedule: "0 * * * *"
    env_vars: {}
    server:
      ip_address: 1.2.3.4
      ssh:
        user: root
        private_key_contents: "{{SSH_PRIVATE_KEY_CONTENTS}}"
        private_key_pass: "{{SSH_PRIVATE_KEY_PASS}}"
|}
  in
  with_temp_config yaml (fun () ->
      match Config_file.read () with
      | Error message -> fail message
      | Ok config -> (
          check bool "no user_service" true (config.user_service = None);
          check bool "no traefik" true (config.traefik = None);
          check int "servers from cron job" 1
            (List.length (Config_file.servers config));
          match config.cron_jobs with
          | None -> fail "expected cron_jobs"
          | Some jobs -> (
              check int "cron job count" 1 (List.length jobs);
              match jobs with
              | [] -> fail "expected at least one cron job"
              | job :: _ ->
                  check string "cron job name" "my-cron" job.name;
                  check string "cron job image" "ghcr.io/org/cron" job.image;
                  check string "cron job schedule" "0 * * * *" job.schedule;
                  check (option string)
                    "cron job registry user defaults to None" None
                    job.registry_user;
                  check (option string)
                    "cron job registry pass defaults to None" None
                    job.registry_pass;
                  check string "cron job server ip" "1.2.3.4"
                    job.server.ip_address)))

let test_parse_service_with_drain_grace_period () =
  Unix.putenv "SSH_PRIVATE_KEY_CONTENTS" "ssh-key";
  Unix.putenv "SSH_PRIVATE_KEY_PASS" "ssh-pass";
  Unix.putenv "REGISTRY_USER" "registry-user";
  Unix.putenv "REGISTRY_PASS" "registry-pass";
  let yaml =
    {|service:
  name: my-app
  image: registry.example.com/app
  port: 8080
  drain_grace_period: 5
  registry_user: "{{REGISTRY_USER}}"
  registry_pass: "{{REGISTRY_PASS}}"
  env_vars: {}
  servers:
    - ip_address: 1.2.3.4
      ssh:
        user: root
        private_key_contents: "{{SSH_PRIVATE_KEY_CONTENTS}}"
        private_key_pass: "{{SSH_PRIVATE_KEY_PASS}}"

bondi_server:
  version: 0.1.0
|}
  in
  with_temp_config yaml (fun () ->
      match Config_file.read () with
      | Error message -> fail message
      | Ok config -> (
          match config.user_service with
          | None -> fail "expected service"
          | Some service ->
              check (option int) "drain_grace_period" (Some 5)
                service.drain_grace_period))

let test_parse_service_without_drain_grace_period () =
  Unix.putenv "SSH_PRIVATE_KEY_CONTENTS" "ssh-key";
  Unix.putenv "SSH_PRIVATE_KEY_PASS" "ssh-pass";
  Unix.putenv "REGISTRY_USER" "registry-user";
  Unix.putenv "REGISTRY_PASS" "registry-pass";
  let yaml =
    {|service:
  name: my-app
  image: registry.example.com/app
  port: 8080
  registry_user: "{{REGISTRY_USER}}"
  registry_pass: "{{REGISTRY_PASS}}"
  env_vars: {}
  servers:
    - ip_address: 1.2.3.4
      ssh:
        user: root
        private_key_contents: "{{SSH_PRIVATE_KEY_CONTENTS}}"
        private_key_pass: "{{SSH_PRIVATE_KEY_PASS}}"

bondi_server:
  version: 0.1.0
|}
  in
  with_temp_config yaml (fun () ->
      match Config_file.read () with
      | Error message -> fail message
      | Ok config -> (
          match config.user_service with
          | None -> fail "expected service"
          | Some service ->
              check (option int) "drain_grace_period" None
                service.drain_grace_period))

let test_parse_service_with_deployment_strategy () =
  Unix.putenv "SSH_PRIVATE_KEY_CONTENTS" "ssh-key";
  Unix.putenv "SSH_PRIVATE_KEY_PASS" "ssh-pass";
  Unix.putenv "REGISTRY_USER" "registry-user";
  Unix.putenv "REGISTRY_PASS" "registry-pass";
  let yaml =
    {|service:
  name: my-app
  image: registry.example.com/app
  port: 8080
  deployment_strategy: blue-green
  registry_user: "{{REGISTRY_USER}}"
  registry_pass: "{{REGISTRY_PASS}}"
  env_vars: {}
  servers:
    - ip_address: 1.2.3.4
      ssh:
        user: root
        private_key_contents: "{{SSH_PRIVATE_KEY_CONTENTS}}"
        private_key_pass: "{{SSH_PRIVATE_KEY_PASS}}"

bondi_server:
  version: 0.1.0
|}
  in
  with_temp_config yaml (fun () ->
      match Config_file.read () with
      | Error message -> fail message
      | Ok config -> (
          match config.user_service with
          | None -> fail "expected service"
          | Some service ->
              check (option string) "deployment_strategy" (Some "blue-green")
                service.deployment_strategy))

let test_parse_service_with_health_timeout () =
  Unix.putenv "SSH_PRIVATE_KEY_CONTENTS" "ssh-key";
  Unix.putenv "SSH_PRIVATE_KEY_PASS" "ssh-pass";
  Unix.putenv "REGISTRY_USER" "registry-user";
  Unix.putenv "REGISTRY_PASS" "registry-pass";
  let yaml =
    {|service:
  name: my-app
  image: registry.example.com/app
  port: 8080
  health_timeout: 60
  poll_interval: 2
  registry_user: "{{REGISTRY_USER}}"
  registry_pass: "{{REGISTRY_PASS}}"
  env_vars: {}
  servers:
    - ip_address: 1.2.3.4
      ssh:
        user: root
        private_key_contents: "{{SSH_PRIVATE_KEY_CONTENTS}}"
        private_key_pass: "{{SSH_PRIVATE_KEY_PASS}}"

bondi_server:
  version: 0.1.0
|}
  in
  with_temp_config yaml (fun () ->
      match Config_file.read () with
      | Error message -> fail message
      | Ok config -> (
          match config.user_service with
          | None -> fail "expected service"
          | Some service ->
              check (option int) "health_timeout" (Some 60)
                service.health_timeout;
              check (option int) "poll_interval" (Some 2) service.poll_interval))

let test_parse_service_without_health_timeout () =
  Unix.putenv "SSH_PRIVATE_KEY_CONTENTS" "ssh-key";
  Unix.putenv "SSH_PRIVATE_KEY_PASS" "ssh-pass";
  Unix.putenv "REGISTRY_USER" "registry-user";
  Unix.putenv "REGISTRY_PASS" "registry-pass";
  let yaml =
    {|service:
  name: my-app
  image: registry.example.com/app
  port: 8080
  registry_user: "{{REGISTRY_USER}}"
  registry_pass: "{{REGISTRY_PASS}}"
  env_vars: {}
  servers:
    - ip_address: 1.2.3.4
      ssh:
        user: root
        private_key_contents: "{{SSH_PRIVATE_KEY_CONTENTS}}"
        private_key_pass: "{{SSH_PRIVATE_KEY_PASS}}"

bondi_server:
  version: 0.1.0
|}
  in
  with_temp_config yaml (fun () ->
      match Config_file.read () with
      | Error message -> fail message
      | Ok config -> (
          match config.user_service with
          | None -> fail "expected service"
          | Some service ->
              check (option int) "health_timeout" None service.health_timeout;
              check (option int) "poll_interval" None service.poll_interval))

let test_service_logs_false () =
  Unix.putenv "SSH_PRIVATE_KEY_CONTENTS" "ssh-key";
  Unix.putenv "SSH_PRIVATE_KEY_PASS" "ssh-pass";
  Unix.putenv "REGISTRY_USER" "registry-user";
  Unix.putenv "REGISTRY_PASS" "registry-pass";
  let yaml =
    {|service:
  name: my-app
  image: registry.example.com/app
  port: 8080
  logs: false
  registry_user: "{{REGISTRY_USER}}"
  registry_pass: "{{REGISTRY_PASS}}"
  env_vars: {}
  servers:
    - ip_address: 1.2.3.4
      ssh:
        user: root
        private_key_contents: "{{SSH_PRIVATE_KEY_CONTENTS}}"
        private_key_pass: "{{SSH_PRIVATE_KEY_PASS}}"

bondi_server:
  version: 0.1.0
|}
  in
  with_temp_config yaml (fun () ->
      match Config_file.read () with
      | Error message -> fail message
      | Ok config -> (
          match config.user_service with
          | None -> fail "expected service"
          | Some service -> check (option bool) "logs" (Some false) service.logs
          ))

let test_service_logs_default () =
  Unix.putenv "SSH_PRIVATE_KEY_CONTENTS" "ssh-key";
  Unix.putenv "SSH_PRIVATE_KEY_PASS" "ssh-pass";
  Unix.putenv "REGISTRY_USER" "registry-user";
  Unix.putenv "REGISTRY_PASS" "registry-pass";
  let yaml =
    {|service:
  name: my-app
  image: registry.example.com/app
  port: 8080
  registry_user: "{{REGISTRY_USER}}"
  registry_pass: "{{REGISTRY_PASS}}"
  env_vars: {}
  servers:
    - ip_address: 1.2.3.4
      ssh:
        user: root
        private_key_contents: "{{SSH_PRIVATE_KEY_CONTENTS}}"
        private_key_pass: "{{SSH_PRIVATE_KEY_PASS}}"

bondi_server:
  version: 0.1.0
|}
  in
  with_temp_config yaml (fun () ->
      match Config_file.read () with
      | Error message -> fail message
      | Ok config -> (
          match config.user_service with
          | None -> fail "expected service"
          | Some service ->
              check (option bool) "logs defaults to None" None service.logs))

let test_alloy_config_parses () =
  Unix.putenv "SSH_PRIVATE_KEY_CONTENTS" "ssh-key";
  Unix.putenv "SSH_PRIVATE_KEY_PASS" "ssh-pass";
  Unix.putenv "GRAFANA_INSTANCE_ID" "123456";
  Unix.putenv "GRAFANA_API_KEY" "glc_secret";
  let yaml =
    {|bondi_server:
  version: 0.1.0

alloy:
  image: grafana/alloy:v1.9.0
  grafana_cloud:
    instance_id: "{{GRAFANA_INSTANCE_ID}}"
    api_key: "{{GRAFANA_API_KEY}}"
    endpoint: https://logs-prod.grafana.net/loki/api/v1/push
  collect: services_only
  labels:
    env: production
    team: backend
|}
  in
  with_temp_config yaml (fun () ->
      match Config_file.read () with
      | Error message -> fail message
      | Ok config -> (
          match config.alloy with
          | None -> fail "expected alloy config"
          | Some alloy -> (
              check (option string) "alloy image" (Some "grafana/alloy:v1.9.0")
                alloy.image;
              check string "grafana cloud instance_id" "123456"
                alloy.grafana_cloud.instance_id;
              check string "grafana cloud api_key" "glc_secret"
                alloy.grafana_cloud.api_key;
              check string "grafana cloud endpoint"
                "https://logs-prod.grafana.net/loki/api/v1/push"
                alloy.grafana_cloud.endpoint;
              check (option string) "collect" (Some "services_only")
                alloy.collect;
              match alloy.labels with
              | None -> fail "expected labels"
              | Some labels ->
                  check
                    (list (pair string string))
                    "labels"
                    [ ("env", "production"); ("team", "backend") ]
                    labels)))

let test_alloy_config_optional () =
  Unix.putenv "SSH_PRIVATE_KEY_CONTENTS" "ssh-key";
  Unix.putenv "SSH_PRIVATE_KEY_PASS" "ssh-pass";
  let yaml = {|bondi_server:
  version: 0.1.0
|} in
  with_temp_config yaml (fun () ->
      match Config_file.read () with
      | Error message -> fail message
      | Ok config ->
          check bool "alloy absent defaults to None" true (config.alloy = None))

let test_alloy_env_var_templating () =
  Unix.putenv "SSH_PRIVATE_KEY_CONTENTS" "ssh-key";
  Unix.putenv "SSH_PRIVATE_KEY_PASS" "ssh-pass";
  Unix.putenv "MY_INSTANCE" "inst-999";
  Unix.putenv "MY_KEY" "key-abc";
  Unix.putenv "MY_ENDPOINT" "https://logs.example.com/push";
  let yaml =
    {|bondi_server:
  version: 0.1.0

alloy:
  grafana_cloud:
    instance_id: "{{MY_INSTANCE}}"
    api_key: "{{MY_KEY}}"
    endpoint: "{{MY_ENDPOINT}}"
|}
  in
  with_temp_config yaml (fun () ->
      match Config_file.read () with
      | Error message -> fail message
      | Ok config -> (
          match config.alloy with
          | None -> fail "expected alloy config"
          | Some alloy ->
              check string "instance_id templated" "inst-999"
                alloy.grafana_cloud.instance_id;
              check string "api_key templated" "key-abc"
                alloy.grafana_cloud.api_key;
              check string "endpoint templated" "https://logs.example.com/push"
                alloy.grafana_cloud.endpoint))

let test_alloy_collect_default () =
  Unix.putenv "SSH_PRIVATE_KEY_CONTENTS" "ssh-key";
  Unix.putenv "SSH_PRIVATE_KEY_PASS" "ssh-pass";
  let yaml =
    {|bondi_server:
  version: 0.1.0

alloy:
  grafana_cloud:
    instance_id: "123"
    api_key: "abc"
    endpoint: https://logs.example.com/push
|}
  in
  with_temp_config yaml (fun () ->
      match Config_file.read () with
      | Error message -> fail message
      | Ok config -> (
          match config.alloy with
          | None -> fail "expected alloy config"
          | Some alloy ->
              check (option string) "collect defaults to None" None
                alloy.collect))

let test_alloy_labels_parse () =
  Unix.putenv "SSH_PRIVATE_KEY_CONTENTS" "ssh-key";
  Unix.putenv "SSH_PRIVATE_KEY_PASS" "ssh-pass";
  let yaml =
    {|bondi_server:
  version: 0.1.0

alloy:
  grafana_cloud:
    instance_id: "123"
    api_key: "abc"
    endpoint: https://logs.example.com/push
  labels:
    region: us-east-1
|}
  in
  with_temp_config yaml (fun () ->
      match Config_file.read () with
      | Error message -> fail message
      | Ok config -> (
          match config.alloy with
          | None -> fail "expected alloy config"
          | Some alloy -> (
              match alloy.labels with
              | None -> fail "expected labels"
              | Some labels ->
                  check
                    (list (pair string string))
                    "labels"
                    [ ("region", "us-east-1") ]
                    labels)))

let test_alloy_collect_invalid () =
  Unix.putenv "SSH_PRIVATE_KEY_CONTENTS" "ssh-key";
  Unix.putenv "SSH_PRIVATE_KEY_PASS" "ssh-pass";
  let yaml =
    {|bondi_server:
  version: 0.1.0

alloy:
  grafana_cloud:
    instance_id: "123"
    api_key: "abc"
    endpoint: https://logs.example.com/push
  collect: invalid_mode
|}
  in
  with_temp_config yaml (fun () ->
      match Config_file.read () with
      | Error msg ->
          check bool "error mentions invalid value" true
            (Bondi_common.String_utils.contains ~needle:"invalid_mode" msg)
      | Ok _ -> fail "expected error for invalid collect mode")

let () =
  run "Config_file"
    [
      ( "read",
        [
          test_case "reads config with env vars" `Quick test_read_config_success;
          test_case "reads config with cron jobs" `Quick
            test_read_config_with_cron_jobs;
          test_case "reads cron-only config" `Quick test_read_config_cron_only;
          test_case "parses service with drain_grace_period" `Quick
            test_parse_service_with_drain_grace_period;
          test_case "parses service without drain_grace_period" `Quick
            test_parse_service_without_drain_grace_period;
          test_case "parses service with deployment_strategy" `Quick
            test_parse_service_with_deployment_strategy;
          test_case "parses service with health_timeout and poll_interval"
            `Quick test_parse_service_with_health_timeout;
          test_case "parses service without health_timeout and poll_interval"
            `Quick test_parse_service_without_health_timeout;
          test_case "service logs false" `Quick test_service_logs_false;
          test_case "service logs default" `Quick test_service_logs_default;
        ] );
      ( "alloy",
        [
          test_case "alloy config parses" `Quick test_alloy_config_parses;
          test_case "alloy config optional" `Quick test_alloy_config_optional;
          test_case "alloy env var templating" `Quick
            test_alloy_env_var_templating;
          test_case "alloy collect default" `Quick test_alloy_collect_default;
          test_case "alloy labels parse" `Quick test_alloy_labels_parse;
          test_case "alloy collect invalid" `Quick test_alloy_collect_invalid;
        ] );
    ]
