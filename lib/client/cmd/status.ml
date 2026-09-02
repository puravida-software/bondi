type output_format = Table | Json

let read_body_string body =
  Eio.Buf_read.(of_flow ~max_size:max_int body |> take_all)

(* A fixed bound on one request to one orchestrator, not user configuration. A
   host that refuses the connection answers at once; one that drops the packets
   — a firewalled port is an ordinary way for "the orchestrator is down" to
   present — answers never, and this call has no deadline of its own. Both
   commands that make it print a report at the end of their work, so an
   unbounded wait here is the report being lost on exactly the failure it exists
   to describe. *)
let fetch_timeout_seconds = 10.0

let fetch_status ~clock ~client ip_address ~port ~service_name =
  let base_url = Printf.sprintf "http://%s:%d/api/v1/status" ip_address port in
  let url =
    match service_name with
    | None -> base_url
    | Some name ->
        Printf.sprintf "%s?service=%s" base_url
          (Uri.pct_encode ~component:`Query name)
  in
  let uri = Uri.of_string url in
  try
    (* The body is read inside the bound as well as the request: a server that
       accepts the connection and then stalls part-way through its response
       holds the reader open just as long as one that never answers. *)
    let status, body_str =
      Eio.Time.with_timeout_exn clock fetch_timeout_seconds (fun () ->
          let resp, body =
            Eio.Switch.run (fun sw -> Cohttp_eio.Client.get ~sw client uri)
          in
          (Cohttp.Response.status resp, read_body_string body))
    in
    match status with
    | `OK -> Orchestrator_status.reading_of_body ~ip_address body_str
    | _ ->
        (* The server answered, and what it answered with is the evidence. This
           is not a source that could not be reached. *)
        Error
          (Status_report.Not_understood
             (Printf.sprintf "%s answered %s: %s" ip_address
                (Cohttp.Code.string_of_status status)
                body_str))
  with
  (* Named before the catch-all so the bound reports itself in its own words:
     the exception's name says nothing an operator can act on, and "took too
     long" is a different instruction from "refused the connection". *)
  | Eio.Time.Timeout ->
      Error
        (Status_report.Not_consulted
           (Printf.sprintf "server %s did not answer within %.0f seconds"
              ip_address fetch_timeout_seconds))
  (* Re-raised rather than caught. A cancellation is the caller withdrawing the
     question, not the server failing to answer it, and turning one into a cell
     in the report is how Ctrl-C comes to print a table instead of stopping. *)
  | Eio.Cancel.Cancelled _ as cancelled -> raise cancelled
  | exn ->
      Error
        (Status_report.Not_consulted
           (Printf.sprintf "Error calling status endpoint on server %s: %s"
              ip_address (Printexc.to_string exn)))

(* Same reasoning as the deploy path: the orchestrator answers on loopback only,
   so a status read from another machine goes through a forwarded port. A server
   declared without [ssh] is dialled directly -- correct for localhost and for a
   tunnel the operator opened themselves.

   A tunnel that never came up is [Not_consulted], not [Not_understood]: nothing
   was obtained from the box at all, and the distinction is what tells an
   operator whether to look at their key or at the orchestrator. *)
let orchestrator_reading ~clock ~client ~service_name
    (server : Config_file.server) =
  let port =
    Option.value ~default:Bondi_common.Defaults.server_port server.port
  in
  (* A loopback address is the box itself: the published port is already
     reachable and forwarding loopback to loopback buys nothing. *)
  match
    if Bondi_common.Net.is_loopback server.ip_address then None else server.ssh
  with
  | None -> fetch_status ~clock ~client server.ip_address ~port ~service_name
  | Some ssh -> (
      match
        Ssh_tunnel.with_tunnel ~ssh ~host:server.ip_address ~remote_port:port
          (fun local_port ->
            Ok
              (fetch_status ~clock ~client "127.0.0.1" ~port:local_port
                 ~service_name))
      with
      | Ok reading -> reading
      | Error msg ->
          Error
            (Status_report.Not_consulted
               (Printf.sprintf "%s: %s" server.ip_address msg)))

let orchestrator_reading_standalone ~service_name server =
  Eio_main.run @@ fun env ->
  orchestrator_reading ~clock:(Eio.Stdenv.clock env)
    ~client:(Cohttp_eio.Client.make ~https:None (Eio.Stdenv.net env))
    ~service_name server

let run output_format () =
  match Config_file.read () with
  | Error message ->
      prerr_endline ("Error reading configuration: " ^ message);
      exit 1
  | Ok config -> (
      let service_name =
        match config.user_service with
        | Some service -> Some service.name
        | None -> None
      in
      Eio_main.run @@ fun env ->
      let net = Eio.Stdenv.net env in
      let client = Cohttp_eio.Client.make ~https:None net in
      let reports =
        List.map
          (fun (server : Config_file.server) ->
            (* This command reports a health state and never waits for one: a
               wait costs a bound per component, and an operator asking what is
               running is not asking anyone to hold still while it settles. *)
            Status_gather.report_of_reading ~config ~address:server.ip_address
              ~waits:[]
              (Status_gather.gather
                 ~fetch:
                   (orchestrator_reading ~clock:(Eio.Stdenv.clock env) ~client
                      ~service_name)
                 server))
          (Config_file.servers config)
      in
      let output =
        match output_format with
        | Table -> Status_report.render_table reports
        | Json -> Status_report.render_json reports
      in
      match String.equal output "" with
      | true -> ()
      | false -> print_string output)

let output_format_arg =
  let formats = [ ("json", Json); ("table", Table) ] in
  let doc = "Output format. $(docv) must be $(b,json) or $(b,table)." in
  Cmdliner.Arg.(
    value & opt (enum formats) Table & info [ "output" ] ~docv:"VAL" ~doc)

let cmd =
  let term = Cmdliner.Term.(const run $ output_format_arg $ const ()) in
  let info =
    Cmdliner.Cmd.info "status"
      ~doc:"Get the status of deployed components on all configured servers."
  in
  Cmdliner.Cmd.v info term
