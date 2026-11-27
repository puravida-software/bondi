open Alcotest
module Blue_green = Bondi_server__Strategy__Blue_green
module Deploy = Bondi_server__Deploy
module Docker = Bondi_server__Docker__Client
module Simple = Bondi_server__Strategy__Simple
module Workload_host_config = Bondi_server__Strategy__Workload_host_config

(* The labels production puts on a service, taken from the function that builds
   them, so a change to the label shape reaches this suite instead of leaving a
   hand-written copy describing keys nothing produces. *)
let service_name = "my-service"

let service_input : Simple.deploy_input =
  {
    Simple.service_name = Some (Test_helpers.router_name service_name);
    image = Some (Test_helpers.image_reference "myapp:v1");
    port = Some 8080;
    registry_user = None;
    registry_pass = None;
    env_vars = None;
    traefik_domain_name = Some "example.com";
    traefik_image = None;
    traefik_acme_email = None;
    traefik_acme_ca_server = None;
    force_traefik_redeploy = None;
    cron_jobs = None;
    drain_grace_period = None;
    deployment_strategy = None;
    health_timeout = None;
    poll_interval = None;
    logs = None;
    volumes = None;
  }

let traefik_labels =
  match Simple.service_config service_input with
  | Ok (_, { Docker.labels = Some labels; _ }) -> labels
  | Ok (_, { Docker.labels = None; _ })
  | Error _ ->
      failwith "fixture: service_config produced no labels"

let base_config =
  {
    Blue_green.container_name = "my-service";
    temp_container_name = "my-service-new";
    config =
      {
        Docker.image = Some "myapp:v1";
        env = None;
        cmd = None;
        entrypoint = None;
        hostname = None;
        working_dir = None;
        labels = Some traefik_labels;
        exposed_ports = None;
      };
    host_config = Workload_host_config.of_volumes None;
    networking_conf = Docker.default_networking_config;
    poll_interval = 1.0;
    health_timeout = 120.0;
  }

let old_workload =
  Server_test_helpers.mk_container ~id:"old-container-id" ~image:"myapp:v0.9"
    ~names:[ "/my-service" ] ()

let context_with_workload =
  {
    Blue_green.current_workload = Some old_workload;
    temp_read = Blue_green.No_temp;
  }

let empty_context =
  { Blue_green.current_workload = None; temp_read = Blue_green.No_temp }

let action_string = function
  | Blue_green.CleanupOrphanedContainer { container_id } ->
      "CleanupOrphanedContainer(" ^ container_id ^ ")"
  | Blue_green.RunNewContainer { container_name; _ } ->
      "RunNewContainer(" ^ container_name ^ ")"
  | Blue_green.WaitForHealthy { container_name; _ } ->
      "WaitForHealthy(" ^ container_name ^ ")"
  | Blue_green.SettleBeforeStop { seconds } ->
      Printf.sprintf "SettleBeforeStop(%g)" seconds
  | Blue_green.StopAndRemoveContainer { container_id } ->
      "StopAndRemoveContainer(" ^ container_id ^ ")"
  | Blue_green.RenameContainer { container_id; new_name } ->
      "RenameContainer(" ^ container_id ^ "," ^ new_name ^ ")"

(* The old container is stopped while it is still attached to the network.
   Detaching it first reloads nothing in Traefik [assumed -- from the
   Traefik v3.6.8 source and docs; no run records it], so it would keep the old
   container in rotation while cutting that container off from DNS and its
   database for the rest of its shutdown. Traefik drops it from rotation on its
   [die] event [observed -- Traefik v3.6.8, engine 29.10.0, the hand-run swap
   recorded in scripts/deploy-arms.sh], and the router's retry middleware resends what it refuses
   meanwhile. Between the health check and the stop sits the fixed settle that
   lets Traefik add the new container before the old one refuses: 3 s, the
   developer's figure above Traefik's 2 s default providersThrottleDuration.
   The list is compared whole, so a detach anywhere ahead of the stop, or the
   settle anywhere but between the health check and the stop, is a different
   plan. *)
