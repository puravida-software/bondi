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
              check string "name" "my-app"
                (Bondi_common.Router_name.to_string service.name);
              check string "image" "registry.example.com/app"
                (Bondi_common.Image_reference.to_string service.image);
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
                      check (option string) "ssh key" (Some "ssh-key")
                        ssh.private_key_contents;
                      check (option string) "ssh pass" (Some "ssh-pass")
                        ssh.private_key_pass)));
          check string "bondi version" "0.1.0" config.bondi_server.version;
          (match config.traefik with
          | None -> fail "expected traefik"
          | Some t ->
              check string "traefik domain" "example.com" t.domain_name;
              check string "traefik image" "traefik:v3.3.3"
                (Bondi_common.Image_reference.to_string t.image);
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
                  check string "cron job image" "ghcr.io/org/my-job"
                    (Bondi_common.Image_reference.to_string job.image);
                  check string "cron job schedule" "0 14 * * 3"
                    (Bondi_common.Cron_schedule.to_string job.schedule);
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
                  check string "cron job image" "ghcr.io/org/cron"
                    (Bondi_common.Image_reference.to_string job.image);
                  check string "cron job schedule" "0 * * * *"
                    (Bondi_common.Cron_schedule.to_string job.schedule);
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
                (Option.map Bondi_common.Image_reference.to_string alloy.image);
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

let alloy_credential_yaml ~instance_id ~api_key =
  Printf.sprintf
    {|bondi_server:
  version: 0.1.0

alloy:
  grafana_cloud:
    instance_id: %s
    api_key: %s
    endpoint: https://logs.example.com/push
|}
    instance_id api_key

(* [docker run --env-file] is line-oriented, so a newline inside a credential
   ends the record and the remainder declares a second variable. The [=] case is
   the other half of the same parser rule: everything after the first [=] is the
   value, to the end of the line, so an [=] inside a value reshapes nothing and
   is accepted. *)
let test_alloy_credential_newline_rejected () =
  Unix.putenv "SSH_PRIVATE_KEY_CONTENTS" "ssh-key";
  Unix.putenv "SSH_PRIVATE_KEY_PASS" "ssh-pass";
  let yaml =
    alloy_credential_yaml ~instance_id:{|"123"|}
      ~api_key:{|"glc_secret\nGRAFANA_CLOUD_INSTANCE_ID=999"|}
  in
  with_temp_config yaml (fun () ->
      match Config_file.read () with
      | Ok _ -> fail "expected a newline in the api key to be rejected"
      | Error message ->
          check bool
            (Printf.sprintf "error names the variable, got: %s" message)
            true
            (Bondi_common.String_utils.contains ~needle:"GRAFANA_CLOUD_API_KEY"
               message);
          check bool
            (Printf.sprintf "error does not echo the credential, got: %s"
               message)
            false
            (Bondi_common.String_utils.contains ~needle:"glc_secret" message))

let test_alloy_instance_id_newline_rejected () =
  Unix.putenv "SSH_PRIVATE_KEY_CONTENTS" "ssh-key";
  Unix.putenv "SSH_PRIVATE_KEY_PASS" "ssh-pass";
  let yaml =
    alloy_credential_yaml ~instance_id:{|"123\nGRAFANA_CLOUD_API_KEY=leaked"|}
      ~api_key:{|"abc"|}
  in
  with_temp_config yaml (fun () ->
      match Config_file.read () with
      | Ok _ -> fail "expected a newline in the instance id to be rejected"
      | Error message ->
          check bool
            (Printf.sprintf "error names the variable, got: %s" message)
            true
            (Bondi_common.String_utils.contains
               ~needle:"GRAFANA_CLOUD_INSTANCE_ID" message))

let test_alloy_credential_equals_sign_accepted () =
  Unix.putenv "SSH_PRIVATE_KEY_CONTENTS" "ssh-key";
  Unix.putenv "SSH_PRIVATE_KEY_PASS" "ssh-pass";
  let yaml =
    alloy_credential_yaml ~instance_id:{|"123"|} ~api_key:{|"glc_eyJvIjoiMT=="|}
  in
  with_temp_config yaml (fun () ->
      match Config_file.read () with
      | Error message -> fail message
      | Ok config -> (
          match config.alloy with
          | None -> fail "expected alloy config"
          | Some alloy ->
              check string "api key kept verbatim" "glc_eyJvIjoiMT=="
                alloy.grafana_cloud.api_key))

(* [retries] is spliced verbatim under [grafana_cloud], so a caller chooses
   the YAML spelling: a bare [5] is a number, a quoted ["5"] a string. *)
let alloy_retries_yaml retries =
  Printf.sprintf
    {|bondi_server:
  version: 0.1.0

alloy:
  grafana_cloud:
    instance_id: "123"
    api_key: "abc"
    endpoint: https://logs.example.com/push
    max_backoff_retries: %s
|}
    retries

let read_alloy_retries yaml =
  Unix.putenv "SSH_PRIVATE_KEY_CONTENTS" "ssh-key";
  Unix.putenv "SSH_PRIVATE_KEY_PASS" "ssh-pass";
  with_temp_config yaml (fun () ->
      match Config_file.read () with
      | Error message -> Error message
      | Ok config -> (
          match config.alloy with
          | None -> Error "expected alloy config"
          | Some alloy -> Ok (config, alloy)))

let retries_as_int (alloy : Config_file.alloy) =
  Option.map Bondi_common.Alloy_river.Max_backoff_retries.to_int
    alloy.grafana_cloud.max_backoff_retries

let test_alloy_max_backoff_retries_absent () =
  match
    read_alloy_retries
      {|bondi_server:
  version: 0.1.0

alloy:
  grafana_cloud:
    instance_id: "123"
    api_key: "abc"
    endpoint: https://logs.example.com/push
|}
  with
  | Error message -> fail message
  | Ok (_, alloy) ->
      check (option int) "absent decodes to None" None (retries_as_int alloy)

(* [0] is the value Alloy reads as "retry indefinitely", so it is a value to
   keep, not an absence to drop. *)
let test_alloy_max_backoff_retries_zero_and_positive () =
  List.iter
    (fun n ->
      match read_alloy_retries (alloy_retries_yaml (string_of_int n)) with
      | Error message -> fail message
      | Ok (_, alloy) ->
          check (option int)
            (Printf.sprintf "%d decodes to itself" n)
            (Some n) (retries_as_int alloy))
    [ 0; 5 ]

let test_alloy_max_backoff_retries_negative_refused () =
  match read_alloy_retries (alloy_retries_yaml "-1") with
  | Ok _ -> fail "expected a negative retry limit to be refused"
  | Error message ->
      check bool
        (Printf.sprintf "error names the field, got: %s" message)
        true
        (Bondi_common.String_utils.contains
           ~needle:"alloy.grafana_cloud.max_backoff_retries" message)

(* Every non-integer is refused with the same words, whatever its JSON type. *)
let test_alloy_max_backoff_retries_non_integer_refused () =
  List.iter
    (fun (label, spelling) ->
      match read_alloy_retries (alloy_retries_yaml spelling) with
      | Ok _ -> fail (label ^ ": expected the retry limit to be refused")
      | Error message ->
          check bool
            (Printf.sprintf "%s: refusal says what to write, got: %s" label
               message)
            true
            (Bondi_common.String_utils.contains
               ~needle:
                 "alloy.grafana_cloud.max_backoff_retries: expected a whole \
                  number"
               message))
    [ ("string", {|"5"|}); ("float", "5.5"); ("bool", "true"); ("list", "[5]") ]

(* The field is read for one consumer, the River config setup ships, so the
   chain is followed from the manifest to the line Alloy reads. *)
let test_alloy_max_backoff_retries_reaches_river () =
  match read_alloy_retries (alloy_retries_yaml "7") with
  | Error message -> fail message
  | Ok (config, alloy) ->
      let river =
        Bondi_client.Cmd.Setup.alloy_river_config config alloy
        |> Bondi_common.Alloy_river.generate
      in
      check bool
        (Printf.sprintf "river carries the declared limit, got:\n%s" river)
        true
        (Bondi_common.String_utils.contains ~needle:"max_backoff_retries = 7"
           river)

let managed_yaml body =
  {|bondi_server:
  version: 0.1.0

managed_containers:
|} ^ body

let read_managed yaml =
  with_temp_config yaml (fun () ->
      match Config_file.read () with
      | Error message -> Error message
      | Ok config -> Config_file.managed_containers config)

let check_rejected ~needle yaml =
  match read_managed yaml with
  | Ok _ -> fail "expected the entry to be rejected"
  | Error message ->
      check bool
        (Printf.sprintf "error names %S, got: %s" needle message)
        true
        (Bondi_common.String_utils.contains ~needle message)

let test_managed_containers_parse () =
  Unix.putenv "TWS_PASSWORD" "hunter2";
  let yaml =
    managed_yaml
      {|  - name: ib-gateway
    image: ghcr.io/gnzsnz/ib-gateway
    tag: "10.48.1e"
    restart: unless-stopped
    network: bondi-network
    ports:
      - "4001:4003"
      - "5900:5900"
    env_vars:
      TRADING_MODE: paper
    secret_env_vars:
      TWS_PASSWORD: "{{TWS_PASSWORD}}"
|}
  in
  match read_managed yaml with
  | Error message -> fail message
  | Ok [] -> fail "expected one managed container"
  | Ok (_ :: _ :: _) -> fail "expected exactly one managed container"
  | Ok [ spec ] ->
      let module M = Bondi_common.Managed_container in
      check string "name" "ib-gateway" (M.name spec);
      check string "image" "ghcr.io/gnzsnz/ib-gateway" (M.image spec);
      check string "tag" "10.48.1e" (M.tag spec);
      check bool "restart is unless-stopped" true
        (M.restart spec = M.Unless_stopped);
      check (option string) "network" (Some "bondi-network") (M.network spec);
      check bool "ports" true
        (M.ports spec
        = [
            { M.host = 4001; container = 4003 };
            { M.host = 5900; container = 5900 };
          ]);
      check
        (list (pair string string))
        "plain env"
        [ ("TRADING_MODE", "paper") ]
        (M.plain_env spec);
      check (option string) "secret env file" (Some "TWS_PASSWORD=hunter2\n")
        (M.secret_env_file_contents spec)

let test_managed_containers_absent_parses () =
  let yaml = {|bondi_server:
  version: 0.1.0
|} in
  match read_managed yaml with
  | Error message -> fail message
  | Ok specs -> check int "no managed containers" 0 (List.length specs)

let test_managed_container_requires_image () =
  check_rejected ~needle:"image"
    (managed_yaml
       {|  - name: ib-gateway
    tag: "10.48.1e"
    restart: always
|})

let test_managed_container_requires_tag () =
  check_rejected ~needle:"tag"
    (managed_yaml
       {|  - name: ib-gateway
    image: ghcr.io/gnzsnz/ib-gateway
    restart: always
|})

let test_managed_container_invalid_restart_policy_rejected () =
  check_rejected ~needle:"sometimes"
    (managed_yaml
       {|  - name: ib-gateway
    image: ghcr.io/gnzsnz/ib-gateway
    tag: "10.48.1e"
    restart: sometimes
|})

let test_managed_container_invalid_port_rejected () =
  check_rejected ~needle:"4001-4003"
    (managed_yaml
       {|  - name: ib-gateway
    image: ghcr.io/gnzsnz/ib-gateway
    tag: "10.48.1e"
    restart: always
    ports:
      - "4001-4003"
|})

let test_managed_container_unsafe_name_rejected () =
  check_rejected ~needle:"../etc/shadow"
    (managed_yaml
       {|  - name: "../etc/shadow"
    image: ghcr.io/gnzsnz/ib-gateway
    tag: "10.48.1e"
    restart: always
|})

let test_managed_container_duplicate_env_key_rejected () =
  check_rejected ~needle:"TWS_PASSWORD"
    (managed_yaml
       {|  - name: ib-gateway
    image: ghcr.io/gnzsnz/ib-gateway
    tag: "10.48.1e"
    restart: always
    env_vars:
      TWS_PASSWORD: placeholder
    secret_env_vars:
      TWS_PASSWORD: real-secret
|})

(* One fixture, two jobs: the declared-network job is the affirmative arm for
   the absent-network job's [None] assertion. *)
let cron_network_yaml =
  {|bondi_server:
  version: 0.1.0

cron_jobs:
  - name: joined-job
    image: ghcr.io/org/joined
    schedule: "0 * * * *"
    network: bondi-network
    server:
      ip_address: 1.2.3.4
  - name: unjoined-job
    image: ghcr.io/org/unjoined
    schedule: "5 * * * *"
    server:
      ip_address: 1.2.3.4
|}

let cron_jobs_of_fixture () =
  match Config_file.read () with
  | Error message -> fail message
  | Ok config -> (
      match config.cron_jobs with
      | None -> fail "expected cron_jobs"
      | Some jobs -> jobs)

let test_cron_job_network_parses () =
  with_temp_config cron_network_yaml (fun () ->
      match cron_jobs_of_fixture () with
      | job :: _ ->
          check string "cron job name" "joined-job" job.name;
          check (option string) "cron job network" (Some "bondi-network")
            job.network
      | [] -> fail "expected two cron jobs")

let test_cron_job_network_absent_parses () =
  with_temp_config cron_network_yaml (fun () ->
      match cron_jobs_of_fixture () with
      | _ :: job :: _ ->
          check string "cron job name" "unjoined-job" job.name;
          check (option string) "cron job network defaults to None" None
            job.network
      | _ -> fail "expected two cron jobs")

module Alert = Bondi_common.Alert

(* One fixture, two jobs: the alerting job is the affirmative arm for the quiet
   job's [None] assertions, proving the absence is the field being unset rather
   than the fixture failing to parse. *)
let cron_alerts_yaml =
  {|bondi_server:
  version: 0.1.0

cron_jobs:
  - name: alerting-job
    image: ghcr.io/org/alerting
    schedule: "0 * * * *"
    alert_sinks:
      critical:
        - https://pager.example.com/hook
        - https://record.example.com/hook
      failure:
        - https://dashboard.example.com/hook
    exit_code_severities:
      critical:
        - 70
      success:
        - 2
    server:
      ip_address: 1.2.3.4
  - name: quiet-job
    image: ghcr.io/org/quiet
    schedule: "5 * * * *"
    server:
      ip_address: 1.2.3.4
|}

let test_config_parses_alert_sinks_and_severities () =
  with_temp_config cron_alerts_yaml (fun () ->
      match cron_jobs_of_fixture () with
      | job :: _ -> (
          check string "cron job name" "alerting-job" job.name;
          (match job.alert_sinks with
          | None -> fail "expected alert_sinks"
          | Some sinks -> (
              let Alert.{ critical; failure } = sinks in
              (match critical with
              | [ a; b ] ->
                  check string "critical sink 0"
                    "https://pager.example.com/hook" (Alert.sink_url a);
                  check string "critical sink 1"
                    "https://record.example.com/hook" (Alert.sink_url b)
              | _ -> fail "expected two critical sinks");
              match failure with
              | [ f ] ->
                  check string "failure sink"
                    "https://dashboard.example.com/hook" (Alert.sink_url f)
              | _ -> fail "expected one failure sink"));
          (* Observe the abstract severity_map through its classifier: 70 is
             the configured critical, 2 is a non-zero code overridden to
             success, and unlisted codes fall to the defaults. *)
          match job.exit_code_severities with
          | None -> fail "expected exit_code_severities"
          | Some map ->
              check bool "code 70 is critical" true
                (Alert.severity_of_exit_code map 70 = Alert.Critical);
              check bool "code 2 overridden to success" true
                (Alert.severity_of_exit_code map 2 = Alert.Success);
              check bool "code 0 defaults to success" true
                (Alert.severity_of_exit_code map 0 = Alert.Success);
              check bool "code 1 defaults to failure" true
                (Alert.severity_of_exit_code map 1 = Alert.Failure))
      | [] -> fail "expected two cron jobs")

let test_config_new_fields_absent () =
  with_temp_config cron_alerts_yaml (fun () ->
      match cron_jobs_of_fixture () with
      | _ :: job :: _ ->
          check string "cron job name" "quiet-job" job.name;
          check bool "alert_sinks defaults to None" true (job.alert_sinks = None);
          check bool "exit_code_severities defaults to None" true
            (job.exit_code_severities = None)
      | _ -> fail "expected two cron jobs")

(* A schedule written as a number is refused at read, naming the job. *)
let test_config_rejects_non_string_schedule () =
  let yaml =
    {|bondi_server:
  version: 0.1.0

cron_jobs:
  - name: nightly
    image: ghcr.io/org/nightly
    schedule: 5
    server:
      ip_address: 1.2.3.4
|}
  in
  with_temp_config yaml (fun () ->
      match Config_file.read () with
      | Ok _ -> fail "expected a numeric schedule to be refused"
      | Error message ->
          check bool
            (Printf.sprintf "the refusal names the job and the value, got: %s"
               message)
            true
            (Bondi_common.String_utils.contains
               ~needle:
                 "cron job \"nightly\" schedule 5: the schedule is not a string"
               message))

let test_config_rejects_non_https_sink () =
  let yaml =
    {|bondi_server:
  version: 0.1.0

cron_jobs:
  - name: insecure-job
    image: ghcr.io/org/insecure
    schedule: "0 * * * *"
    alert_sinks:
      critical:
        - http://insecure.example.com/hook
    server:
      ip_address: 1.2.3.4
|}
  in
  with_temp_config yaml (fun () ->
      match Config_file.read () with
      | Ok _ -> fail "expected a non-https sink to be rejected"
      | Error message ->
          check bool "error names the rejected url" true
            (Bondi_common.String_utils.contains
               ~needle:"http://insecure.example.com/hook" message))

(* An encrypted private key that nothing can unlock is refused where the
   configuration is read, before any connection is opened. Left to the
   connection, ssh offers the key -- an OpenSSH key file carries its public half
   in cleartext -- the host accepts it, and the signature that never comes is
   reported by the host as an authorization failure: someone else's verdict on
   a fault that is entirely local.

   The key below is armour and nothing else. A [Proc-Type: 4,ENCRYPTED] header
   is the whole of what a traditional PEM container states about its
   encryption, so no key material is needed to state it. What each real format
   classifies as is settled where the classifier is tested; what is settled
   here is that the refusal reaches the operator from [read]. *)
let encrypted_pem_armour =
  "-----BEGIN RSA PRIVATE KEY-----\\nProc-Type: 4,ENCRYPTED\\nDEK-Info: \
   AES-128-CBC,0123456789ABCDEF\\n\\nbm90LWEtcmVhbC1rZXk=\\n-----END RSA \
   PRIVATE KEY-----\\n"

let ssh_identity_yaml ssh_block =
  Printf.sprintf
    {|service:
  name: web
  image: registry.example.com/web
  port: 8080
  env_vars: {}
  servers:
    - ip_address: 10.0.0.1
      ssh:
%s
bondi_server:
  version: 0.1.0
|}
    ssh_block

let test_encrypted_key_without_passphrase_refused () =
  let yaml =
    ssh_identity_yaml
      (Printf.sprintf
         {|        user: deploy
        private_key_contents: "%s"
        private_key_pass: ""
|}
         encrypted_pem_armour)
  in
  with_temp_config yaml (fun () ->
      match Config_file.read () with
      | Ok _ ->
          fail "expected an encrypted key with no passphrase to be refused"
      | Error message ->
          check bool
            (Printf.sprintf "the refusal names the server, got: %s" message)
            true
            (Bondi_common.String_utils.contains ~needle:"10.0.0.1" message);
          check bool
            (Printf.sprintf "the refusal names the empty field, got: %s" message)
            true
            (Bondi_common.String_utils.contains ~needle:"ssh.private_key_pass"
               message);
          check bool
            (Printf.sprintf "the refusal names the cipher, got: %s" message)
            true
            (Bondi_common.String_utils.contains ~needle:"(pem)" message);
          (* The rule [validate_alloy_credentials] states and this follows: the
             message names the variable and never the value. *)
          check bool
            (Printf.sprintf "the refusal echoes no key material, got: %s"
               message)
            false
            (Bondi_common.String_utils.contains ~needle:"BEGIN RSA PRIVATE KEY"
               message))

(* A manifest may decline to carry key material: a developer should not paste a
   private key into a configuration file to use a credential they already hold,
   and a hardware-backed key cannot be carried as a string at all. Absent is a
   shape, not an omission, and it parses.

   The block below names a [user] and nothing else, which is what `bondi init`
   scaffolds and what an operator relying on their own agent writes. Both key
   fields are checked, because the field this fixture stopped declaring is the
   passphrase: a required [private_key_pass] made this exact manifest fail to
   decode, and a check on [private_key_contents] alone would have gone on
   passing while it did. *)
let test_manifest_with_no_private_key_parses () =
  let yaml = ssh_identity_yaml {|        user: deploy
|} in
  with_temp_config yaml (fun () ->
      match Config_file.read () with
      | Error message -> fail message
      | Ok config -> (
          match Config_file.servers config with
          | [] -> fail "expected one server"
          | server :: _ -> (
              match server.ssh with
              | None -> fail "expected ssh config"
              | Some ssh ->
                  check string "ssh user" "deploy" ssh.user;
                  check (option string) "no key is declared" None
                    ssh.private_key_contents;
                  check (option string) "and no passphrase is declared" None
                    ssh.private_key_pass)))

(* One service, with whatever [service_lines] adds under it, so the parsing and
   refusing arms below differ from each other in those lines alone. *)
let volumes_yaml service_lines =
  {|service:
  name: web
  image: registry.example.com/web
  port: 8080
  env_vars: {}
  servers: []
|}
  ^ service_lines ^ {|
bondi_server:
  version: 0.1.0
|}

let invoices_volume ~host =
  Printf.sprintf
    {|  volumes:
    - host: %s
      container: /data/invoices
      read_only: false
|}
    host

let read_service_volumes yaml =
  with_temp_config yaml (fun () ->
      match Config_file.read () with
      | Error message -> Error message
      | Ok config -> (
          match config.user_service with
          | None -> fail "the fixture declares a service"
          | Some service -> Ok service.volumes))

let mount_fields = Test_helpers.mount_fields

let test_service_volumes_parse () =
  let yaml =
    volumes_yaml
      {|  volumes:
    - host: /srv/myapp/invoices
      container: /data/invoices
      read_only: false
    - host: /etc/myapp
      container: /config
      read_only: true
|}
  in
  match read_service_volumes yaml with
  | Error message -> fail message
  | Ok None -> fail "the declared volumes were dropped"
  | Ok (Some mounts) ->
      check
        (list (triple string string bool))
        "both entries, in order"
        [
          ("/srv/myapp/invoices", "/data/invoices", false);
          ("/etc/myapp", "/config", true);
        ]
        (List.map mount_fields mounts)

let test_service_without_volumes_parses_as_none () =
  let present =
    read_service_volumes
      (volumes_yaml (invoices_volume ~host:"/srv/myapp/invoices"))
  in
  let absent = read_service_volumes (volumes_yaml "") in
  (* The same fixture reaches [Some] with the field declared, so the [None]
     below is the field's absence and not a service that never parsed. *)
  (match present with
  | Ok (Some [ _ ]) -> ()
  | Ok (Some _)
  | Ok None ->
      fail "expected exactly the declared volume"
  | Error message -> fail message);
  match absent with
  | Error message -> fail message
  | Ok volumes ->
      check bool "an omitted volumes field is None" true
        (Option.is_none volumes)

let test_service_volume_relative_path_fails_the_read () =
  match
    read_service_volumes
      (volumes_yaml (invoices_volume ~host:"srv/myapp/invoices"))
  with
  | Ok _ -> fail "a relative host path was accepted"
  | Error message ->
      check string "the read fails naming the path"
        "invalid bondi.yaml: volume host path \"srv/myapp/invoices\" is not \
         absolute: it must start with /"
        message

let test_service_unknown_key_still_fails_the_read () =
  (* [volume] for [volumes]: a misspelt key must not be read as a service that
     declares no mounts. The correctly spelt line parses in the test above. *)
  let misspelt =
    volumes_yaml
      {|  volume:
    - host: /srv/myapp/invoices
      container: /data/invoices
      read_only: false
|}
  in
  match read_service_volumes misspelt with
  | Ok _ -> fail "an unknown key under service was accepted"
  | Error message ->
      check bool
        (Printf.sprintf "the read is refused as invalid, got: %s" message)
        true
        (Bondi_common.String_utils.contains ~needle:"invalid bondi.yaml" message)

let check_volumes_refused ~label yaml =
  match read_service_volumes yaml with
  | Ok _ -> fail (label ^ " was accepted")
  | Error message ->
      check bool
        (Printf.sprintf "%s is refused as invalid, got: %s" label message)
        true
        (Bondi_common.String_utils.contains ~needle:"invalid bondi.yaml" message)

let test_service_volume_missing_read_only_fails_the_read () =
  check_volumes_refused ~label:"an entry without read_only"
    (volumes_yaml
       {|  volumes:
    - host: /srv/myapp/invoices
      container: /data/invoices
|})

let test_service_volume_string_entry_fails_the_read () =
  check_volumes_refused ~label:"a string entry"
    (volumes_yaml {|  volumes:
    - "/a:/b"
|})

let test_service_volume_unknown_entry_key_fails_the_read () =
  check_volumes_refused ~label:"an unknown key inside an entry"
    (volumes_yaml
       {|  volumes:
    - host: /srv/myapp/invoices
      container: /data/invoices
      read_only: false
      mode: rw
|})

let test_service_volume_yes_read_only_reads_as_true () =
  (* YAML 1.1 reads bare [yes] as a boolean. Pinned so a change of parser that
     stops doing so is noticed. *)
  match
    read_service_volumes
      (volumes_yaml
         {|  volumes:
    - host: /srv/myapp/invoices
      container: /data/invoices
      read_only: yes
|})
  with
  | Error message -> fail message
  | Ok (Some [ mount ]) ->
      check bool "yes reads as read_only true" true
        (let _, _, read_only = mount_fields mount in
         read_only)
  | Ok _ -> fail "expected exactly one mount"

(* A manifest whose three image fields, service name and certificate server are
   each given by the caller, so that each arm below changes one of them and the
   refusal can only have come from that one. The defaults are the values
   USAGE.md shows, which read; the certificate server is absent unless given. *)
let images_yaml ?(name = "my-api") ?(service = "ghcr.io/acme/my-api")
    ?(traefik = "traefik:v3.6.8") ?acme_ca_server
    ?(cron = "ghcr.io/acme/backup-job") () =
  let acme_ca_server_line =
    match acme_ca_server with
    | None -> ""
    | Some url -> Printf.sprintf "  acme_ca_server: \"%s\"\n" url
  in
  Printf.sprintf
    {|service:
  name: "%s"
  image: "%s"
  port: 8080
  env_vars: {}
  servers:
    - ip_address: 203.0.113.10
      ssh:
        user: root
bondi_server:
  version: 0.1.0
traefik:
  domain_name: example.com
  image: "%s"
  acme_email: admin@example.com
%scron_jobs:
  - name: daily-backup
    image: "%s"
    schedule: "0 2 * * *"
    server:
      ip_address: 203.0.113.10
      ssh:
        user: root
|}
    name service traefik acme_ca_server_line cron

let read_images yaml = with_temp_config yaml Config_file.read

(* The refusal names the field and echoes what was written there. It is printed
   only to the terminal of the operator who wrote it, so the value is theirs to
   see, and it is the one thing that tells them which line to fix. A refusal
   that reaches a log does not echo it; this one reaches none. *)
let check_read_refused ~label ~expected yaml =
  match read_images yaml with
  | Ok _ -> fail (label ^ " was accepted")
  | Error message -> check string label expected message

let test_config_refuses_bad_image () =
  (match read_images (images_yaml ()) with
  | Ok _ -> ()
  | Error message ->
      fail ("the documented images must read, and were refused: " ^ message));
  check_read_refused ~label:"a service image carrying a tag"
    ~expected:
      "invalid bondi.yaml: service.image \"ghcr.io/acme/my-api:1.0\" carries a \
       tag or digest: give the image without one, such as ghcr.io/acme/my-api, \
       and its tag at deploy time"
    (images_yaml ~service:"ghcr.io/acme/my-api:1.0" ());
  check_read_refused ~label:"a service image pinned by digest"
    ~expected:
      (Printf.sprintf
         "invalid bondi.yaml: service.image \"ghcr.io/acme/my-api@sha256:%s\" \
          carries a tag or digest: give the image without one, such as \
          ghcr.io/acme/my-api, and its tag at deploy time"
         (String.make 64 'a'))
    (images_yaml
       ~service:("ghcr.io/acme/my-api@sha256:" ^ String.make 64 'a')
       ());
  check_read_refused ~label:"a service image that is no reference"
    ~expected:
      "invalid bondi.yaml: service.image \"Acme/My-Api\" is not an image \
       reference"
    (images_yaml ~service:"Acme/My-Api" ());
  check_read_refused ~label:"a traefik image with an empty tag"
    ~expected:
      "invalid bondi.yaml: traefik.image \"traefik:\" is not an image reference"
    (images_yaml ~traefik:"traefik:" ());
  let alloy_yaml image =
    Printf.sprintf
      {|bondi_server:
  version: 0.1.0

alloy:
  image: "%s"
  grafana_cloud:
    instance_id: "1"
    api_key: "k"
    endpoint: https://logs-prod.grafana.net/loki/api/v1/push
|}
      image
  in
  check_read_refused ~label:"an alloy image that is no reference"
    ~expected:
      "invalid bondi.yaml: alloy.image \"Grafana Alloy:latest\" is not an \
       image reference"
    (alloy_yaml "Grafana Alloy:latest");
  check_read_refused ~label:"a cron job image that is no reference"
    ~expected:
      "invalid bondi.yaml: cron_jobs image \"backup job\" is not an image \
       reference"
    (images_yaml ~cron:"backup job" ());
  check_read_refused ~label:"a cron job image carrying a tag"
    ~expected:
      "invalid bondi.yaml: cron_jobs image \"ghcr.io/acme/backup-job:1.0\" \
       carries a tag or digest: give the image without one, such as \
       ghcr.io/acme/backup-job, and its tag at deploy time"
    (images_yaml ~cron:"ghcr.io/acme/backup-job:1.0" ())

(* Traefik's image is a whole reference, so the shapes a service image refuses
   are the ones it must accept: a registry on a port, and a digest pin. *)
let test_config_accepts_traefik_reference () =
  let pinned = "registry:5000/traefik:v3.6.8@sha256:" ^ String.make 64 'b' in
  match read_images (images_yaml ~traefik:pinned ()) with
  | Error message -> fail message
  | Ok config -> (
      match config.traefik with
      | None -> fail "expected traefik"
      | Some traefik ->
          check string "the reference reads back as written" pinned
            (Bondi_common.Image_reference.to_string traefik.image))

let read_traefik yaml =
  match read_images yaml with
  | Error message -> fail ("expected the manifest to read: " ^ message)
  | Ok config -> (
      match config.traefik with
      | None -> fail "expected traefik"
      | Some traefik -> traefik)

(* Let's Encrypt's staging directory, the value a test box would set. *)
let staging_directory = "https://acme-staging-v02.api.letsencrypt.org/directory"

(* Absent is Traefik's own default, Let's Encrypt production, and is read as no
   value at all. A value that is set reads back exactly as written. *)
let test_config_acme_ca_server_optional () =
  check (option string) "absent reads as no certificate server" None
    (Option.map Bondi_common.Acme_ca_server.to_string
       (read_traefik (images_yaml ())).acme_ca_server);
  check (option string) "a set value reads back as written"
    (Some staging_directory)
    (Option.map Bondi_common.Acme_ca_server.to_string
       (read_traefik (images_yaml ~acme_ca_server:staging_directory ()))
         .acme_ca_server)

(* An ACME directory is served over https, so a value that is not an absolute
   https URL is a typo, refused when the file is read and naming the field,
   rather than a resolver that never orders. *)
let test_config_refuses_http_acme_ca_server () =
  check_read_refused ~label:"an http directory"
    ~expected:
      "invalid bondi.yaml: traefik.acme_ca_server \
       \"http://acme-staging-v02.api.letsencrypt.org/directory\" is not an \
       ACME directory URL: it must be an absolute https:// URL that names a \
       host and holds no whitespace or control character"
    (images_yaml
       ~acme_ca_server:"http://acme-staging-v02.api.letsencrypt.org/directory"
       ());
  check_read_refused ~label:"a directory with no scheme"
    ~expected:
      "invalid bondi.yaml: traefik.acme_ca_server \
       \"acme-staging-v02.api.letsencrypt.org/directory\" is not an ACME \
       directory URL: it must be an absolute https:// URL that names a host \
       and holds no whitespace or control character"
    (images_yaml
       ~acme_ca_server:"acme-staging-v02.api.letsencrypt.org/directory" ())

(* The service name names its Traefik router, and Traefik splits a label key at
   [.], so a name holding one would leave the service unserved. A name of one
   character is refused too: Docker refuses it as a container name. *)
let test_config_refuses_unroutable_service_name () =
  check_read_refused ~label:"a name holding a dot"
    ~expected:
      "invalid bondi.yaml: service.name \"my.api\" cannot name a Traefik \
       router: a router name is a lowercase letter or digit followed by one or \
       more lowercase letters, digits, _ or -"
    (images_yaml ~name:"my.api" ());
  check_read_refused ~label:"a name of one character"
    ~expected:
      "invalid bondi.yaml: service.name \"a\" cannot name a Traefik router: a \
       router name is a lowercase letter or digit followed by one or more \
       lowercase letters, digits, _ or -"
    (images_yaml ~name:"a" ());
  check_read_refused ~label:"a name with an uppercase letter"
    ~expected:
      "invalid bondi.yaml: service.name \"Api\" cannot name a Traefik router: \
       it holds an uppercase letter, and Traefik label keys are \
       case-insensitive, so names that differ only by case would collide"
    (images_yaml ~name:"Api" ());
  check_read_refused ~label:"a name Bondi's own Traefik container defines"
    ~expected:
      "invalid bondi.yaml: service.name \"acme-http\" is reserved: Bondi's own \
       Traefik container defines a router, middleware and service of that \
       name, and a service of the same name would collide with them"
    (images_yaml ~name:"acme-http" ());
  match read_images (images_yaml ~name:"my_api-2" ()) with
  | Error message -> fail ("a routable name was refused: " ^ message)
  | Ok config ->
      check (option string) "a routable name reads back as written"
        (Some "my_api-2")
        (Option.map
           (fun (service : Config_file.user_service) ->
             Bondi_common.Router_name.to_string service.name)
           config.user_service)

(* A cron job's name, schedule and secret entries are refused when bondi.yaml
   is read, before any server is contacted. A job runs in a container named
   after it, its schedule is written into root's crontab, and its secrets into
   a KEY=VALUE file read with no unquoting. *)

let cron_job_yaml ~name ~schedule ~secrets =
  Printf.sprintf
    {|  - name: "%s"
    image: ghcr.io/acme/job
    schedule: %s
%s    server:
      ip_address: 203.0.113.10
|}
    name schedule secrets

let free_job name = cron_job_yaml ~name ~schedule:{|"0 3 * * *"|} ~secrets:""

let cron_manifest ~service ~managed ~jobs =
  let service_block =
    match service with
    | None -> ""
    | Some name ->
        Printf.sprintf
          {|service:
  name: "%s"
  image: ghcr.io/acme/%s
  port: 8080
  env_vars: {}
  servers:
    - ip_address: 203.0.113.10
|}
          name name
  in
  let managed_block =
    match managed with
    | [] -> ""
    | names ->
        "managed_containers:\n"
        ^ String.concat ""
            (List.map
               (fun name ->
                 String.concat "\n"
                   [
                     "  - name: " ^ name;
                     "    image: postgres";
                     "    tag: \"17\"";
                     "    restart: always";
                     "";
                   ])
               names)
  in
  service_block
  ^ "bondi_server:\n  version: 0.1.0\n"
  ^ managed_block
  ^ "cron_jobs:\n"
  ^ String.concat "" jobs

let collision_refusal collisions =
  Printf.sprintf
    "cron jobs cannot take names already in use (%s): rename these jobs in \
     bondi.yaml"
    (String.concat "; " collisions)

let collision ~job ~holder =
  Printf.sprintf
    "cron job %S cannot take that name: %s already runs under it, and a cron \
     job's container is named after the job"
    job holder

(* One manifest per class of holder. Each refusal names the job and what holds
   its name, so the operator is told both entries. *)
let test_cron_name_collision_per_holder () =
  let refused ~label ~expected yaml =
    match with_temp_config yaml Config_file.read with
    | Ok _ -> fail (label ^ ": the clash was accepted")
    | Error message -> check string label (collision_refusal expected) message
  in
  refused ~label:"the service"
    ~expected:[ collision ~job:"web" ~holder:{|the service "web"|} ]
    (cron_manifest ~service:(Some "web") ~managed:[] ~jobs:[ free_job "web" ]);
  refused ~label:"the service's blue-green candidate"
    ~expected:
      [
        collision ~job:"web-new"
          ~holder:{|the service's blue-green candidate "web-new"|};
      ]
    (cron_manifest ~service:(Some "web") ~managed:[]
       ~jobs:[ free_job "web-new" ]);
  List.iter
    (fun builtin ->
      refused ~label:builtin
        ~expected:
          [
            collision ~job:builtin
              ~holder:(Printf.sprintf "the built-in container %S" builtin);
          ]
        (cron_manifest ~service:None ~managed:[] ~jobs:[ free_job builtin ]))
    [ "bondi-orchestrator"; "bondi-traefik"; "bondi-alloy" ];
  refused ~label:"a declared managed container's container name"
    ~expected:
      [ collision ~job:"bondi-db" ~holder:{|the managed container "bondi-db"|} ]
    (cron_manifest ~service:None ~managed:[ "db" ]
       ~jobs:[ free_job "bondi-db" ]);
  refused ~label:"another cron job"
    ~expected:[ collision ~job:"backup" ~holder:{|another cron job "backup"|} ]
    (cron_manifest ~service:None ~managed:[]
       ~jobs:[ free_job "backup"; free_job "backup" ]);
  (* The affirmative arm on the same fixture's shape: a managed container's
     own name, unprefixed, is not a container name, so a job may take it. *)
  match
    with_temp_config
      (cron_manifest ~service:(Some "web") ~managed:[ "db" ]
         ~jobs:[ free_job "db"; free_job "web-backup" ])
      Config_file.read
  with
  | Error message -> fail ("free names were refused: " ^ message)
  | Ok config ->
      check (list string) "the jobs come back" [ "db"; "web-backup" ]
        (List.map
           (fun (job : Config_file.cron_job) -> job.name)
           (Option.value config.cron_jobs ~default:[]))

(* The path rule is the server's too; read here, a name that would climb out of
   its directory is refused before any server is contacted. *)
let test_cron_unsafe_name_refused () =
  match
    with_temp_config
      (cron_manifest ~service:None ~managed:[]
         ~jobs:[ free_job "ok"; free_job "../x" ])
      Config_file.read
  with
  | Ok _ -> fail "an unsafe job name was accepted"
  | Error message ->
      check string "the refusal names the unsafe name only"
        "cron job names must be safe to place in a file path (\"../x\"). A \
         name must begin with a letter or a digit and may hold only letters, \
         digits, '.', '_' and '-': rename these jobs in bondi.yaml"
        message

let secret_refusal offenders =
  Printf.sprintf
    "cron job secret entries cannot be written to an env file (%s). A key must \
     be non-empty and hold no \"=\" and no control character, and a value must \
     hold no control character, newline included: fix these entries in \
     bondi.yaml"
    (String.concat "; " offenders)

(* The value is shaped like the credential it would be, so the absence check
   below is one a leak could fail. *)
let test_cron_secret_control_character_refused () =
  let secrets =
    {|    secret_env_vars:
      API_TOKEN: "sk-live-4f9a2c\nINJECTED=1"
|}
  in
  match
    with_temp_config
      (cron_manifest ~service:None ~managed:[]
         ~jobs:
           [ cron_job_yaml ~name:"nightly" ~schedule:{|"0 3 * * *"|} ~secrets ])
      Config_file.read
  with
  | Ok _ -> fail "a secret value holding a newline was accepted"
  | Error message ->
      check string "names the job and the key"
        (secret_refusal
           [
             {|job "nightly" has a control character in the value of "API_TOKEN"|};
           ])
        message;
      check bool "carries no part of the value" false
        (Bondi_common.String_utils.contains ~needle:"sk-live" message
        || Bondi_common.String_utils.contains ~needle:"INJECTED" message)

let test_cron_secret_bad_key_refused () =
  let secrets =
    {|    secret_env_vars:
      "API=TOKEN": placeholder
      "": placeholder
|}
  in
  match
    with_temp_config
      (cron_manifest ~service:None ~managed:[]
         ~jobs:
           [ cron_job_yaml ~name:"nightly" ~schedule:{|"0 3 * * *"|} ~secrets ])
      Config_file.read
  with
  | Ok _ -> fail "a secret key holding = was accepted"
  | Error message ->
      check string "names the job and each key"
        (secret_refusal
           [
             {|job "nightly" has an invalid key "API=TOKEN"|};
             {|job "nightly" has an invalid key ""|};
           ])
        message

let test_cron_schedule_refused_naming_job () =
  let refused ~label ~schedule ~expected =
    match
      with_temp_config
        (cron_manifest ~service:None ~managed:[]
           ~jobs:
             [
               free_job "hourly";
               cron_job_yaml ~name:"nightly" ~schedule ~secrets:"";
             ])
        Config_file.read
    with
    | Ok _ -> fail (label ^ " was accepted")
    | Error message -> check string label expected message
  in
  let grammar = Bondi_common.Cron_schedule.grammar in
  refused ~label:"an empty schedule" ~schedule:{|""|}
    ~expected:
      ({|invalid bondi.yaml: cron job "nightly" schedule "": the schedule is empty: |}
     ^ grammar);
  refused ~label:"four fields" ~schedule:{|"0 3 * *"|}
    ~expected:
      ({|invalid bondi.yaml: cron job "nightly" schedule "0 3 * *": the schedule holds 4 fields, not five: |}
     ^ grammar);
  refused ~label:"a schedule carrying a second crontab line"
    ~schedule:{|"not a schedule\n* * * * * root reboot"|}
    ~expected:
      ({|invalid bondi.yaml: cron job "nightly" schedule "not a schedule\n* * * * * root reboot": the schedule holds a control character, which would end the crontab line early: |}
     ^ grammar)

(* Names, schedules and secret keys of the shapes real manifests use; the
   manifest; the secret values are placeholders, since the real ones live in
   the operators' environments. The app's volumes are left out: only its fork
   build reads them. *)
let test_realistic_manifest_values_accepted () =
  let accepted ~label ~jobs yaml =
    match with_temp_config yaml Config_file.read with
    | Error message -> fail (label ^ " was refused: " ^ message)
    | Ok config ->
        check
          (list (pair string string))
          (label ^ ": names and schedules read back as written")
          jobs
          (List.map
             (fun (job : Config_file.cron_job) ->
               (job.name, Bondi_common.Cron_schedule.to_string job.schedule))
             (Option.value config.cron_jobs ~default:[]))
  in
  accepted ~label:"cron-trading-systems"
    ~jobs:[ ("canary-paper", "17 * * * *") ]
    (cron_manifest ~service:None ~managed:[]
       ~jobs:
         [
           cron_job_yaml ~name:"canary-paper" ~schedule:{|"17 * * * *"|}
             ~secrets:
               {|    secret_env_vars:
      API_KEY_ID: placeholder-key-id
      API_SECRET_KEY: placeholder-secret
      API_KEY: placeholder-api-key
|};
         ]);
  accepted ~label:"app"
    ~jobs:[ ("alert-check", "* * * * *") ]
    (cron_manifest ~service:(Some "app") ~managed:[]
       ~jobs:
         [
           cron_job_yaml ~name:"alert-check" ~schedule:{|"* * * * *"|}
             ~secrets:
               {|    secret_env_vars:
      DB_URL: "postgres://user:pass@db:5432/app?sslmode=disable"
      ALERT_RUNNER_PING_URL: "https://hc-ping.example.com/abc"
|};
         ]);
  accepted ~label:"app"
    ~jobs:[ ("app-backup", "30 3 * * *") ]
    (cron_manifest ~service:(Some "app-server") ~managed:[ "app-db" ]
       ~jobs:
         [
           cron_job_yaml ~name:"app-backup" ~schedule:{|"30 3 * * *"|}
             ~secrets:"";
         ]);
  (* The app declares no cron jobs; its service name is the only value the
     new pass reads. *)
  match
    with_temp_config
      {|service:
  name: myapp
  image: ghcr.io/acme/myapp
  port: 8080
  env_vars: {}
  servers:
    - ip_address: 203.0.113.10
bondi_server:
  version: 0.1.0
|}
      Config_file.read
  with
  | Error message -> fail ("myapp was refused: " ^ message)
  | Ok config ->
      check bool "myapp declares no cron jobs" true
        (Option.is_none config.cron_jobs)

let () =
  run "Config_file"
    [
      ( "images",
        [
          test_case "a bad image is refused, naming the field" `Quick
            test_config_refuses_bad_image;
          test_case "traefik takes a whole reference" `Quick
            test_config_accepts_traefik_reference;
        ] );
      ( "traefik and routers",
        [
          test_case "acme_ca_server is optional" `Quick
            test_config_acme_ca_server_optional;
          test_case "an http acme_ca_server is refused, naming the field" `Quick
            test_config_refuses_http_acme_ca_server;
          test_case "an unroutable service name is refused, naming the field"
            `Quick test_config_refuses_unroutable_service_name;
        ] );
      ( "cron job inputs",
        [
          test_case "a cron job taking a held name is refused, naming both"
            `Quick test_cron_name_collision_per_holder;
          test_case "a cron job name unsafe in a path is refused at read" `Quick
            test_cron_unsafe_name_refused;
          test_case
            "a secret value with a control character is refused, naming job \
             and key"
            `Quick test_cron_secret_control_character_refused;
          test_case "a bad secret key is refused, naming job and key" `Quick
            test_cron_secret_bad_key_refused;
          test_case "a bad schedule is refused, naming the job" `Quick
            test_cron_schedule_refused_naming_job;
          test_case "realistic names and schedules are accepted" `Quick
            test_realistic_manifest_values_accepted;
        ] );
      ( "read",
        [
          test_case "reads config with env vars" `Quick test_read_config_success;
          test_case "reads config with cron jobs" `Quick
            test_read_config_with_cron_jobs;
          test_case "reads cron-only config" `Quick test_read_config_cron_only;
          test_case "cron job network parses" `Quick
            test_cron_job_network_parses;
          test_case "cron job network absent parses" `Quick
            test_cron_job_network_absent_parses;
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
      ( "volumes",
        [
          test_case "service volumes parse" `Quick test_service_volumes_parse;
          test_case "service without volumes parses as None" `Quick
            test_service_without_volumes_parses_as_none;
          test_case "a relative volume path fails the read" `Quick
            test_service_volume_relative_path_fails_the_read;
          test_case "an unknown key under service still fails the read" `Quick
            test_service_unknown_key_still_fails_the_read;
          test_case "a volume without read_only fails the read" `Quick
            test_service_volume_missing_read_only_fails_the_read;
          test_case "a string volume entry fails the read" `Quick
            test_service_volume_string_entry_fails_the_read;
          test_case "an unknown key inside a volume fails the read" `Quick
            test_service_volume_unknown_entry_key_fails_the_read;
          test_case "read_only: yes reads as true" `Quick
            test_service_volume_yes_read_only_reads_as_true;
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
          test_case "alloy api key with a newline" `Quick
            test_alloy_credential_newline_rejected;
          test_case "alloy instance id with a newline" `Quick
            test_alloy_instance_id_newline_rejected;
          test_case "alloy api key with an equals sign" `Quick
            test_alloy_credential_equals_sign_accepted;
          test_case "alloy max_backoff_retries absent" `Quick
            test_alloy_max_backoff_retries_absent;
          test_case "alloy max_backoff_retries zero and positive" `Quick
            test_alloy_max_backoff_retries_zero_and_positive;
          test_case "alloy max_backoff_retries negative refused" `Quick
            test_alloy_max_backoff_retries_negative_refused;
          test_case "alloy max_backoff_retries non-integer refused" `Quick
            test_alloy_max_backoff_retries_non_integer_refused;
          test_case "alloy max_backoff_retries reaches the river config" `Quick
            test_alloy_max_backoff_retries_reaches_river;
        ] );
      ( "managed_containers",
        [
          test_case "managed containers parse" `Quick
            test_managed_containers_parse;
          test_case "managed containers absent parses" `Quick
            test_managed_containers_absent_parses;
          test_case "managed container requires image" `Quick
            test_managed_container_requires_image;
          test_case "managed container requires tag" `Quick
            test_managed_container_requires_tag;
          test_case "managed container invalid restart policy rejected" `Quick
            test_managed_container_invalid_restart_policy_rejected;
          test_case "managed container invalid port rejected" `Quick
            test_managed_container_invalid_port_rejected;
          test_case "managed container unsafe name rejected" `Quick
            test_managed_container_unsafe_name_rejected;
          test_case "managed container duplicate env key rejected" `Quick
            test_managed_container_duplicate_env_key_rejected;
        ] );
      ( "ssh identity",
        [
          test_case
            "an encrypted key with an empty passphrase is refused by name"
            `Quick test_encrypted_key_without_passphrase_refused;
          test_case "a manifest with no private key parses" `Quick
            test_manifest_with_no_private_key_parses;
        ] );
      ( "alerts",
        [
          test_case "parses alert_sinks and exit_code_severities" `Quick
            test_config_parses_alert_sinks_and_severities;
          test_case "new alert fields absent parse to None" `Quick
            test_config_new_fields_absent;
          test_case "rejects non-https sink" `Quick
            test_config_rejects_non_https_sink;
          test_case "rejects a schedule that is not a string, naming the job"
            `Quick test_config_rejects_non_string_schedule;
        ] );
    ]
