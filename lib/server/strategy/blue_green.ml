let default_poll_interval = 1.0
let default_health_timeout = 120.0

(** How long the new colour serves beside the old one, once healthy, before the
    old one is stopped. Traefik applies what its Docker provider sees at most
    once per providersThrottleDuration, 2 s by default, so the configuration
    that adds the new container can land up to 2 s after its [healthy] event.
    Stopped before then, the old container is the only server Traefik knows and
    refuses everything sent to it, with nothing to retry against. 3 s is that
    default with a margin. Measured on Docker Engine 29.10.0 with Traefik
    v3.6.8, in swaps run by hand in this plan's order under a steady 50 requests
    a second: with no settle 58 of 508 and 72 of 504 failed, with 3 s 3 of 654
    and 4 of 654; and through this strategy, polling health every quarter
    second, 57 of 693 with no settle and 5 of 837 with 3 s
    [observed 2026-11-22]. Neither configurable nor read by the simple strategy,
    whose stop precedes its new container and has no such window. *)
let settle_before_stop = 3.0

(* ------------------------------------------------------------------------- *)
(* Types                                                                     *)
(* ------------------------------------------------------------------------- *)

(** What gather found under [<name>-new], the name a new colour is started under
    beside a running workload. A deploy that failed past the health check can
    leave it as the container Traefik is serving, so it is read before it is
    touched. *)
type temp_container =
  | Absent
  | Orphan of Docker.Client.container
      (** Not running, not healthy, or not on the shared network: nothing is
          served by it, so it is removed before the new colour starts. *)
  | Live of Docker.Client.container
      (** Running, healthy and on the shared network: an interrupted swap,
          completed before the new colour is planned against it. *)

(** What gather read under [<name>-new]: the container and its inspect, kept
    unclassified so that deciding what it is stays in {!plan}. *)
type temp_read =
  | No_temp
  | Temp of Docker.Client.container * Docker.Client.inspect_response

type blue_green_context = {
  current_workload : Docker.Client.container option;
  temp_read : temp_read;
}

type blue_green_config = {
  container_name : string;
  temp_container_name : string;
  config : Docker.Client.container_config;
  host_config : Docker.Client.host_config;
      (* One value for both [RunNewContainer] sites, so the colour started
         beside a running workload and the one started on a first deploy
         cannot mount differently. *)
  networking_conf : Docker.Client.networking_config;
  poll_interval : float;
  health_timeout : float;
}

type action =
  | CleanupOrphanedContainer of { container_id : string }
  | RunNewContainer of {
      container_name : string;
      config : Docker.Client.container_config;
      host_config : Docker.Client.host_config;
      networking_conf : Docker.Client.networking_config;
    }
  | WaitForHealthy of {
      container_name : string;
      poll_interval : float;
      timeout : float;
    }
  | SettleBeforeStop of { seconds : float }
      (** A fixed wait, so the proxy routes to the new colour before the old one
          is stopped. *)
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

(** Classifies the container found under [<name>-new] from its inspect. Only a
    container proven to be serving is [Live]: running, reporting [healthy], and
    attached to [network_name], the network Traefik routes over. Anything short
    of that proof is [Orphan], including a health word the Engine API does not
    define, because nothing but a passing check shows it is serving. *)
let classify_temp_container ~network_name (container : Docker.Client.container)
    (inspect : Docker.Client.inspect_response) : temp_container =
  let running =
    match inspect.state.status with
    | "running" -> true
    | _ -> false
  in
  let healthy =
    match inspect.state.health with
    | Some { status = "healthy"; _ } -> true
    | Some _
    | None ->
        false
  in
  let attached =
    match inspect.network_settings with
    | Some { networks } -> List.mem network_name networks
    | None -> false
  in
  match (running, healthy, attached) with
  | true, true, true -> Live container
  | false, (true | false), (true | false)
  | true, false, (true | false)
  | true, true, false ->
      Orphan container