let test_success_path_stops_old_while_attached () =
  let plan = Blue_green.plan base_config context_with_workload in
  check (list string) "success path actions"
    [
      "RunNewContainer(my-service-new)";
      "WaitForHealthy(my-service-new)";
      "SettleBeforeStop(3)";
      "StopAndRemoveContainer(old-container-id)";
      "RenameContainer(my-service-new,my-service)";
    ]
    (List.map action_string plan.success_path)

let test_plan_success_path_no_existing_workload () =
  let plan = Blue_green.plan base_config empty_context in
  check (list string) "success path for first deploy"
    [ "RunNewContainer(my-service)"; "WaitForHealthy(my-service)" ]
    (List.map action_string plan.success_path)

(* The settle is blue-green's alone. Simple stops the old container before its
   new one exists, so there is no window in which Traefik has yet to add a new
   server, and nothing to wait for. On one service, with one container running,
   blue-green's plan settles before its stop (the affirmative arm) and simple's
   plan is the pull, the stop and the run, with nothing between. *)
let simple_action_string = function
  | Simple.EnsureNetwork { network_name } ->
      "EnsureNetwork(" ^ network_name ^ ")"
  | Simple.PullImage { image; _ } ->
      "PullImage(" ^ Bondi_common.Image_reference.to_string image ^ ")"
  | Simple.StopAndRemoveContainer container ->
      "StopAndRemoveContainer(" ^ container.Docker.id ^ ")"
  | Simple.RunWorkload { container_name; _ } ->
      "RunWorkload(" ^ container_name ^ ")"

let test_settle_is_blue_green_only () =
  check bool "blue-green settles before its stop" true
    (List.mem "SettleBeforeStop(3)"
       (List.map action_string
          (Blue_green.plan base_config context_with_workload).success_path));
  match
    Simple.plan service_input { Simple.current_workload = Some old_workload }
  with
  | Error e -> Alcotest.fail ("simple plan refused: " ^ e)
  | Ok actions ->
      check (list string) "simple: pull, stop, run, and no settle"
        [
          "EnsureNetwork(bondi-network)";
          "PullImage(myapp:v1)";
          "StopAndRemoveContainer(old-container-id)";
          "RunWorkload(my-service)";
        ]
        (List.map simple_action_string actions)

(* Failure paths

   [new_container] is what gather finds under the temp name. Each inspect below
   differs from [serving_inspect] in one respect only, so an [Orphan] answer is
   caused by that respect and not by the fixture failing to describe a serving
   container. *)

let new_container =
  Server_test_helpers.mk_container ~id:"new-container-id" ~image:"myapp:v1"
    ~names:[ "/my-service-new" ] ()

let shared_network = Bondi_common.Defaults.network_name

let inspect_of ~status ~health ~networks =
  Server_test_helpers.mk_inspect ~created_at:"2026-11-22T00:00:00Z"
    ~restart_count:0 ~status ~health ~networks ()

let healthy = Some (Server_test_helpers.mk_health_state "healthy")

let serving_inspect =
  inspect_of ~status:"running" ~health:healthy
    ~networks:(Some [ shared_network ])

let temp_container_string = function
  | Blue_green.Absent -> "Absent"
  | Blue_green.Orphan container -> "Orphan(" ^ container.Docker.id ^ ")"
  | Blue_green.Live container -> "Live(" ^ container.Docker.id ^ ")"

let classified inspect =
  temp_container_string
    (Blue_green.classify_temp_container ~network_name:shared_network
       new_container inspect)

let test_temp_container_classification () =
  check string "running, healthy and attached is live" "Live(new-container-id)"
    (classified serving_inspect);
  List.iter
    (fun (what, inspect) ->
      check string (what ^ " is an orphan") "Orphan(new-container-id)"
        (classified inspect))
    [
      ( "not running",
        inspect_of ~status:"exited" ~health:healthy
          ~networks:(Some [ shared_network ]) );
      ( "unhealthy",
        inspect_of ~status:"running"
          ~health:(Some (Server_test_helpers.mk_health_state "unhealthy"))
          ~networks:(Some [ shared_network ]) );
      ( "starting",
        inspect_of ~status:"running"
          ~health:(Some (Server_test_helpers.mk_health_state "starting"))
          ~networks:(Some [ shared_network ]) );
      ( "without a health check",
        inspect_of ~status:"running" ~health:None
          ~networks:(Some [ shared_network ]) );
      (* On a network, but not the one Traefik routes over: the name is read,
         not merely that some network is attached. *)
      ( "detached from the shared network",
        inspect_of ~status:"running" ~health:healthy
          ~networks:(Some [ "bridge" ]) );
      ( "without network settings",
        inspect_of ~status:"running" ~health:healthy ~networks:None );
    ]

