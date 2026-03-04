open Ppx_yojson_conv_lib.Yojson_conv

type component_status = {
  name : string;
  image_name : string;
  tag : string;
  status : string;
  restart_count : int option;
  created_at : string option;
}
[@@deriving yojson, show, eq]
(** Status of a single Bondi-managed component. *)

type infrastructure_status = {
  orchestrator : component_status option;
  traefik : component_status option;
}
[@@deriving yojson, show, eq]
(** Infrastructure components. *)

type comprehensive_status = {
  service : component_status option;
  cron_jobs : component_status list;
  infrastructure : infrastructure_status;
  errors : string list;
}
[@@deriving yojson, show, eq]
(** Full status response. *)

type status_context = {
  service_inspection :
    (Docker.Client.container * Docker.Client.inspect_response) option;
  orchestrator_inspection :
    (Docker.Client.container * Docker.Client.inspect_response) option;
  traefik_inspection :
    (Docker.Client.container * Docker.Client.inspect_response) option;
  scheduled_cron_jobs : Crontab.scheduled_job list;
  cron_error : string option;
}
(** Gathered state from Docker and crontab — input to the pure plan phase. *)

(** Parse an image string into (image_name, tag), falling back to the raw
    string and "unknown" if parsing fails. *)
let parse_image image =
  match Strategy.Simple.parse_image_and_tag image with
  | Ok (image_name, tag) -> (image_name, tag)
  | Error _ -> (image, "unknown")

(** Build a component_status from a Docker container + inspect response. *)
let component_of_inspection ~name
    ((_container, inspect) :
      Docker.Client.container * Docker.Client.inspect_response) ~image =
  let image_name, tag = parse_image image in
  Some
    {
      name;
      image_name;
      tag;
      status = inspect.state.status;
      restart_count = Some inspect.restart_count;
      created_at = Some inspect.created_at;
    }

(** Build a component_status for a scheduled cron job. *)
let component_of_scheduled_job (job : Crontab.scheduled_job) : component_status
    =
  let image_name, tag = parse_image job.image in
  {
    name = job.name;
    image_name;
    tag;
    status = "scheduled";
    restart_count = None;
    created_at = None;
  }

(** Pure: build a comprehensive status response from gathered context. *)
let plan ~(service_name : string option) (ctx : status_context) :
    comprehensive_status =
  let service =
    match service_name with
    | None -> None
    | Some _ -> (
        match ctx.service_inspection with
        | None -> None
        | Some ((container, _inspect) as pair) ->
            let name =
              match container.names with
              | n :: _ -> Docker.Client.normalize_container_name n
              | [] -> "unknown"
            in
            component_of_inspection ~name pair ~image:container.image)
  in
  let orchestrator =
    match ctx.orchestrator_inspection with
    | None -> None
    | Some ((container, _inspect) as pair) ->
        let name =
          match container.names with
          | n :: _ -> Docker.Client.normalize_container_name n
          | [] -> "unknown"
        in
        component_of_inspection ~name pair ~image:container.image
  in
  let traefik =
    match ctx.traefik_inspection with
    | None -> None
    | Some ((container, _inspect) as pair) ->
        let name =
          match container.names with
          | n :: _ -> Docker.Client.normalize_container_name n
          | [] -> "unknown"
        in
        component_of_inspection ~name pair ~image:container.image
  in
  let cron_jobs = List.map component_of_scheduled_job ctx.scheduled_cron_jobs in
  let errors =
    match ctx.cron_error with
    | Some e -> [ e ]
    | None -> []
  in
  { service; cron_jobs; infrastructure = { orchestrator; traefik }; errors }

(** Inspect a container by name, returning the container + inspect pair if
    found. *)
let inspect_by_name client ~net ~container_name =
  match Docker.Client.get_container_by_name client ~net ~container_name with
  | None -> None
  | Some container ->
      let inspect =
        Docker.Client.inspect_container client ~net ~container_id:container.id
      in
      Some (container, inspect)

(** Impure: inspect Docker containers and read crontab. *)
let gather ~client ~net ~(service_name : string option) : status_context =
  let service_inspection =
    match service_name with
    | None -> None
    | Some name -> inspect_by_name client ~net ~container_name:name
  in
  let orchestrator_inspection =
    inspect_by_name client ~net ~container_name:"bondi-orchestrator"
  in
  let traefik_inspection =
    inspect_by_name client ~net ~container_name:"bondi-traefik"
  in
  let scheduled_cron_jobs, cron_error =
    match Crontab.list_scheduled_jobs () with
    | Ok jobs -> (jobs, None)
    | Error msg -> ([], Some (Printf.sprintf "Failed to read crontab: %s" msg))
  in
  {
    service_inspection;
    orchestrator_inspection;
    traefik_inspection;
    scheduled_cron_jobs;
    cron_error;
  }

let route ~client ~net =
  Dream.get "/status" @@ fun req ->
  let open Lwt.Infix in
  let service_name = Dream.query req "service" in
  Lwt.catch
    (fun () ->
      (Lwt_eio.run_eio @@ fun () -> gather ~client ~net ~service_name)
      >>= fun ctx ->
      let status = plan ~service_name ctx in
      List.iter (fun e -> Dream.log "status warning: %s" e) status.errors;
      status
      |> yojson_of_comprehensive_status
      |> Yojson.Safe.to_string
      |> Dream.json)
    (fun exn ->
      Dream.respond ~status:`Internal_Server_Error (Printexc.to_string exn))
