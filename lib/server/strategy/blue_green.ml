let default_drain_grace_period = 2.0
let default_poll_interval = 1.0
let default_health_timeout = 120.0

(* ------------------------------------------------------------------------- *)
(* Types                                                                     *)
(* ------------------------------------------------------------------------- *)

type blue_green_context = {
  current_workload : Docker.Client.container option;
  orphaned_new_container : Docker.Client.container option;
}

type blue_green_config = {
  container_name : string;
  temp_container_name : string;
  config : Docker.Client.container_config;
  networking_conf : Docker.Client.networking_config;
  network_name : string;
  poll_interval : float;
  health_timeout : float;
  drain_grace_period : float;
}

type action =
  | CleanupOrphanedContainer of { container_id : string }
  | RunNewContainer of {
      container_name : string;
      config : Docker.Client.container_config;
      networking_conf : Docker.Client.networking_config;
    }
  | WaitForHealthy of {
      container_name : string;
      poll_interval : float;
      timeout : float;
    }
  | DisconnectFromNetwork of { container_id : string; network_name : string }
  | DrainGracePeriod of { seconds : float }
  | StopAndRemoveContainer of { container_id : string }
  | RenameContainer of { container_id : string; new_name : string }

type deploy_plan = {
  success_path : action list;
  rollback_container_name : string;
}

(* ------------------------------------------------------------------------- *)
(* Phase 2: Plan (pure)                                                     *)
(* ------------------------------------------------------------------------- *)

let ( let* ) = Result.bind

let plan (config : blue_green_config) (context : blue_green_context) :
    deploy_plan =
  let cleanup =
    match context.orphaned_new_container with
    | Some container ->
        [ CleanupOrphanedContainer { container_id = container.id } ]
    | None -> []
  in
  let main_actions =
    match context.current_workload with
    | Some workload ->
        [
          RunNewContainer
            {
              container_name = config.temp_container_name;
              config = config.config;
              networking_conf = config.networking_conf;
            };
          WaitForHealthy
            {
              container_name = config.temp_container_name;
              poll_interval = config.poll_interval;
              timeout = config.health_timeout;
            };
          DisconnectFromNetwork
            { container_id = workload.id; network_name = config.network_name };
          DrainGracePeriod { seconds = config.drain_grace_period };
          StopAndRemoveContainer { container_id = workload.id };
          RenameContainer
            {
              container_id = config.temp_container_name;
              new_name = config.container_name;
            };
        ]
    | None ->
        [
          RunNewContainer
            {
              container_name = config.container_name;
              config = config.config;
              networking_conf = config.networking_conf;
            };
          WaitForHealthy
            {
              container_name = config.container_name;
              poll_interval = config.poll_interval;
              timeout = config.health_timeout;
            };
        ]
  in
  {
    success_path = cleanup @ main_actions;
    rollback_container_name = config.temp_container_name;
  }

(* ------------------------------------------------------------------------- *)
(* Phase 3: Interpreter                                                     *)
(* ------------------------------------------------------------------------- *)

let last_health_output (health : Docker.Client.health_state) =
  match List.rev health.log with
  | [] -> None
  | last :: _ ->
      let output = String.trim last.output in
      if output = "" then None else Some output

let health_detail (health : Docker.Client.health_state) =
  let streak =
    if health.failing_streak > 0 then
      Printf.sprintf "%d consecutive failures" health.failing_streak
    else ""
  in
  let output =
    match last_health_output health with
    | Some s -> Printf.sprintf "last output: %s" s
    | None -> ""
  in
  match (streak, output) with
  | "", "" -> ""
  | s, "" -> Printf.sprintf " (%s)" s
  | "", o -> Printf.sprintf " (%s)" o
  | s, o -> Printf.sprintf " (%s, %s)" s o