(* The two kinds of container [plan] classifies under the temp name, as gather
   reads them: the container with its inspect. *)
let live_temp container = Blue_green.Temp (container, serving_inspect)

let orphan_temp container =
  Blue_green.Temp
    ( container,
      inspect_of ~status:"exited" ~health:healthy
        ~networks:(Some [ shared_network ]) )

let context_with ~workload temp_read =
  { Blue_green.current_workload = workload; temp_read }

(* The container the failed branch started is what a rollback removes. *)
let started_container (plan : Blue_green.deploy_plan) =
  match
    List.find_map
      (function
        | Blue_green.RunNewContainer { container_name; _ } ->
            Some container_name
        | Blue_green.CleanupOrphanedContainer _
        | Blue_green.WaitForHealthy _
        | Blue_green.SettleBeforeStop _
        | Blue_green.StopAndRemoveContainer _
        | Blue_green.RenameContainer _ ->
            None)
      plan.success_path
  with
  | Some name -> name
  | None -> Alcotest.fail "expected a RunNewContainer action"

let check_rollback_target ~what ~expected context =
  let plan = Blue_green.plan base_config context in
  check string
    (what ^ ": the rollback target")
    expected plan.rollback_container_name;
  check string
    (what ^ ": is the container that branch started")
    (started_container plan) plan.rollback_container_name

(* With nothing serving, the new container is started under the service's own
   name, so that is the one a failed health check must remove. *)
let test_first_deploy_rollback_targets_started_container () =
  check_rollback_target ~what:"first deploy" ~expected:"my-service"
    empty_context;
  check_rollback_target ~what:"first deploy over an orphan"
    ~expected:"my-service"
    (context_with ~workload:None (orphan_temp new_container))

(* With a workload serving, the new colour runs beside it under the temp name,
   and a rollback removing the service's own name would take down the one
   container still serving. A live temp container is the serving workload once
   its swap is completed, so the same holds with or without the old one. *)
let test_rollback_with_old_serving_targets_new () =
  check_rollback_target ~what:"beside a workload" ~expected:"my-service-new"
    context_with_workload;
  check_rollback_target ~what:"beside a live temp container alone"
    ~expected:"my-service-new"
    (context_with ~workload:None (live_temp new_container));
  check_rollback_target ~what:"beside a live temp container and the old one"
    ~expected:"my-service-new"
    (context_with ~workload:(Some old_workload) (live_temp new_container))

(* A live temp container is the one Traefik is serving after a swap that
   failed past the health check. It is never cleaned up as an orphan: the swap
   is completed first, and it is replaced only as the outgoing colour, after
   the new one passes its check. The lists are compared whole, so a removal of
   it anywhere ahead of that is a different plan. *)
