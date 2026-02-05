open Ppx_yojson_conv_lib.Yojson_conv

type deploy_payload = {
  image_name : string;
  tag : string;
  port : int;
  env_vars : Config_file.string_map;
  traefik_domain_name : string;
  traefik_image : string;
  traefik_acme_email : string;
  registry_user : string option;
  registry_pass : string option;
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

let run tag =
  print_endline "Deployment process initiated...";
  match Config_file.read () with
  | Error message ->
      prerr_endline ("Error reading configuration: " ^ message);
      exit 1
  | Ok config -> (
      let payload =
        {
          image_name = config.user_service.image_name;
          tag;
          port = config.user_service.port;
          env_vars = config.user_service.env_vars;
          traefik_domain_name = config.traefik.domain_name;
          traefik_image = config.traefik.image;
          traefik_acme_email = config.traefik.acme_email;
          registry_user = config.user_service.registry_user;
          registry_pass = config.user_service.registry_pass;
        }
      in
      Eio_main.run @@ fun env ->
      let net = Eio.Stdenv.net env in
      let client = Cohttp_eio.Client.make ~https:None net in
      let results =
        List.map
          (fun server ->
            let ip_address = server.Config_file.ip_address in
            print_endline
              (Printf.sprintf
                 "Deploying to server: %s at http://%s:3030/api/v1/deploy"
                 ip_address ip_address);
            post_deploy ~client ip_address payload)
          config.user_service.servers
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
            config.user_service.servers)

let tag_arg =
  let doc = "Deployment tag." in
  Cmdliner.Arg.(required & pos 0 (some string) None & info [] ~docv:"TAG" ~doc)

let cmd =
  let term = Cmdliner.Term.(const run $ tag_arg) in
  let info = Cmdliner.Cmd.info "deploy" ~doc:"Deploy a tagged release." in
  Cmdliner.Cmd.v info term
