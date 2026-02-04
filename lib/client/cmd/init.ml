let sample_config_yaml project_name =
  Printf.sprintf
    {|service:
  image_name: %s
  port: 8080
  registry_user: "{{REGISTRY_USER}}"
  registry_pass: "{{REGISTRY_PASS}}"
  env_vars:
    ENV: "prod"
  servers:
    - ip_address: "55.55.55.55"
      ssh:
        user: root
        private_key_contents: "{{SSH_PRIVATE_KEY_CONTENTS}}"
        private_key_pass: "{{SSH_PRIVATE_KEY_PASS}}"
    - ip_address: "55.55.55.56"
      ssh:
        user: root
        private_key_contents: "{{SSH_PRIVATE_KEY_CONTENTS}}"
        private_key_pass: "{{SSH_PRIVATE_KEY_PASS}}"

bondi_server:
  version: 0.0.0

traefik:
  domain_name: example.com
  image: traefik:v3.3.0
  acme_email: john.doe@example.com
|}
    project_name

let write_file path contents =
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () -> output_string oc contents)

let run () =
  if Sys.file_exists Config_file.config_file_name then (
    print_endline "Bondi already initialised, nothing else to do!";
    exit 0);
  print_endline "Initialising Bondi!";
  let folder =
    try Filename.basename (Sys.getcwd ()) with
    | exn ->
        prerr_endline
          ("Error getting working directory: " ^ Printexc.to_string exn);
        exit 1
  in
  let config = sample_config_yaml folder in
  try
    write_file Config_file.config_file_name config;
    print_endline "Bondi initialised successfully!"
  with
  | exn ->
      prerr_endline ("Error writing config file: " ^ Printexc.to_string exn);
      exit 1

let cmd =
  let term = Cmdliner.Term.(const run $ const ()) in
  let info = Cmdliner.Cmd.info "init" ~doc:"Initialize Bondi configuration." in
  Cmdliner.Cmd.v info term