let test_live_new_is_not_removed () =
  check (list string) "live, with the old workload present"
    [
      "StopAndRemoveContainer(old-container-id)";
      "RenameContainer(new-container-id,my-service)";
      "RunNewContainer(my-service-new)";
      "WaitForHealthy(my-service-new)";
      "SettleBeforeStop(3)";
      "StopAndRemoveContainer(new-container-id)";
      "RenameContainer(my-service-new,my-service)";
    ]
    (List.map action_string
       (Blue_green.plan base_config
          (context_with ~workload:(Some old_workload) (live_temp new_container)))
         .success_path);
  check (list string) "live, with no old workload"
    [
      "RenameContainer(new-container-id,my-service)";
      "RunNewContainer(my-service-new)";
      "WaitForHealthy(my-service-new)";
      "SettleBeforeStop(3)";
      "StopAndRemoveContainer(new-container-id)";
      "RenameContainer(my-service-new,my-service)";
    ]
    (List.map action_string
       (Blue_green.plan base_config
          (context_with ~workload:None (live_temp new_container)))
         .success_path);
  (* The affirmative arm: the same container, classified an orphan, is
     removed before anything else. *)
  check (list string) "an orphan is still cleaned up"
    [
      "CleanupOrphanedContainer(new-container-id)";
      "RunNewContainer(my-service-new)";
      "WaitForHealthy(my-service-new)";
      "SettleBeforeStop(3)";
      "StopAndRemoveContainer(old-container-id)";
      "RenameContainer(my-service-new,my-service)";
    ]
    (List.map action_string
       (Blue_green.plan base_config
          (context_with ~workload:(Some old_workload)
             (orphan_temp new_container)))
         .success_path)

let proxy_string = function
  | Bondi_server__Proxy.CreateNetwork { network_name } ->
      "CreateNetwork(" ^ network_name ^ ")"
  | Bondi_server__Proxy.PullImage { image } ->
      "PullImage(" ^ Bondi_common.Image_reference.to_string image ^ ")"
  | Bondi_server__Proxy.StopAndRemove { container_id } ->
      "ProxyStopAndRemove(" ^ container_id ^ ")"
  | Bondi_server__Proxy.EnsureTraefik _ -> "EnsureTraefik"

let pull_string = function
  | Deploy.PullWorkload image ->
      "PullWorkload(" ^ Bondi_common.Image_reference.to_string image ^ ")"
  | Deploy.PullTraefik image ->
      "PullTraefik(" ^ Bondi_common.Image_reference.to_string image ^ ")"
  | Deploy.PullCronImage job -> "PullCronImage(" ^ job.Simple.name ^ ")"

(* The whole deploy as one sequence: the pulls where the deploy runs them, and
   blue-green's plan where the deploy runs it. A strategy the request declares
   leaves the workload to be pulled with the other images. *)
let composed_deploy context =
  (* A running proxy that a forced redeploy replaces, so the proxy plan stops
     it. *)
  let current_traefik =
    Some
      (Server_test_helpers.mk_container ~id:"proxy-id" ~image:"traefik:v3.3.0"
         ~names:[ "/" ^ Bondi_common.Builtin_container.traefik ]
         ())
  in
  let input =
    {
      service_input with
      deployment_strategy = Some "blue-green";
      traefik_image = Some (Test_helpers.image_reference "traefik:v3.3.0");
      traefik_acme_email = Some "ops@example.com";
      force_traefik_redeploy = Some true;
    }
  in
  let config =
    match Blue_green.config_of_input input with
    | Ok config -> config
    | Error e -> Alcotest.fail ("config refused: " ^ e)
  in
  List.concat_map
    (function
      | Deploy.Pull_images ->
          List.map pull_string
            (Deploy.pull_plan ~workload_pulled:false input ~current_traefik)
      | Deploy.Converge_proxy ->
          List.map proxy_string (Deploy.proxy_plan input ~current_traefik)
      | Deploy.Deploy_workload ->
          List.map action_string (Blue_green.plan config context).success_path
      | Deploy.Check_image_labels
      | Deploy.Validate_workload
      | Deploy.Gather_workload
      | Deploy.Converge_restart_policy
      | Deploy.Snapshot_replaced
      | Deploy.Apply_cron
      | Deploy.Clean_up ->
          [])
    (Deploy.deploy_steps ~has_service:true)

let position entry entries =
  let rec go i = function
    | [] -> Alcotest.fail (entry ^ " is not in the composed deploy")
    | x :: _ when x = entry -> i
    | _ :: rest -> go (i + 1) rest
  in
  go 0 entries

(* The proxy's stop is a stop like the workload's: after every pull, before
   the workload starts. *)
