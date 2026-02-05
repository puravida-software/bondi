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
  image_name: registry.example.com/app
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
          check string "image name" "registry.example.com/app"
            config.user_service.image_name;
          check int "port" 8080 config.user_service.port;
          check (option string) "registry user" (Some "registry-user")
            config.user_service.registry_user;
          check (option string) "registry pass" (Some "registry-pass")
            config.user_service.registry_pass;
          check
            (list (pair string string))
            "env vars"
            [ ("DATABASE_URL", "postgres://example") ]
            config.user_service.env_vars;
          check int "server count" 1 (List.length config.user_service.servers);
          (match config.user_service.servers with
          | [] -> fail "expected at least one server"
          | server :: _ -> (
              check string "server ip" "1.2.3.4" server.ip_address;
              match server.ssh with
              | None -> fail "expected ssh config"
              | Some ssh ->
                  check string "ssh user" "root" ssh.user;
                  check string "ssh key" "ssh-key" ssh.private_key_contents;
                  check string "ssh pass" "ssh-pass" ssh.private_key_pass));
          check string "bondi version" "0.1.0" config.bondi_server.version;
          check string "traefik domain" "example.com" config.traefik.domain_name;
          check string "traefik image" "traefik:v3.3.3" config.traefik.image;
          check string "traefik email" "admin@example.com"
            config.traefik.acme_email)

let () =
  run "Config_file"
    [
      ( "read",
        [
          test_case "reads config with env vars" `Quick test_read_config_success;
        ] );
    ]
