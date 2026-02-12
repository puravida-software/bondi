open Ppx_yojson_conv_lib.Yojson_conv

(* Cron job for deploy payload - excludes server (server filters which jobs to send per target) *)
type deploy_cron_job = {
  name : string;
  image : string;
  schedule : string;
  env_vars : Config_file.string_map option;
}
[@@deriving yojson]

type deploy_payload = {
  image_name : string;
  tag : string;
  port : int;
  env_vars : Config_file.string_map;
  traefik_domain_name : string option;
  traefik_image : string option;
  traefik_acme_email : string option;
  registry_user : string option;
  registry_pass : string option;
  force_traefik_redeploy : bool option;
  cron_jobs : deploy_cron_job list option;
}
[@@deriving yojson]

let read_body_string body =
  Eio.Buf_read.(of_flow ~max_size:max_int body |> take_all)

let post_deploy ~client ip_address payload =
  let url = Printf.sprintf "http://%s:3030/api/v1/deploy" ip_address in
  let uri = Uri.of_string url in
  let headers = Cohttp.Header.init_with "Content-Type" "application/json" in
  let body_str = payload |> yojson_of_deploy_payload |> Yojson.Safe.to_string in
  let body = Cohttp_eio.Body.of_string body_str in
  try
    let response, response_body =
      Eio.Switch.run (fun sw ->
          Cohttp_eio.Client.post ~sw ~headers ~body client uri)
    in
    let status = Cohttp.Response.status response in
    let response_body_str = read_body_string response_body in
    match status with
    | `OK -> Ok ()
    | _ ->
        Error
          (Printf.sprintf "Non-OK response from server %s: %s" ip_address
             response_body_str)
  with
  | exn ->
      Error
        (Printf.sprintf "Error calling deploy endpoint on server %s: %s"
           ip_address (Printexc.to_string exn))

let cron_job_to_deploy (j : Config_file.cron_job) : deploy_cron_job =
  { name = j.name; image = j.image; schedule = j.schedule; env_vars = j.env_vars }

let cron_jobs_for_server ip_address (cron_jobs : Config_file.cron_job list option)
    : deploy_cron_job list option =
  match cron_jobs with
  | None -> None
  | Some jobs ->
      let filtered =
        List.filter
          (fun (j : Config_file.cron_job) ->
            j.server.ip_address = ip_address)
          jobs
      in
      if filtered = [] then None else Some (List.map cron_job_to_deploy filtered)

let run tag force_traefik_redeploy =
  print_endline "Deployment process initiated...";
  match Config_file.read () with
  | Error message ->
      prerr_endline ("Error reading configuration: " ^ message);
      exit 1
  | Ok config -> (
      let servers = Config_file.servers config in
      if servers = [] then (
        prerr_endline
          "Error: no servers configured. Add servers to bondi.yaml under \
           service or each cron job.";
        exit 1);
      Eio_main.run @@ fun env ->
      let net = Eio.Stdenv.net env in
      let client = Cohttp_eio.Client.make ~https:None net in
      let results =
        List.map
          (fun server ->
            let ip_address = server.Config_file.ip_address in
            let base_payload =
              match config.user_service with
              | Some service ->
                  {
                    image_name = service.image_name;
                    tag;
                    port = service.port;
                    env_vars = service.env_vars;
                    traefik_domain_name =
                      Option.map
                        (fun (tr : Config_file.traefik) -> tr.domain_name)
                        config.traefik;
                    traefik_image =
                      Option.map (fun (tr : Config_file.traefik) -> tr.image)
                        config.traefik;
                    traefik_acme_email =
                      Option.map
                        (fun (tr : Config_file.traefik) -> tr.acme_email)
                        config.traefik;
                    registry_user = service.registry_user;
                    registry_pass = service.registry_pass;
                    force_traefik_redeploy = Some force_traefik_redeploy;
                    cron_jobs = cron_jobs_for_server ip_address config.cron_jobs;
                  }
              | None ->
                  {
                    image_name = "cron-only";
                    tag;
                    port = 0;
                    env_vars = [];
                    traefik_domain_name = None;
                    traefik_image = None;
                    traefik_acme_email = None;
                    registry_user = None;
                    registry_pass = None;
                    force_traefik_redeploy = Some force_traefik_redeploy;
                    cron_jobs = cron_jobs_for_server ip_address config.cron_jobs;
                  }
            in
            print_endline
              (Printf.sprintf
                 "Deploying to server: %s at http://%s:3030/api/v1/deploy"
                 ip_address ip_address);
            post_deploy ~client ip_address base_payload)
          servers
      in
      match
        List.find_opt
          (function
            | Error _ -> true
            | Ok () -> false)
          results
      with
      | Some (Error message) ->
          prerr_endline message;
          exit 1
      | _ ->
          List.iter
            (fun server ->
              print_endline
                (Printf.sprintf "Deployment initiated on server %s"
                   server.Config_file.ip_address))
            servers)

let tag_arg =
  let doc = "Deployment tag." in
  Cmdliner.Arg.(required & pos 0 (some string) None & info [] ~docv:"TAG" ~doc)

let force_traefik_redeploy_arg =
  let doc = "Force Traefik to be redeployed to pick up config changes." in
  Cmdliner.Arg.(value & flag & info [ "redeploy-traefik" ] ~doc)

let cmd =
  let term = Cmdliner.Term.(const run $ tag_arg $ force_traefik_redeploy_arg) in
  let info = Cmdliner.Cmd.info "deploy" ~doc:"Deploy a tagged release." in
  Cmdliner.Cmd.v info term