let test_proxy_stop_after_pulls_before_workload_start () =
  let composed = composed_deploy context_with_workload in
  let proxy_stop = position "ProxyStopAndRemove(proxy-id)" composed in
  check bool "after the workload pull" true
    (position "PullWorkload(myapp:v1)" composed < proxy_stop);
  check bool "after the proxy pull" true
    (position "PullTraefik(traefik:v3.3.0)" composed < proxy_stop);
  check bool "before the workload starts" true
    (proxy_stop < position "RunNewContainer(my-service-new)" composed)

(* Completing an interrupted swap stops the old workload, so it waits for the
   new image like every other stop: a pull that fails must leave both
   containers as they were. *)
let test_live_completion_after_workload_pull () =
  let composed =
    composed_deploy
      (context_with ~workload:(Some old_workload) (live_temp new_container))
  in
  let pulled = position "PullWorkload(myapp:v1)" composed in
  check bool "the old workload is stopped after the pull" true
    (pulled < position "StopAndRemoveContainer(old-container-id)" composed);
  check bool "the live container is renamed after the pull" true
    (pulled < position "RenameContainer(new-container-id,my-service)" composed)

let test_rollback_failure_reported_with_cause () =
  let cause = "container my-service is unhealthy (3 consecutive failures)" in
  let rollback_error = "docker http 500: driver failed removing container" in
  let reported =
    Blue_green.failure_after_rollback ~cause (Error rollback_error)
  in
  check bool "a failed rollback keeps the cause" true
    (Bondi_common.String_utils.contains ~needle:cause reported);
  check bool "and reports its own failure" true
    (Bondi_common.String_utils.contains ~needle:rollback_error reported);
  check string "a rollback that succeeded adds nothing" cause
    (Blue_green.failure_after_rollback ~cause (Ok ()))

let test_plan_temp_container_name () =
  let plan = Blue_green.plan base_config context_with_workload in
  let run_action =
    List.find_opt
      (function
        | Blue_green.RunNewContainer _ -> true
        | Blue_green.CleanupOrphanedContainer _
        | Blue_green.WaitForHealthy _
        | Blue_green.SettleBeforeStop _
        | Blue_green.StopAndRemoveContainer _
        | Blue_green.RenameContainer _ ->
            false)
      plan.success_path
  in
  match run_action with
  | Some (Blue_green.RunNewContainer { container_name; _ }) ->
      check string "temp container name" "my-service-new" container_name
  | Some (Blue_green.CleanupOrphanedContainer _)
  | Some (Blue_green.WaitForHealthy _)
  | Some (Blue_green.SettleBeforeStop _)
  | Some (Blue_green.StopAndRemoveContainer _)
  | Some (Blue_green.RenameContainer _)
  | None ->
      Alcotest.fail "expected RunNewContainer action"

let test_plan_traefik_labels_on_new_container () =
  let plan = Blue_green.plan base_config context_with_workload in
  let run_action =
    List.find_opt
      (function
        | Blue_green.RunNewContainer _ -> true
        | Blue_green.CleanupOrphanedContainer _
        | Blue_green.WaitForHealthy _
        | Blue_green.SettleBeforeStop _
        | Blue_green.StopAndRemoveContainer _
        | Blue_green.RenameContainer _ ->
            false)
      plan.success_path
  in
  match run_action with
  | Some (Blue_green.RunNewContainer { config; _ }) ->
      let has_traefik_enable =
        match config.labels with
        | Some labels ->
            List.exists
              (fun (k, v) -> k = "traefik.enable" && v = "true")
              labels
        | None -> false
      in
      check bool "has traefik labels" true has_traefik_enable;
      let router_rule =
        match config.labels with
        | Some labels ->
            List.assoc_opt
              ("traefik.http.routers." ^ service_name ^ ".rule")
              labels
        | None -> None
      in
      check bool "router is named after the service" true
        (Option.is_some router_rule)
  | Some (Blue_green.CleanupOrphanedContainer _)
  | Some (Blue_green.WaitForHealthy _)
  | Some (Blue_green.SettleBeforeStop _)
  | Some (Blue_green.StopAndRemoveContainer _)
  | Some (Blue_green.RenameContainer _)
  | None ->
      Alcotest.fail "expected RunNewContainer action"

