type component_status = {
  name : string;
  image_name : string;
  tag : string;
  status : string;
  restart_count : int option; [@default None]
  created_at : string option; [@default None]
}
[@@deriving yojson, show, eq]
(** Status of a single Bondi-managed component. *)

type infrastructure_status = {
  orchestrator : component_status option; [@default None]
  traefik : component_status option; [@default None]
  alloy : component_status option; [@default None]
  managed : component_status list; [@default []]
}
[@@deriving yojson, show, eq]
(** Infrastructure components. *)

type comprehensive_status = {
  service : component_status option; [@default None]
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
  cron_container_inspections : (string * Docker.Client.inspect_response) list;
  cron_error : string option;
  alloy_inspection :
    (Docker.Client.container * Docker.Client.inspect_response) option;
  managed_inspections :
    (Docker.Client.container * Docker.Client.inspect_response) list;
  managed_error : string option;
}
(** Gathered state from Docker and crontab — input to the pure plan phase. *)

(** Parse an image string into (image_name, tag). Returns Error when parsing
    fails. *)
let parse_image image =
  match Strategy.Simple.parse_image_and_tag image with
  | Ok (image_name, tag) -> Ok (image_name, tag)
  | Error _ -> Error (Printf.sprintf "failed to parse image: %s" image)

(** Build a component_status from a Docker container + inspect response. Returns
    (Some status, None) on success, or (None, Some error) on parse failure. *)
let component_of_inspection ~name
    ((_container, inspect) :
      Docker.Client.container * Docker.Client.inspect_response) ~image =
  match parse_image image with
  | Ok (image_name, tag) ->
      ( Some
          {
            name;
            image_name;
            tag;
            status = inspect.state.status;
            restart_count = Some inspect.restart_count;
            created_at = Some inspect.created_at;
          },
        None )
  | Error msg -> (None, Some msg)

let container_display_name (container : Docker.Client.container) =
  match container.names with
  | n :: _ -> Ok (Docker.Client.normalize_container_name n)
  | [] -> Error (Printf.sprintf "container %s has no name" container.id)

(** Derive cron job status from a container's inspect state. Maps "exited" with
    exit code 0 to "completed", non-zero to "failed (exit N)". Unknown statuses
    (e.g. "dead", "paused") are passed through as-is. *)
let cron_status_of_inspect (state : Docker.Client.inspect_state) : string =
  match state.status with
  | "exited" when state.exit_code = 0 -> "completed"
  | "exited" -> Printf.sprintf "failed (exit %d)" state.exit_code
  | s -> s

(** Build a component_status for a scheduled cron job, optionally using
    container inspect data if available. Returns (Some status, None) on success,
    or (None, Some error) on parse failure. *)
let component_of_scheduled_job
    ~(inspections : (string * Docker.Client.inspect_response) list)
    (job : Crontab.scheduled_job) =
  match parse_image job.image with
  | Ok (image_name, tag) ->
      let status =
        match List.assoc_opt job.name inspections with
        | Some inspect -> cron_status_of_inspect inspect.state
        | None -> "scheduled"
      in
      ( Some
          {
            name = job.name;
            image_name;
            tag;
            status;
            restart_count = None;
            created_at = None;
          },
        None )
  | Error msg -> (None, Some msg)

(** Extract a component from an inspection pair, collecting errors. *)
let extract_component inspection =
  match inspection with
  | None -> (None, [])
  | Some ((container, _inspect) as pair) -> (
      match container_display_name container with
      | Error msg -> (None, [ msg ])
      | Ok name ->
          let component, err =
            component_of_inspection ~name pair ~image:container.image
          in
          (component, Option.to_list err))

(** Select the managed containers from a Docker listing. Discovery is by label
    because the server never reads [bondi.yaml] and so cannot know the declared
    names. *)
let managed_containers_of (containers : Docker.Client.container list) =
  let label_key, label_value = Bondi_common.Managed_container.type_label in
  List.filter
    (fun (container : Docker.Client.container) ->
      match container.labels with
      | None -> false
      | Some labels -> List.assoc_opt label_key labels = Some label_value)
    containers

(** Pure: build a comprehensive status response from gathered context. *)
let plan ~(service_name : string option) (ctx : status_context) :
    comprehensive_status =
  let errors = ref [] in
  let add_errors errs = errors := !errors @ errs in
  let service =
    match service_name with
    | None -> None
    | Some _ ->
        let component, errs = extract_component ctx.service_inspection in
        add_errors errs;
        component
  in
  let orchestrator, orch_errs = extract_component ctx.orchestrator_inspection in
  add_errors orch_errs;
  let traefik, traefik_errs = extract_component ctx.traefik_inspection in
  add_errors traefik_errs;
  let alloy, alloy_errs = extract_component ctx.alloy_inspection in
  add_errors alloy_errs;
  let cron_jobs =
    List.filter_map
      (fun job ->
        let component, err =
          component_of_scheduled_job ~inspections:ctx.cron_container_inspections
            job
        in
        (match err with
        | Some msg -> add_errors [ msg ]
        | None -> ());
        component)
      ctx.scheduled_cron_jobs
  in
  let managed =
    List.filter_map
      (fun inspection ->
        let component, errs = extract_component (Some inspection) in
        add_errors errs;
        component)
      ctx.managed_inspections
  in
  (match ctx.cron_error with
  | Some e -> add_errors [ e ]
  | None -> ());
  (match ctx.managed_error with
  | Some e -> add_errors [ e ]
  | None -> ());
  {
    service;
    cron_jobs;
    infrastructure = { orchestrator; traefik; alloy; managed };
    errors = !errors;
  }

