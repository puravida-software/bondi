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
  image: registry.example.com/app:latest
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
              check string "image" "registry.example.com/app:latest"
                service.image;
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
  image: registry.example.com/app:latest
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
    image: ghcr.io/org/my-job:latest
    schedule: "0 14 * * 3"
    env_vars:
      API_KEY: "{{REGISTRY_USER}}"
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
                  check string "cron job image" "ghcr.io/org/my-job:latest"
                    job.image;
                  check string "cron job schedule" "0 14 * * 3" job.schedule;
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
    image: ghcr.io/org/cron:latest
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
                  check string "cron job image" "ghcr.io/org/cron:latest"
                    job.image;
                  check string "cron job schedule" "0 * * * *" job.schedule;
                  check string "cron job server ip" "1.2.3.4"
                    job.server.ip_address)))

let () =
  run "Config_file"
    [
      ( "read",
        [
          test_case "reads config with env vars" `Quick test_read_config_success;
          test_case "reads config with cron jobs" `Quick
            test_read_config_with_cron_jobs;
          test_case "reads cron-only config" `Quick test_read_config_cron_only;
        ] );
    ]