let extract_new_container_host_config (actions : Blue_green.action list) =
  List.find_map
    (function
      | Blue_green.RunNewContainer { host_config; _ } -> Some host_config
      | Blue_green.CleanupOrphanedContainer _
      | Blue_green.WaitForHealthy _
      | Blue_green.SettleBeforeStop _
      | Blue_green.StopAndRemoveContainer _
      | Blue_green.RenameContainer _ ->
          None)
    actions

let check_planned_restart_policy msg (host_config : Docker.host_config) =
  match host_config.restart_policy with
  | None -> Alcotest.fail (msg ^ ": no restart policy planned")
  | Some policy ->
      check string (msg ^ ": policy name") "unless-stopped" policy.name;
      check (option int)
        (msg ^ ": no maximum retry count")
        None policy.maximum_retry_count

let check_restart_policy_for msg context =
  let plan = Blue_green.plan base_config context in
  match extract_new_container_host_config plan.success_path with
  | None -> Alcotest.fail (msg ^ ": expected a RunNewContainer action")
  | Some host_config -> check_planned_restart_policy msg host_config

(* [Blue_green.plan] builds [RunNewContainer] at two separate sites - the
   temp-container arm taken when a workload is already running, and the
   direct-name arm taken when none is. Both are asserted, because a policy set
   only at one site ships a workload without one on the other path. *)
let test_run_new_container_carries_restart_policy () =
  check_restart_policy_for "replacing a running workload" context_with_workload;
  check_restart_policy_for "no existing workload" empty_context

(* Volumes

   The config below is assembled from a deploy input by the same function
   [Blue_green.deploy] uses, so these cases see the host config the strategy
   actually runs with rather than one this file built. *)

let mount_testable = Server_test_helpers.mount_testable
let host_config_testable = Server_test_helpers.host_config_testable
let bind_mount = Test_helpers.bind_mount

let input_with_volumes : Simple.deploy_input =
  {
    service_name = Some (Test_helpers.router_name "my-service");
    image = Some (Test_helpers.image_reference "myapp:v1");
    port = Some 8080;
    registry_user = None;
    registry_pass = None;
    env_vars = None;
    traefik_domain_name = Some "example.com";
    traefik_image = None;
    traefik_acme_email = None;
    traefik_acme_ca_server = None;
    force_traefik_redeploy = None;
    cron_jobs = None;
    drain_grace_period = None;
    deployment_strategy = Some "blue-green";
    health_timeout = None;
    poll_interval = None;
    logs = None;
    volumes =
      Some
        [
          bind_mount ~host:"/srv/app/invoices" ~container:"/app/invoices"
            ~read_only:false;
          bind_mount ~host:"/etc/app" ~container:"/app/config" ~read_only:true;
        ];
  }

let declared_mounts : Docker.mount list =
  [
    {
      type_ = "bind";
      source = "/srv/app/invoices";
      target = "/app/invoices";
      read_only = false;
    };
    {
      type_ = "bind";
      source = "/etc/app";
      target = "/app/config";
      read_only = true;
    };
  ]

let new_container_host_config msg input context =
  match Blue_green.config_of_input input with
  | Error e -> Alcotest.fail (msg ^ ": config refused: " ^ e)
  | Ok config -> (
      let plan = Blue_green.plan config context in
      match extract_new_container_host_config plan.success_path with
      | None -> Alcotest.fail (msg ^ ": expected a RunNewContainer action")
      | Some host_config -> host_config)

(* The temp-container site, taken when a workload is already running: the
   incoming colour mounts what the outgoing one does. *)
let test_new_container_carries_mounts_when_replacing_a_workload () =
  check
    (option (list mount_testable))
    "incoming colour's mounts" (Some declared_mounts)
    (new_container_host_config "replacing" input_with_volumes
       context_with_workload)
      .mounts

(* The direct-name site, taken when nothing is running yet. *)
let test_new_container_carries_mounts_on_first_deploy () =
  check
    (option (list mount_testable))
    "first container's mounts" (Some declared_mounts)
    (new_container_host_config "first deploy" input_with_volumes empty_context)
      .mounts

