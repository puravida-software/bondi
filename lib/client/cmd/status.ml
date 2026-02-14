open Ppx_yojson_conv_lib.Yojson_conv

type container_status = {
  image_name : string;
  tag : string;
  created_at : string;
  restart_count : int;
  status : string;
}
[@@deriving yojson]

let read_body_string body =
  Eio.Buf_read.(of_flow ~max_size:max_int body |> take_all)

let fetch_status ~client ip_address ~service_name =
  let url =
    Printf.sprintf "http://%s:3030/api/v1/status?service=%s" ip_address
      (Uri.pct_encode ~component:`Query service_name)
  in
  let uri = Uri.of_string url in
  try
    let resp, body =
      Eio.Switch.run (fun sw -> Cohttp_eio.Client.get ~sw client uri)
    in
    let status = Cohttp.Response.status resp in
    let body_str = read_body_string body in
    match status with
    | `Not_found -> Ok None
    | `OK -> (
        try
          let json = Yojson.Safe.from_string body_str in
          Ok (Some (container_status_of_yojson json))
        with
        | Ppx_yojson_conv_lib.Yojson_conv.Of_yojson_error (exn, _) ->
            Error
              (Printf.sprintf "Error decoding response from server %s: %s"
                 ip_address (Printexc.to_string exn))
        | exn ->
            Error
              (Printf.sprintf "Error decoding response from server %s: %s"
                 ip_address (Printexc.to_string exn)))
    | _ ->
        Error
          (Printf.sprintf "Non-OK response from server %s: %s" ip_address
             body_str)
  with
  | exn ->
      Error
        (Printf.sprintf "Error calling status endpoint on server %s: %s"
           ip_address (Printexc.to_string exn))

let run () =
  match Config_file.read () with
  | Error message ->
      prerr_endline ("Error reading configuration: " ^ message);
      exit 1
  | Ok config -> (
      match config.user_service with
      | None ->
          prerr_endline
            "Error: no service configured. Status requires a service.";
          exit 1
      | Some service ->
          Eio_main.run @@ fun env ->
          let net = Eio.Stdenv.net env in
          let client = Cohttp_eio.Client.make ~https:None net in
          let status_per_server =
            List.fold_left
              (fun acc (server : Config_file.server) ->
                match
                  fetch_status ~client server.ip_address
                    ~service_name:service.name
                with
                | Ok None ->
                    print_endline "Status: Container not found";
                    acc
                | Ok (Some status) -> (server.ip_address, status) :: acc
                | Error message ->
                    prerr_endline message;
                    acc)
              []
              (Config_file.servers config)
            |> List.rev
          in
          let json =
            `Assoc
              (List.map
                 (fun (ip, status) -> (ip, yojson_of_container_status status))
                 status_per_server)
          in
          print_endline (Yojson.Safe.pretty_to_string json))

let cmd =
  let term = Cmdliner.Term.(const run $ const ()) in
  let info =
    Cmdliner.Cmd.info "status"
      ~doc:
        "Get the status of the deployed service container on all configured \
         servers."
  in
  Cmdliner.Cmd.v info term