(** Inspect a container by name, returning the container + inspect pair if
    found. *)
let inspect_by_name client ~net ~clock ~container_name =
  match Docker.Client.get_container_by_name client ~net ~container_name with
  | Error msg ->
      Diagnostics.write
        (Printf.sprintf "failed to look up container %s: %s" container_name msg);
      None
  | Ok None -> None
  | Ok (Some container) -> (
      match
        Docker.Client.inspect_container client ~net ~clock
          ~container_id:container.id
      with
      | Ok inspect -> Some (container, inspect)
      | Error msg ->
          Diagnostics.write
            (Printf.sprintf "failed to inspect container %s: %s" container_name
               msg);
          None)

(** Impure: inspect Docker containers and read crontab. *)
let gather ~client ~net ~clock ~(service_name : string option) : status_context
    =
  let service_inspection =
    match service_name with
    | None -> None
    | Some name -> inspect_by_name client ~net ~clock ~container_name:name
  in
  let orchestrator_inspection =
    inspect_by_name client ~net ~clock ~container_name:"bondi-orchestrator"
  in
  let traefik_inspection =
    inspect_by_name client ~net ~clock ~container_name:"bondi-traefik"
  in
  let alloy_inspection =
    inspect_by_name client ~net ~clock ~container_name:"bondi-alloy"
  in
  (* A failed listing is reported rather than rendered as an empty set: the
     client shows anything it does not hear about as "not found", which reads
     as "setup has not run" when the real cause is an unreachable Docker. *)
  let managed_inspections, managed_error =
    match Docker.Client.list_containers client ~net ~all:true () with
    | Error msg ->
        ([], Some (Printf.sprintf "failed to list managed containers: %s" msg))
    | Ok containers ->
        ( List.filter_map
            (fun (container : Docker.Client.container) ->
              match
                Docker.Client.inspect_container client ~net ~clock
                  ~container_id:container.id
              with
              | Ok inspect -> Some (container, inspect)
              | Error msg ->
                  Diagnostics.write
                    (Printf.sprintf "failed to inspect managed container %s: %s"
                       container.id msg);
                  None)
            (managed_containers_of containers),
          None )
  in
  let scheduled_cron_jobs, cron_error =
    match Crontab.list_scheduled_jobs () with
    | Ok jobs -> (jobs, None)
    | Error msg -> ([], Some (Printf.sprintf "Failed to read crontab: %s" msg))
  in
  let cron_container_inspections =
    List.filter_map
      (fun (job : Crontab.scheduled_job) ->
        match
          Docker.Client.get_container_by_name client ~net
            ~container_name:job.name
        with
        | Error msg ->
            Diagnostics.write
              (Printf.sprintf "failed to look up cron container %s: %s" job.name
                 msg);
            None
        | Ok None -> None
        | Ok (Some container) -> (
            match
              Docker.Client.inspect_container client ~net ~clock
                ~container_id:container.id
            with
            | Ok inspect -> Some (job.name, inspect)
            | Error msg ->
                Diagnostics.write
                  (Printf.sprintf "failed to inspect cron container %s: %s"
                     job.name msg);
                None))
      scheduled_cron_jobs
  in
  {
    service_inspection;
    orchestrator_inspection;
    traefik_inspection;
    scheduled_cron_jobs;
    cron_container_inspections;
    cron_error;
    alloy_inspection;
    managed_inspections;
    managed_error;
  }

(* The whole of what the endpoint decides, with no transport named. Ported
   from the route body: gather, plan, and narrate the per-subsystem warnings
   the plan collected.

   The catch-all is the route's former [Lwt.catch], moved here so the caller is
   handed a value instead of an escaping exception. It stays a catch-all rather
   than filtering [Stdlib.Exit]: nothing on this path calls [exit], and
   narrowing it would answer a raised [Exit] differently than this endpoint
   answers it today. [Eio.Cancel.Cancelled] is different, and it is the
   boundary move that makes it so: the old catch sat outside
   [Lwt_eio.run_eio], where a cancelled fiber had already been converted before
   it could be seen, while this one runs inside that fiber. Absorbing it there
   would let a cancelled status report return normally and break structured
   concurrency, so it is re-raised rather than classified. A subsystem that merely failed does not come through here
   at all -- those are collected as values into [errors] and returned with
   whatever else could be read, because a status that reports nothing is worse
   than a status that reports what it could not reach. *)
let report ~client ~net ~clock ~(service_name : string option) :
    (comprehensive_status, Handler_error.t) result =
  try
    let ctx = gather ~client ~net ~clock ~service_name in
    let status = plan ~service_name ctx in
    List.iter
      (fun e -> Diagnostics.write (Printf.sprintf "status warning: %s" e))
      status.errors;
    Ok status
  with
  | Eio.Cancel.Cancelled _ as cancelled -> raise cancelled
  | exn -> Error (Handler_error.Orchestrator_failure (Printexc.to_string exn))

let route ~client ~net ~clock =
  Dream.get "/status" @@ fun req ->
  let open Lwt.Infix in
  let service_name = Dream.query req "service" in
  (Lwt_eio.run_eio @@ fun () -> report ~client ~net ~clock ~service_name)
  >>= function
  | Ok status ->
      status
      |> comprehensive_status_to_yojson
      |> Yojson.Safe.to_string
      |> Dream.json
  | Error err ->
      Dream.respond
        ~status:(Handler_error.http_status err)
        (Handler_error.message err)