let wait_for_healthy ~clock ~client ~net ~container_name ~poll_interval ~timeout
    : (unit, string) result =
  let start = Eio.Time.now clock in
  let rec loop () =
    let elapsed = Eio.Time.now clock -. start in
    if elapsed >= timeout then
      Error
        (Printf.sprintf "timeout waiting for container %s to become healthy"
           container_name)
    else
      let inspect =
        Docker.Client.inspect_container client ~net ~container_id:container_name
      in
      match inspect.state.health with
      | Some { status = "healthy"; _ } -> Ok ()
      | Some ({ status = "unhealthy"; _ } as h) ->
          Error
            (Printf.sprintf "container %s is unhealthy%s" container_name
               (health_detail h))
      | _ ->
          Eio.Time.sleep clock poll_interval;
          loop ()
  in
  loop ()

let rollback ~client ~net ~rollback_container_name =
  Docker.Client.stop_container client ~net ~container_id:rollback_container_name;
  Docker.Client.remove_container client ~net
    ~container_id:rollback_container_name

let interpret ~clock ~client ~net (plan : deploy_plan) : (unit, string) result =
  let rec run = function
    | [] -> Ok ()
    | CleanupOrphanedContainer { container_id } :: rest ->
        Docker.Client.stop_container client ~net ~container_id;
        Docker.Client.remove_container client ~net ~container_id;
        run rest
    | RunNewContainer { container_name; config; networking_conf } :: rest ->
        let opts : Docker.Client.run_image_options =
          {
            container_name;
            config;
            host_config = None;
            networking_conf = Some networking_conf;
          }
        in
        let _ = Docker.Client.run_image_with_opts client ~net opts in
        run rest
    | WaitForHealthy { container_name; poll_interval; timeout } :: rest -> (
        match
          wait_for_healthy ~clock ~client ~net ~container_name ~poll_interval
            ~timeout
        with
        | Ok () -> run rest
        | Error msg ->
            rollback ~client ~net
              ~rollback_container_name:plan.rollback_container_name;
            Error msg)
    | DisconnectFromNetwork { container_id; network_name } :: rest ->
        Docker.Client.disconnect_from_network client ~net ~container_id
          ~network_name;
        run rest
    | DrainGracePeriod { seconds } :: rest ->
        Eio.Time.sleep clock seconds;
        run rest
    | StopAndRemoveContainer { container_id } :: rest ->
        Docker.Client.stop_container client ~net ~container_id;
        Docker.Client.remove_container client ~net ~container_id;
        run rest
    | RenameContainer { container_id; new_name } :: rest ->
        Docker.Client.rename_container client ~net ~container_id ~new_name;
        run rest
  in
  run plan.success_path

(* ------------------------------------------------------------------------- *)
(* Phase 1: Gather context (read-only)                                       *)
(* ------------------------------------------------------------------------- *)

let gather_context ~client ~net ~container_name ~temp_container_name :
    (blue_green_context, string) result =
  try
    let current_workload =
      Docker.Client.get_container_by_name client ~net ~container_name
    in
    let orphaned_new_container =
      Docker.Client.get_container_by_name client ~net
        ~container_name:temp_container_name
    in
    Ok { current_workload; orphaned_new_container }
  with
  | exn -> Error (Printexc.to_string exn)

(* ------------------------------------------------------------------------- *)
(* Entry point                                                               *)
(* ------------------------------------------------------------------------- *)

let deploy ~clock ~client ~net ~(input : Simple.deploy_input) :
    (unit, string) result =
  let container_name =
    match input.service_name with
    | Some name -> name
    | None -> "bondi-service"
  in
  let temp_container_name = container_name ^ "-new" in
  let* service_cfg = Simple.service_config input in
  let drain_grace_period =
    Option.value ~default:default_drain_grace_period input.drain_grace_period
  in
  let poll_interval =
    Option.value ~default:default_poll_interval input.poll_interval
  in
  let health_timeout =
    Option.value ~default:default_health_timeout input.health_timeout
  in
  let config : blue_green_config =
    {
      container_name;
      temp_container_name;
      config = service_cfg;
      networking_conf = Simple.default_networking_config;
      network_name = Simple.default_network_name;
      poll_interval;
      health_timeout;
      drain_grace_period;
    }
  in
  let* context =
    gather_context ~client ~net ~container_name ~temp_container_name
  in
  let deploy_plan = plan config context in
  interpret ~clock ~client ~net deploy_plan