let plan (config : blue_green_config) (context : blue_green_context) :
    deploy_plan =
  (* What is under the temp name is settled first. An orphan is removed. A live
     one is the container serving after a swap that failed past the health
     check, so that swap is completed (the old workload, if any, stopped while
     attached, then the live one renamed) and it becomes the workload the new
     colour replaces. *)
  let temp_container =
    match context.temp_read with
    | No_temp -> Absent
    | Temp (container, inspect) ->
        classify_temp_container ~network_name:Bondi_common.Defaults.network_name
          container inspect
  in
  let settle_temp, workload =
    match temp_container with
    | Absent -> ([], context.current_workload)
    | Orphan container ->
        ( [ CleanupOrphanedContainer { container_id = container.id } ],
          context.current_workload )
    | Live live ->
        let stop_old =
          match context.current_workload with
          | Some old -> [ StopAndRemoveContainer { container_id = old.id } ]
          | None -> []
        in
        ( stop_old
          @ [
              RenameContainer
                { container_id = live.id; new_name = config.container_name };
            ],
          Some live )
  in
  (* The rollback target is the container each branch starts: beside a
     workload, the temp name, so the one still serving is left alone; with
     nothing serving, the service's own name. *)
  let main_actions, rollback_container_name =
    match workload with
    | Some workload ->
        ( [
            RunNewContainer
              {
                container_name = config.temp_container_name;
                config = config.config;
                host_config = config.host_config;
                networking_conf = config.networking_conf;
              };
            WaitForHealthy
              {
                container_name = config.temp_container_name;
                poll_interval = config.poll_interval;
                timeout = config.health_timeout;
              };
            (* Healthy is not yet routed: Traefik may add the new colour up to
               its throttle later, so the old one serves until then. *)
            SettleBeforeStop { seconds = settle_before_stop };
            (* Stopped while still attached to the network: Traefik drops it on
             its [die] event [observed -- Traefik v3.6.8, engine 29.10.0, the
             hand-run swap recorded in scripts/deploy-arms.sh], and until then
             it keeps DNS and its database. Detaching it first reloads nothing
             in Traefik [assumed -- from the Traefik v3.6.8 source and docs
             read for feature 0041 FR-4; no run records it] and cuts it off
             mid-shutdown. *)
            StopAndRemoveContainer { container_id = workload.id };
            RenameContainer
              {
                container_id = config.temp_container_name;
                new_name = config.container_name;
              };
          ],
          config.temp_container_name )
    | None ->
        ( [
            RunNewContainer
              {
                container_name = config.container_name;
                config = config.config;
                host_config = config.host_config;
                networking_conf = config.networking_conf;
              };
            WaitForHealthy
              {
                container_name = config.container_name;
                poll_interval = config.poll_interval;
                timeout = config.health_timeout;
              };
          ],
          config.container_name )
  in
  { success_path = settle_temp @ main_actions; rollback_container_name }

(** The message a failed health wait answers with, given how the rollback that
    followed it went. A rollback that failed is reported beside the failure that
    caused it, so neither is lost; one that succeeded adds nothing. *)
let failure_after_rollback ~cause (rollback : (unit, string) result) : string =
  match rollback with
  | Ok () -> cause
  | Error rollback_error ->
      Printf.sprintf "%s; the rollback that followed also failed: %s" cause
        rollback_error

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
      let* inspect =
        Docker.Client.inspect_container client ~net ~clock
          ~container_id:container_name
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
  let ( let* ) = Result.bind in
  let* () =
    Docker.Client.stop_container client ~net
      ~container_id:rollback_container_name
  in
  Docker.Client.remove_container client ~net
    ~container_id:rollback_container_name

let interpret ~clock ~client ~net (plan : deploy_plan) : (unit, string) result =
  let rec run = function
    | [] -> Ok ()
    | CleanupOrphanedContainer { container_id } :: rest ->
        let* () = Docker.Client.stop_container client ~net ~container_id in
        let* () = Docker.Client.remove_container client ~net ~container_id in
        run rest
    | RunNewContainer { container_name; config; host_config; networking_conf }
      :: rest ->
        let opts : Docker.Client.run_image_options =
          {
            container_name;
            config;
            host_config = Some host_config;
            networking_conf = Some networking_conf;
          }
        in
        let* _ = Docker.Client.run_image_with_opts client ~net opts in
        run rest
    | WaitForHealthy { container_name; poll_interval; timeout } :: rest -> (
        match
          wait_for_healthy ~clock ~client ~net ~container_name ~poll_interval
            ~timeout
        with
        | Ok () -> run rest
        | Error cause ->
            Error
              (failure_after_rollback ~cause
                 (rollback ~client ~net
                    ~rollback_container_name:plan.rollback_container_name)))
    | SettleBeforeStop { seconds } :: rest ->
        Eio.Time.sleep clock seconds;
        run rest
    | StopAndRemoveContainer { container_id } :: rest ->
        let* () = Docker.Client.stop_container client ~net ~container_id in
        let* () = Docker.Client.remove_container client ~net ~container_id in
        run rest
    | RenameContainer { container_id; new_name } :: rest ->
        let* () =
          Docker.Client.rename_container client ~net ~container_id ~new_name
        in
        run rest
  in
  run plan.success_path

(* ------------------------------------------------------------------------- *)
(* Phase 1: Gather context (read-only)                                       *)
(* ------------------------------------------------------------------------- *)

let gather_context ~clock ~client ~net ~container_name ~temp_container_name :
    (blue_green_context, string) result =
  let* current_workload =
    Docker.Client.get_container_by_name client ~net ~container_name
  in
  let* temp =
    Docker.Client.get_container_by_name client ~net
      ~container_name:temp_container_name
  in
  (* Read before anything is touched: an inspect that fails stops the deploy
     here, with nothing moved, rather than guessing what the container is. What
     it is is decided by [plan]. *)
  let* temp_read =
    match temp with
    | None -> Ok No_temp
    | Some container ->
        let* inspect =
          Docker.Client.inspect_container client ~net ~clock
            ~container_id:container.id
        in
        Ok (Temp (container, inspect))
  in
  Ok { current_workload; temp_read }

(* ------------------------------------------------------------------------- *)
(* Entry point                                                               *)
(* ------------------------------------------------------------------------- *)

(** The strategy's whole configuration, read purely from the deploy input.
    Separate from [deploy] so that what a switch runs with, its host config
    included, is reachable without a Docker Engine. *)
let config_of_input (input : Simple.deploy_input) :
    (blue_green_config, string) result =
  let container_name =
    match input.service_name with
    | Some name -> Bondi_common.Router_name.to_string name
    | None -> "bondi-service"
  in
  let temp_container_name = container_name ^ "-new" in
  let* _, service_cfg = Simple.service_config input in
  let poll_interval =
    Option.value ~default:default_poll_interval input.poll_interval
  in
  let health_timeout =
    Option.value ~default:default_health_timeout input.health_timeout
  in
  Ok
    {
      container_name;
      temp_container_name;
      config = service_cfg;
      host_config = Workload_host_config.of_volumes input.volumes;
      networking_conf = Docker.Client.default_networking_config;
      poll_interval;
      health_timeout;
    }

(** Every read the strategy plans from, taken before anything on the box moves
    and so before the proxy does. The configuration is built here too, so a
    request the workload cannot be built from is refused ahead of the reads. *)
let gather ~clock ~client ~net ~(input : Simple.deploy_input) :
    (blue_green_config * blue_green_context, string) result =
  let* config = config_of_input input in
  let* context =
    gather_context ~clock ~client ~net ~container_name:config.container_name
      ~temp_container_name:config.temp_container_name
  in
  Ok (config, context)

let deploy ~clock ~client ~net (config : blue_green_config)
    (context : blue_green_context) : (unit, string) result =
  interpret ~clock ~client ~net (plan config context)
