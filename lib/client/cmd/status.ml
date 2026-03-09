(** Output format for the status command. *)
type output_format = Table | Json

type component_status = {
  name : string;
  image_name : string;
  tag : string;
  status : string;
  restart_count : int option; [@default None]
  created_at : string option; [@default None]
}
[@@deriving yojson]
(** Status of a single Bondi-managed component. *)

type infrastructure_status = {
  orchestrator : component_status option; [@default None]
  traefik : component_status option; [@default None]
  alloy : component_status option; [@default None]
}
[@@deriving yojson]
(** Infrastructure components. *)

type comprehensive_status = {
  service : component_status option; [@default None]
  cron_jobs : component_status list;
  infrastructure : infrastructure_status;
  errors : string list;
}
[@@deriving yojson]
(** Full status response. *)

module StringSet = Set.Make (String)

(** Format a component status row for table output. *)
let format_row (c : component_status) =
  let restarts =
    match c.restart_count with
    | Some n -> string_of_int n
    | None -> "N/A"
  in
  let created =
    match c.created_at with
    | Some s -> s
    | None -> "-"
  in
  Printf.sprintf "  %-22s %-35s %-12s %-12s %-10s %s" c.name c.image_name c.tag
    c.status restarts created

(** Format a "not found" row for table output. *)
let not_found_row name =
  Printf.sprintf "  %-22s %-35s %-12s %-12s %-10s %s" name "-" "-" "not found"
    "-" "-"

(** Table column header line. *)
let table_header =
  Printf.sprintf "  %-22s %-35s %-12s %-12s %-10s %s" "NAME" "IMAGE" "TAG"
    "STATUS" "RESTARTS" "CREATED"

(** Render the service section lines. Returns empty list if no service
    configured. *)
let service_section ~(config : Config_file.t) (status : comprehensive_status) =
  match config.user_service with
  | None -> []
  | Some svc ->
      let row =
        match status.service with
        | Some s -> format_row s
        | None -> not_found_row svc.name
      in
      [ "Service"; table_header; row; "" ]

(** Render the cron jobs section lines. Returns empty list if no cron jobs
    configured. *)
let cron_jobs_section ~(config_cron_names : string list)
    (status : comprehensive_status) =
  match config_cron_names with
  | [] -> []
  | _ ->
      let found_names =
        List.fold_left
          (fun s (c : component_status) -> StringSet.add c.name s)
          StringSet.empty status.cron_jobs
      in
      let found_rows =
        List.map (fun (c : component_status) -> format_row c) status.cron_jobs
      in
      let missing_rows =
        List.filter_map
          (fun name ->
            if StringSet.mem name found_names then None
            else Some (not_found_row name))
          config_cron_names
      in
      [ "Cron Jobs"; table_header ] @ found_rows @ missing_rows @ [ "" ]

(** Render the infrastructure section lines. *)
let infrastructure_section (status : comprehensive_status) =
  let orch_row =
    match status.infrastructure.orchestrator with
    | Some c -> format_row c
    | None -> not_found_row "bondi-orchestrator"
  in
  let traefik_row =
    match status.infrastructure.traefik with
    | Some c -> format_row c
    | None -> not_found_row "bondi-traefik"
  in
  let alloy_row =
    match status.infrastructure.alloy with
    | Some c -> [ format_row c ]
    | None -> []
  in
  [ "Infrastructure"; table_header; orch_row; traefik_row ] @ alloy_row @ [ "" ]

(** Render the warnings section lines. Returns empty list if no errors. *)
let warnings_section (status : comprehensive_status) =
  match status.errors with
  | [] -> []
  | errors ->
      ("Warnings" :: List.map (fun e -> Printf.sprintf "  %s" e) errors)
      @ [ "" ]

(** Pure: render status results as a human-readable table. Adds "not found" rows
    for components in config but missing from the server response (REQ-F8). *)
let format_table ~(config : Config_file.t)
    (results : (string * comprehensive_status) list) =
  let config_cron_names =
    match config.cron_jobs with
    | Some jobs -> List.map (fun (j : Config_file.cron_job) -> j.name) jobs
    | None -> []
  in
  let lines =
    List.concat_map
      (fun (ip, status) ->
        [ Printf.sprintf "Server: %s" ip; "" ]
        @ service_section ~config status
        @ cron_jobs_section ~config_cron_names status
        @ infrastructure_section status
        @ warnings_section status)
      results
  in
  String.concat "\n" lines

(** Pure: render status results as JSON. *)
let format_json (results : (string * comprehensive_status) list) =
  let json =
    `Assoc
      (List.map
         (fun (ip, status) -> (ip, comprehensive_status_to_yojson status))
         results)
  in
  Yojson.Safe.pretty_to_string json

let read_body_string body =
  Eio.Buf_read.(of_flow ~max_size:max_int body |> take_all)

let fetch_status ~client ip_address ~service_name =
  let base_url = Printf.sprintf "http://%s:3030/api/v1/status" ip_address in
  let url =
    match service_name with
    | None -> base_url
    | Some name ->
        Printf.sprintf "%s?service=%s" base_url
          (Uri.pct_encode ~component:`Query name)
  in
  let uri = Uri.of_string url in
  try
    let resp, body =
      Eio.Switch.run (fun sw -> Cohttp_eio.Client.get ~sw client uri)
    in
    let status = Cohttp.Response.status resp in
    let body_str = read_body_string body in
    match status with
    | `OK ->
        let json = Yojson.Safe.from_string body_str in
        comprehensive_status_of_yojson json
        |> Result.map_error (fun msg ->
            Printf.sprintf "error decoding status response from server %s: %s"
              ip_address msg)
    | _ ->
        Error
          (Printf.sprintf "Non-OK response from server %s: %s" ip_address
             body_str)
  with
  | exn ->
      Error
        (Printf.sprintf "Error calling status endpoint on server %s: %s"
           ip_address (Printexc.to_string exn))

let run output_format () =
  match Config_file.read () with
  | Error message ->
      prerr_endline ("Error reading configuration: " ^ message);
      exit 1
  | Ok config ->
      let service_name =
        match config.user_service with
        | Some service -> Some service.name
        | None -> None
      in
      Eio_main.run @@ fun env ->
      let net = Eio.Stdenv.net env in
      let client = Cohttp_eio.Client.make ~https:None net in
      let status_per_server =
        List.fold_left
          (fun acc (server : Config_file.server) ->
            match fetch_status ~client server.ip_address ~service_name with
            | Ok status -> (server.ip_address, status) :: acc
            | Error message ->
                prerr_endline message;
                acc)
          []
          (Config_file.servers config)
        |> List.rev
      in
      let output =
        match output_format with
        | Table -> format_table ~config status_per_server
        | Json -> format_json status_per_server
      in
      if output <> "" then print_string output

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