let simple_workload_host_config (input : Simple.deploy_input) =
  let context = { Simple.current_workload = None } in
  match Simple.plan input context with
  | Error e -> Alcotest.fail ("simple plan failed: " ^ e)
  | Ok actions -> (
      match
        List.find_map
          (function
            | Simple.RunWorkload { host_config; _ } -> Some host_config
            | Simple.EnsureNetwork _
            | Simple.StopAndRemoveContainer _
            | Simple.PullImage _ ->
                None)
          actions
      with
      | None -> Alcotest.fail "expected a RunWorkload action"
      | Some host_config -> host_config)

(* For one deploy input, the simple strategy's container and both blue-green
   sites get the same host config. The first check is the affirmative arm:
   equality between two configs that both carry no mounts would prove nothing. *)
let test_simple_and_blue_green_mount_identically () =
  let simple = simple_workload_host_config input_with_volumes in
  check
    (option (list mount_testable))
    "simple carries the declared mounts" (Some declared_mounts) simple.mounts;
  check host_config_testable "blue-green replacing a workload" simple
    (new_container_host_config "replacing" input_with_volumes
       context_with_workload);
  check host_config_testable "blue-green first deploy" simple
    (new_container_host_config "first deploy" input_with_volumes empty_context)

(* The colour started beside a running workload runs as [<svc>-new] and is
   renamed afterwards, so its container name is not the workload's name. The
   name check is the arm: it proves the label below was read off the temp
   container and not off the direct-name first-deploy site. *)
let test_blue_green_temp_container_carries_service_name () =
  match Blue_green.config_of_input input_with_volumes with
  | Error e -> Alcotest.fail ("config refused: " ^ e)
  | Ok config -> (
      let plan = Blue_green.plan config context_with_workload in
      let started =
        List.find_map
          (function
            | Blue_green.RunNewContainer { container_name; config; _ } ->
                Some (container_name, config.labels)
            | Blue_green.CleanupOrphanedContainer _
            | Blue_green.WaitForHealthy _
            | Blue_green.SettleBeforeStop _
            | Blue_green.StopAndRemoveContainer _
            | Blue_green.RenameContainer _ ->
                None)
          plan.success_path
      in
      match started with
      | None -> Alcotest.fail "expected a RunNewContainer action"
      | Some (_, None) -> Alcotest.fail "expected labels on the temp container"
      | Some (container_name, Some labels) ->
          check string "started under the temp name" "my-service-new"
            container_name;
          check (option string) "bondi.name is the service, not the temp name"
            (Some "my-service")
            (List.assoc_opt "bondi.name" labels))

let test_plan_orphan_cleanup () =
  let orphan =
    Server_test_helpers.mk_container ~id:"orphan-id" ~image:"myapp:v0.8"
      ~names:[ "/my-service-new" ] ()
  in
  let context =
    {
      Blue_green.current_workload = Some old_workload;
      temp_read = orphan_temp orphan;
    }
  in
  let plan = Blue_green.plan base_config context in
  match plan.success_path with
  | [] -> Alcotest.fail "expected a non-empty success path"
  | first_action :: _ ->
      check string "first action is cleanup"
        "CleanupOrphanedContainer(orphan-id)"
        (action_string first_action)

let mk_health_log output exit_code : Docker.health_log_entry =
  { output; exit_code }

let test_last_health_output_empty_log () =
  let health = Server_test_helpers.mk_health_state "unhealthy" in
  check (option string) "no output" None (Blue_green.last_health_output health)

let test_last_health_output_returns_last () =
  let log =
    [ mk_health_log "first check" 1; mk_health_log "connection refused" 1 ]
  in
  let health = Server_test_helpers.mk_health_state ~log "unhealthy" in
  check (option string) "last output" (Some "connection refused")
    (Blue_green.last_health_output health)

let test_last_health_output_trims_whitespace () =
  let log = [ mk_health_log "  some output  \n" 1 ] in
  let health = Server_test_helpers.mk_health_state ~log "unhealthy" in
  check (option string) "trimmed" (Some "some output")
    (Blue_green.last_health_output health)

