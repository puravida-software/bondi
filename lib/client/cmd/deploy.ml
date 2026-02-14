open Ppx_yojson_conv_lib.Yojson_conv

(* Cron job for deploy payload - excludes server (server filters which jobs to send per target) *)
type deploy_cron_job = {
  name : string;
  image : string;
  schedule : string;
  env_vars : Config_file.string_map option;
  registry_user : string option;
  registry_pass : string option;
}
[@@deriving yojson]

type deploy_payload = {
  service_name : string option;
  image : string; (* Full image string including tag *)
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

let parse_name_tag s : (string * string, string) result =
  match String.split_on_char ':' s with
  | [] -> Error "missing tag (expected name:tag)"
  | [ _ ] -> Error "missing tag (expected name:tag)"
  | name :: tag_parts ->
      let tag = String.concat ":" tag_parts in
      if tag = "" then Error "missing tag (expected name:tag)"
      else Ok (name, tag)

let cron_job_to_deploy (j : Config_file.cron_job) ~image : deploy_cron_job =
  {
    name = j.name;
    image;
    schedule = j.schedule;
    env_vars = j.env_vars;
    registry_user = j.registry_user;
    registry_pass = j.registry_pass;
  }

let cron_jobs_for_server ip_address
    (cron_jobs : Config_file.cron_job list option)
    (deployments : (string * string) list) : deploy_cron_job list option =
  let tag_of_name name = List.assoc_opt name deployments in
  match cron_jobs with
  | None -> None
  | Some jobs ->
      let filtered =
        List.filter
          (fun (j : Config_file.cron_job) -> j.server.ip_address = ip_address)
          jobs
      in
      let with_tags =
        List.filter_map
          (fun (j : Config_file.cron_job) ->
            match tag_of_name j.name with
            | Some tag ->
                Some (cron_job_to_deploy j ~image:(j.image ^ ":" ^ tag))
            | None -> None)
          filtered
      in
      if with_tags = [] then None else Some with_tags

let validate_deployments (config : Config_file.t) deployments :
    ((string * string) list, string) result =
  let service_names =
    match config.user_service with
    | Some s -> [ s.name ]
    | None -> []
  in
  let cron_names =
    match config.cron_jobs with
    | Some jobs -> List.map (fun (j : Config_file.cron_job) -> j.name) jobs
    | None -> []
  in
  let valid_names = service_names @ cron_names in
  let check (name, _tag) =
    if List.mem name valid_names then None
    else Some (Printf.sprintf "Unknown deployment target: %s" name)
  in
  match List.find_map check deployments with
  | Some msg -> Error msg
  | None -> Ok deployments

let run force_traefik_redeploy deployments =
  print_endline "Deployment process initiated...";
  let deployments =
    match deployments with
    | [] ->
        prerr_endline
          "Error: no deployments specified. Use name:tag (e.g. \
           my-service:v1.2.3)";
        exit 1
    | _ -> (
        match
          List.fold_left
            (fun acc s ->
              match acc with
              | Error _ -> acc
              | Ok acc -> (
                  match parse_name_tag s with
                  | Error msg ->
                      prerr_endline ("Error: " ^ msg);
                      exit 1
                  | Ok pair -> Ok (pair :: acc)))
            (Ok []) deployments
        with
        | Error _ -> exit 1
        | Ok parsed -> List.rev parsed)
  in
  match Config_file.read () with
  | Error message ->
      prerr_endline ("Error reading configuration: " ^ message);
      exit 1
  | Ok config -> (
      (match validate_deployments config deployments with
      | Error msg ->
          prerr_endline msg;
          exit 1
      | Ok _ -> ());
      let servers = Config_file.servers config in
      if servers = [] then (
        prerr_endline
          "Error: no servers configured. Add servers to bondi.yaml under \
           service or each cron job.";
        exit 1);
      Eio_main.run @@ fun env ->
      let net = Eio.Stdenv.net env in
      let client = Cohttp_eio.Client.make ~https:None net in
      let tag_of_name name = List.assoc_opt name deployments in
      let is_service_server ip =
        match config.user_service with
        | Some s ->
            List.exists
              (fun (x : Config_file.server) -> x.ip_address = ip)
              s.servers
        | None -> false
      in
      let results =
        List.map
          (fun (server : Config_file.server) ->
            let ip_address = server.ip_address in
            let deploy_service =
              match config.user_service with
              | Some service
                when is_service_server ip_address
                     && Option.is_some (tag_of_name service.name) ->
                  true
              | _ -> false
            in
            let base_payload =
              if deploy_service then
                let service = Option.get config.user_service in
                let tag = Option.get (tag_of_name service.name) in
                {
                  service_name = Some service.name;
                  image = service.image ^ ":" ^ tag;
                  port = service.port;
                  env_vars = service.env_vars;
                  traefik_domain_name =
                    Option.map
                      (fun (tr : Config_file.traefik) -> tr.domain_name)
                      config.traefik;
                  traefik_image =
                    Option.map
                      (fun (tr : Config_file.traefik) -> tr.image)
                      config.traefik;
                  traefik_acme_email =
                    Option.map
                      (fun (tr : Config_file.traefik) -> tr.acme_email)
                      config.traefik;
                  registry_user = service.registry_user;
                  registry_pass = service.registry_pass;
                  force_traefik_redeploy = Some force_traefik_redeploy;
                  cron_jobs =
                    cron_jobs_for_server ip_address config.cron_jobs deployments;
                }
              else
                {
                  service_name = None;
                  image = "cron-only:latest";
                  port = 0;
                  env_vars = [];
                  traefik_domain_name = None;
                  traefik_image = None;
                  traefik_acme_email = None;
                  registry_user = None;
                  registry_pass = None;
                  force_traefik_redeploy = Some force_traefik_redeploy;
                  cron_jobs =
                    cron_jobs_for_server ip_address config.cron_jobs deployments;
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
            (fun (server : Config_file.server) ->
              print_endline
                (Printf.sprintf "Deployment initiated on server %s"
                   server.ip_address))
            servers)

let force_traefik_redeploy_arg =
  let doc = "Force Traefik to be redeployed to pick up config changes." in
  Cmdliner.Arg.(value & flag & info [ "redeploy-traefik" ] ~doc)

let deployments_arg =
  let doc = "Deployments as name:tag (e.g. my-service:v1.2.3 backup:v2)." in
  Cmdliner.Arg.(value & pos_all string [] & info [] ~docv:"NAME:TAG" ~doc)

let cmd =
  let term =
    Cmdliner.Term.(const run $ force_traefik_redeploy_arg $ deployments_arg)
  in
  let info =
    Cmdliner.Cmd.info "deploy"
      ~doc:"Deploy services and cron jobs. Specify name:tag for each target."
  in
  Cmdliner.Cmd.v info term
