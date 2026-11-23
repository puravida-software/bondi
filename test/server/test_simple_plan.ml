open Alcotest
module Simple = Bondi_server__Strategy__Simple
module Docker = Bondi_server__Docker__Client
module Image_reference = Bondi_common.Image_reference

let mock_container ~id ~image =
  {
    Docker.id;
    image;
    image_id = "image-id";
    names = [ "/container-name" ];
    state = Some "running";
    status = Some "Up";
    labels = None;
  }

let minimal_input =
  {
    Simple.service_name = Some (Test_helpers.router_name "my-service");
    image = Some (Test_helpers.image_reference "myapp:v1");
    port = Some 8080;
    registry_user = None;
    registry_pass = None;
    env_vars = None;
    traefik_domain_name = Some "example.com";
    traefik_image = Some (Test_helpers.image_reference "traefik:v3.3.0");
    traefik_acme_email = Some "admin@example.com";
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

let input_with_registry =
  {
    minimal_input with
    registry_user = Some "user";
    registry_pass = Some "pass";
  }

let action_string = function
  | Simple.StopAndRemoveContainer _ -> "StopAndRemoveContainer"
  | Simple.PullImage { image; with_auth } ->
      "PullImage("
      ^ Image_reference.name image
      ^ ":"
      ^ Image_reference.pull_tag image
      ^ ","
      ^ string_of_bool with_auth
      ^ ")"
  | Simple.RunWorkload { container_name; _ } ->
      "RunWorkload(" ^ container_name ^ ")"

let test_plan_empty_context_no_traefik () =
  (* traefik_domain_name required for workload labels; traefik_image/acme omitted
     so we skip traefik setup *)
  let context = { Simple.current_workload = None } in
  let input =
    { minimal_input with traefik_image = None; traefik_acme_email = None }
  in
  match Simple.plan input context with
  | Error _ -> Alcotest.fail "plan should succeed with valid input"
  | Ok actions ->
      check (list string) "no traefik setup actions"
        [ "PullImage(myapp:v1,false)"; "RunWorkload(my-service)" ]
        (List.map action_string actions)

(* A declared proxy is not this strategy's to converge: the deploy converges it
   ahead of every strategy, so the plan is the workload's alone. *)
let test_plan_empty_context_with_traefik () =
  let context = { Simple.current_workload = None } in
  match Simple.plan minimal_input context with
  | Error _ -> Alcotest.fail "plan should succeed"
  | Ok actions ->
      check (list string) "the workload alone"
        [ "PullImage(myapp:v1,false)"; "RunWorkload(my-service)" ]
        (List.map action_string actions)

let test_plan_with_existing_workload () =
  let workload = mock_container ~id:"workload-1" ~image:"myapp:v0.9" in
  let context = { Simple.current_workload = Some workload } in
  match Simple.plan minimal_input context with
  | Error _ -> Alcotest.fail "plan should succeed"
  | Ok actions ->
      let has_stop_workload =
        List.exists
          (function
            | Simple.StopAndRemoveContainer _ -> true
            | Simple.PullImage _
            | Simple.RunWorkload _ ->
                false)
          actions
      in
      check bool "includes StopAndRemoveContainer for workload" true
        has_stop_workload

(* The index of the first action satisfying [matches], so an ordering test reads
   positions rather than pinning the whole list. *)
let position_of matches actions =
  let rec go index = function
    | [] -> None
    | action :: rest ->
        if matches action then Some index else go (index + 1) rest
  in
  go 0 actions

let is_pull_of ~image = function
  | Simple.PullImage { image = pulled; _ } ->
      Image_reference.to_string pulled = image
  | Simple.StopAndRemoveContainer _
  | Simple.RunWorkload _ ->
      false

let is_run_workload = function
  | Simple.RunWorkload _ -> true
  | Simple.StopAndRemoveContainer _
  | Simple.PullImage _ ->
      false

let is_stop_of ~container_id = function
  | Simple.StopAndRemoveContainer container ->
      container.Docker.id = container_id
  | Simple.PullImage _
  | Simple.RunWorkload _ ->
      false

let check_before ~first:(first_name, first) ~second:(second_name, second) =
  check bool
    (Printf.sprintf "%s (at %d) precedes %s (at %d)" first_name first
       second_name second)
    true (first < second)

(* A pull that fails must leave the old service running, so the new image is on
   the box before the old container is stopped, and the outage is only the stop,
   remove and start. *)
let test_redeploy_pulls_before_stop () =
  let workload = mock_container ~id:"workload-1" ~image:"myapp:v0.9" in
  let context = { Simple.current_workload = Some workload } in
  match Simple.plan minimal_input context with
  | Error e -> Alcotest.fail ("plan failed: " ^ e)
  | Ok actions -> (
      match
        ( position_of (is_pull_of ~image:"myapp:v1") actions,
          position_of (is_stop_of ~container_id:"workload-1") actions,
          position_of is_run_workload actions )
      with
      | Some pull, Some stop, Some run ->
          check_before ~first:("PullImage", pull)
            ~second:("StopAndRemoveContainer", stop);
          check_before
            ~first:("StopAndRemoveContainer", stop)
            ~second:("RunWorkload", run)
      | None, _, _
      | _, None, _
      | _, _, None ->
          Alcotest.fail
            "expected PullImage, StopAndRemoveContainer of the workload and \
             RunWorkload")

(* A registry with a port puts a second ':' in the reference. Read by a split on
   ':', it named no image, the pull was dropped, and the old service was stopped
   for an image that was never on the box. The pull is of the repository,
   registry and port included, at the declared tag. No Traefik is declared, so
   the service's pull is the only one planned. *)
let test_registry_port_reference_pulls_before_stop () =
  let workload =
    mock_container ~id:"workload-1" ~image:"registry:5000/app:1.2.2"
  in
  let context = { Simple.current_workload = Some workload } in
  let input =
    {
      minimal_input with
      image = Some (Test_helpers.image_reference "registry:5000/app:1.2.3");
      traefik_image = None;
      traefik_acme_email = None;
    }
  in
  match Simple.plan input context with
  | Error e -> Alcotest.fail ("plan failed: " ^ e)
  | Ok actions -> (
      let pulled =
        List.filter_map
          (function
            | Simple.PullImage { image; _ } ->
                Some (Image_reference.name image, Image_reference.pull_tag image)
            | Simple.StopAndRemoveContainer _
            | Simple.RunWorkload _ ->
                None)
          actions
      in
      check
        (list (pair string string))
        "the one pull is the repository at the declared tag"
        [ ("registry:5000/app", "1.2.3") ]
        pulled;
      match
        ( position_of (is_pull_of ~image:"registry:5000/app:1.2.3") actions,
          position_of (is_stop_of ~container_id:"workload-1") actions )
      with
      | Some pull, Some stop ->
          check_before ~first:("PullImage", pull)
            ~second:("StopAndRemoveContainer", stop)
      | None, _
      | _, None ->
          Alcotest.fail
            "expected PullImage and StopAndRemoveContainer of the workload")

let test_plan_with_registry_auth () =
  let context = { Simple.current_workload = None } in
  match Simple.plan input_with_registry context with
  | Error _ -> Alcotest.fail "plan should succeed"
  | Ok actions -> (
      let pull = List.find_opt (is_pull_of ~image:"myapp:v1") actions in
      match pull with
      | Some (Simple.PullImage { with_auth; _ }) ->
          check bool "PullImage uses auth" true with_auth
      | Some (Simple.StopAndRemoveContainer _)
      | Some (Simple.RunWorkload _)
      | None ->
          Alcotest.fail "expected PullImage with auth")

let test_plan_cron_only_skips_workload () =
  let input =
    {
      minimal_input with
      traefik_domain_name = None;
      traefik_image = Some (Test_helpers.image_reference "traefik:v3");
      traefik_acme_email = Some "a@b.com";
    }
  in
  let context = { Simple.current_workload = None } in
  match Simple.plan input context with
  | Error _ -> Alcotest.fail "plan should succeed for cron-only (no workload)"
  | Ok actions ->
      let has_workload =
        List.exists
          (function
            | Simple.PullImage _
            | Simple.RunWorkload _ ->
                true
            | Simple.StopAndRemoveContainer _ -> false)
          actions
      in
      check bool "no workload actions when traefik_domain_name is None" false
        has_workload

let extract_workload_labels actions =
  List.find_map
    (function
      | Simple.RunWorkload { config; _ } -> config.labels
      | Simple.StopAndRemoveContainer _
      | Simple.PullImage _ ->
          None)
    actions

let extract_workload_host_config actions =
  List.find_map
    (function
      | Simple.RunWorkload { host_config; _ } -> Some host_config
      | Simple.StopAndRemoveContainer _
      | Simple.PullImage _ ->
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

let test_run_workload_carries_restart_policy () =
  let context = { Simple.current_workload = None } in
  match Simple.plan minimal_input context with
  | Error e -> Alcotest.fail ("plan failed: " ^ e)
  | Ok actions -> (
      match extract_workload_host_config actions with
      | None -> Alcotest.fail "expected a RunWorkload action"
      | Some host_config ->
          check_planned_restart_policy "planned workload" host_config)

let mount_testable = Server_test_helpers.mount_testable
let bind_mount = Test_helpers.bind_mount

(* One read-write and one read-only volume, so a plan that dropped either the
   second entry or the flag would show. *)
let input_with_volumes =
  {
    minimal_input with
    volumes =
      Some
        [
          bind_mount ~host:"/srv/comalito/invoices" ~container:"/app/invoices"
            ~read_only:false;
          bind_mount ~host:"/etc/comalito" ~container:"/app/config"
            ~read_only:true;
        ];
  }

let planned_workload_mounts input =
  let context = { Simple.current_workload = None } in
  match Simple.plan input context with
  | Error e -> Alcotest.fail ("plan failed: " ^ e)
  | Ok actions -> (
      match extract_workload_host_config actions with
      | None -> Alcotest.fail "expected a RunWorkload action"
      | Some host_config -> host_config.mounts)

let test_run_workload_carries_declared_mounts () =
  check
    (option (list mount_testable))
    "one bind mount per declared volume, in order"
    (Some
       [
         {
           Docker.type_ = "bind";
           source = "/srv/comalito/invoices";
           target = "/app/invoices";
           read_only = false;
         };
         {
           Docker.type_ = "bind";
           source = "/etc/comalito";
           target = "/app/config";
           read_only = true;
         };
       ])
    (planned_workload_mounts input_with_volumes)

(* The absence arm of the case above: the same fixture with its volumes taken
   away plans a workload with no Mounts key at all. *)
let test_run_workload_without_volumes_carries_no_mounts () =
  check
    (option (list mount_testable))
    "no mounts" None
    (planned_workload_mounts { input_with_volumes with volumes = None })

let test_deploy_adds_bondi_managed_label () =
  let context = { Simple.current_workload = None } in
  match Simple.plan minimal_input context with
  | Error e -> Alcotest.fail ("plan failed: " ^ e)
  | Ok actions -> (
      match extract_workload_labels actions with
      | None -> Alcotest.fail "expected labels on workload container"
      | Some labels ->
          check bool "has bondi.managed=true" true
            (List.mem ("bondi.managed", "true") labels))

let test_deploy_adds_bondi_type_label () =
  let context = { Simple.current_workload = None } in
  match Simple.plan minimal_input context with
  | Error e -> Alcotest.fail ("plan failed: " ^ e)
  | Ok actions -> (
      match extract_workload_labels actions with
      | None -> Alcotest.fail "expected labels on workload container"
      | Some labels ->
          check bool "has bondi.type=service" true
            (List.mem ("bondi.type", "service") labels))

let test_deploy_adds_bondi_logs_label () =
  let context = { Simple.current_workload = None } in
  match Simple.plan minimal_input context with
  | Error e -> Alcotest.fail ("plan failed: " ^ e)
  | Ok actions -> (
      match extract_workload_labels actions with
      | None -> Alcotest.fail "expected labels on workload container"
      | Some labels ->
          check bool "has bondi.logs label" true
            (List.exists (fun (k, _) -> k = "bondi.logs") labels))

let test_service_labels_carry_service_name () =
  let context = { Simple.current_workload = None } in
  match Simple.plan minimal_input context with
  | Error e -> Alcotest.fail ("plan failed: " ^ e)
  | Ok actions -> (
      match extract_workload_labels actions with
      | None -> Alcotest.fail "expected labels on workload container"
      | Some labels ->
          check (option string) "bondi.name is the service name"
            (Some "my-service")
            (List.assoc_opt "bondi.name" labels))

(* Two services behind one Traefik feed one load balancer if they share a
   router or service name, so each is named after its own service. The keys are
   the ones Traefik v3.6.8 was observed to serve a container by: the router's
   rule and entrypoints and the service's load-balancer port. *)
let test_router_named_after_service () =
  let context = { Simple.current_workload = None } in
  let traefik_keys service_name =
    match
      Simple.plan
        {
          minimal_input with
          service_name = Some (Test_helpers.router_name service_name);
        }
        context
    with
    | Error e -> Alcotest.failf "plan for %s failed: %s" service_name e
    | Ok actions -> (
        match extract_workload_labels actions with
        | None -> Alcotest.fail "expected labels on workload container"
        | Some labels ->
            List.map fst labels
            |> List.filter (fun key ->
                String.starts_with ~prefix:"traefik.http.routers." key
                || String.starts_with ~prefix:"traefik.http.services." key))
  in
  let expected name =
    [
      "traefik.http.routers." ^ name ^ ".rule";
      "traefik.http.routers." ^ name ^ ".entrypoints";
      "traefik.http.routers." ^ name ^ ".tls";
      "traefik.http.routers." ^ name ^ ".tls.certresolver";
      "traefik.http.routers." ^ name ^ ".middlewares";
      "traefik.http.services." ^ name ^ ".loadbalancer.server.port";
    ]
  in
  let api = traefik_keys "api" and web = traefik_keys "web-app" in
  check (list string) "the api service's keys are named api" (expected "api")
    api;
  check (list string) "the web-app service's keys are named web-app"
    (expected "web-app") web;
  check (list string) "the two services share no key" []
    (List.filter (fun key -> List.mem key web) api);
  check (list string) "no key is named bondi" []
    (List.filter
       (fun key -> Bondi_common.String_utils.contains ~needle:".bondi." key)
       (api @ web))

let planned_labels_for service_name =
  match
    Simple.plan
      {
        minimal_input with
        service_name = Some (Test_helpers.router_name service_name);
      }
      { Simple.current_workload = None }
  with
  | Error e -> Alcotest.failf "plan for %s failed: %s" service_name e
  | Ok actions -> (
      match extract_workload_labels actions with
      | None -> Alcotest.fail "expected labels on workload container"
      | Some labels -> labels)

(* The router names its own retry middleware, and the middleware is declared on
   the same container. Four attempts is the count the swap measurements settled
   on (feature 0041, NFR-1, Step B).
   The interval is Traefik v3.6's documented default, 0 (retry at once, no
   backoff), which is what those swaps ran with since they left it unset; it is
   written out so a later change of Traefik's default does not change it. *)
let test_router_carries_retry_middleware () =
  let labels = planned_labels_for "my-service" in
  check (option string) "the router uses the service's retry middleware"
    (Some "my-service-retry")
    (List.assoc_opt "traefik.http.routers.my-service.middlewares" labels);
  check (option string) "four attempts" (Some "4")
    (List.assoc_opt "traefik.http.middlewares.my-service-retry.retry.attempts"
       labels);
  check (option string) "the documented default interval, written out"
    (Some "0")
    (List.assoc_opt
       "traefik.http.middlewares.my-service-retry.retry.initialinterval" labels)

(* Two services behind one Traefik each declare a middleware. Sharing a name,
   the two declarations would be one middleware defined twice, which Traefik
   reports as a conflict, so each is named after its own service. *)
let test_retry_middleware_named_per_service () =
  let middleware_of service_name =
    List.assoc_opt
      ("traefik.http.routers." ^ service_name ^ ".middlewares")
      (planned_labels_for service_name)
  in
  let declared service_name =
    List.filter_map
      (fun (key, _) ->
        match String.split_on_char '.' key with
        | [ "traefik"; "http"; "middlewares"; name; "retry"; _ ] -> Some name
        | _ -> None)
      (planned_labels_for service_name)
    |> List.sort_uniq String.compare
  in
  check (option string) "api's router uses api-retry" (Some "api-retry")
    (middleware_of "api");
  check (option string) "web-app's router uses web-app-retry"
    (Some "web-app-retry") (middleware_of "web-app");
  check (list string) "api declares only api-retry" [ "api-retry" ]
    (declared "api");
  check (list string) "web-app declares only web-app-retry" [ "web-app-retry" ]
    (declared "web-app")

(* A reference with no tag and no digest is the one the engine resolves as
   [latest]. The registry-port case is the one a split on ':' read as a tag. *)
let test_service_image_reference () =
  let reference = Test_helpers.image_reference in
  check string "untagged gains :latest" "myapp:latest"
    (Simple.service_image_reference (reference "myapp"));
  check string "untagged behind a registry port gains :latest"
    "registry:5000/app:latest"
    (Simple.service_image_reference (reference "registry:5000/app"));
  check string "tagged is kept" "myapp:v1"
    (Simple.service_image_reference (reference "myapp:v1"));
  check string "a digest is kept as written"
    ("old/worker@sha256:" ^ String.make 64 'a')
    (Simple.service_image_reference
       (reference ("old/worker@sha256:" ^ String.make 64 'a')))

let () =
  run "Simple.plan"
    [
      ( "empty context",
        [
          test_case "no traefik config" `Quick
            test_plan_empty_context_no_traefik;
          test_case "with traefik config, the workload alone" `Quick
            test_plan_empty_context_with_traefik;
        ] );
      ( "existing containers",
        [
          test_case "stops existing workload" `Quick
            test_plan_with_existing_workload;
        ] );
      ( "ordering",
        [
          test_case "redeploy pulls before it stops" `Quick
            test_redeploy_pulls_before_stop;
          test_case "a registry-port reference pulls before it stops" `Quick
            test_registry_port_reference_pulls_before_stop;
        ] );
      ( "registry",
        [
          test_case "uses auth when registry credentials provided" `Quick
            test_plan_with_registry_auth;
        ] );
      ( "validation",
        [
          test_case "skips workload when traefik_domain_name is None" `Quick
            test_plan_cron_only_skips_workload;
        ] );
      ( "restart policy",
        [
          test_case "run workload carries the policy" `Quick
            test_run_workload_carries_restart_policy;
        ] );
      ( "volumes",
        [
          test_case "run workload carries declared mounts" `Quick
            test_run_workload_carries_declared_mounts;
          test_case "run workload without volumes carries no mounts" `Quick
            test_run_workload_without_volumes_carries_no_mounts;
        ] );
      ( "image reference",
        [
          test_case "service image reference" `Quick
            test_service_image_reference;
        ] );
      ( "container labels",
        [
          test_case "adds bondi.managed label" `Quick
            test_deploy_adds_bondi_managed_label;
          test_case "adds bondi.type label" `Quick
            test_deploy_adds_bondi_type_label;
          test_case "adds bondi.logs label" `Quick
            test_deploy_adds_bondi_logs_label;
          test_case "carries the service name" `Quick
            test_service_labels_carry_service_name;
          test_case "router named after the service" `Quick
            test_router_named_after_service;
          test_case "router carries the retry middleware" `Quick
            test_router_carries_retry_middleware;
          test_case "retry middleware named per service" `Quick
            test_retry_middleware_named_per_service;
        ] );
    ]