let test_last_health_output_blank_is_none () =
  let log = [ mk_health_log "   " 1 ] in
  let health = Server_test_helpers.mk_health_state ~log "unhealthy" in
  check (option string) "blank is none" None
    (Blue_green.last_health_output health)

let test_health_detail_empty () =
  let health = Server_test_helpers.mk_health_state "unhealthy" in
  check string "no detail" "" (Blue_green.health_detail health)

let test_health_detail_streak_only () =
  let health =
    Server_test_helpers.mk_health_state ~failing_streak:3 "unhealthy"
  in
  check string "streak only" " (3 consecutive failures)"
    (Blue_green.health_detail health)

let test_health_detail_output_only () =
  let log = [ mk_health_log "connection refused" 1 ] in
  let health = Server_test_helpers.mk_health_state ~log "unhealthy" in
  check string "output only" " (last output: connection refused)"
    (Blue_green.health_detail health)

let test_health_detail_streak_and_output () =
  let log = [ mk_health_log "timeout" 1 ] in
  let health =
    Server_test_helpers.mk_health_state ~failing_streak:5 ~log "unhealthy"
  in
  check string "streak and output"
    " (5 consecutive failures, last output: timeout)"
    (Blue_green.health_detail health)

let () =
  run "Blue_green"
    [
      ( "success path",
        [
          test_case "stops the old container while attached" `Quick
            test_success_path_stops_old_while_attached;
          test_case "no existing workload" `Quick
            test_plan_success_path_no_existing_workload;
          test_case "the settle is blue-green's alone" `Quick
            test_settle_is_blue_green_only;
        ] );
      ( "rollback",
        [
          test_case "first deploy targets the container it started" `Quick
            test_first_deploy_rollback_targets_started_container;
          test_case "with the old one serving targets the new" `Quick
            test_rollback_with_old_serving_targets_new;
          test_case "a failed rollback is reported with its cause" `Quick
            test_rollback_failure_reported_with_cause;
        ] );
      ( "temp container",
        [
          test_case "classification" `Quick test_temp_container_classification;
          test_case "a live one is not removed" `Quick
            test_live_new_is_not_removed;
          test_case "completing a swap waits for the workload pull" `Quick
            test_live_completion_after_workload_pull;
          test_case "proxy stop after the pulls, before the workload starts"
            `Quick test_proxy_stop_after_pulls_before_workload_start;
        ] );
      ( "container naming",
        [
          test_case "temp container name" `Quick test_plan_temp_container_name;
          test_case "temp container carries the service name" `Quick
            test_blue_green_temp_container_carries_service_name;
        ] );
      ( "traefik labels",
        [
          test_case "labels on new container" `Quick
            test_plan_traefik_labels_on_new_container;
        ] );
      ( "restart policy",
        [
          test_case "new container carries the policy" `Quick
            test_run_new_container_carries_restart_policy;
        ] );
      ( "volumes",
        [
          test_case "new container carries mounts when replacing a workload"
            `Quick test_new_container_carries_mounts_when_replacing_a_workload;
          test_case "new container carries mounts on first deploy" `Quick
            test_new_container_carries_mounts_on_first_deploy;
          test_case "simple and blue-green mount identically" `Quick
            test_simple_and_blue_green_mount_identically;
        ] );
      ( "orphan cleanup",
        [
          test_case "orphaned container triggers cleanup first" `Quick
            test_plan_orphan_cleanup;
        ] );
      ( "last_health_output",
        [
          test_case "empty log" `Quick test_last_health_output_empty_log;
          test_case "returns last entry" `Quick
            test_last_health_output_returns_last;
          test_case "trims whitespace" `Quick
            test_last_health_output_trims_whitespace;
          test_case "blank is none" `Quick test_last_health_output_blank_is_none;
        ] );
      ( "health_detail",
        [
          test_case "empty" `Quick test_health_detail_empty;
          test_case "streak only" `Quick test_health_detail_streak_only;
          test_case "output only" `Quick test_health_detail_output_only;
          test_case "streak and output" `Quick
            test_health_detail_streak_and_output;
        ] );
    ]
