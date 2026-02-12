open Alcotest
module Simple = Bondi_server__Strategy__Simple
module Docker = Bondi_server__Docker__Client

let mock_container ~id ~image =
  {
    Docker.id;
    image;
    image_id = "image-id";
    names = [ "/container-name" ];
    state = Some "running";
    status = Some "Up";
  }

let minimal_input =
  {
    Simple.image_name = "myapp";
    tag = "v1";
    port = 8080;
    registry_user = None;
    registry_pass = None;
    env_vars = None;
    traefik_domain_name = Some "example.com";
    traefik_image = Some "traefik:v3.3.0";
    traefik_acme_email = Some "admin@example.com";
    force_traefik_redeploy = None;
    cron_jobs = None;
  }

let input_with_registry =
  {
    minimal_input with
    registry_user = Some "user";
    registry_pass = Some "pass";
  }

let action_string = function
  | Simple.CreateNetwork { network_name } ->
      "CreateNetwork(" ^ network_name ^ ")"
  | Simple.EnsureTraefik _ -> "EnsureTraefik"
  | Simple.StopAndRemoveContainer _ -> "StopAndRemoveContainer"
  | Simple.PullImage { image; tag; with_auth } ->
      "PullImage(" ^ image ^ ":" ^ tag ^ "," ^ string_of_bool with_auth ^ ")"
  | Simple.RunWorkload { container_name; _ } ->
      "RunWorkload(" ^ container_name ^ ")"

let test_plan_empty_context_no_traefik () =
  (* traefik_domain_name required for workload labels; traefik_image/acme omitted
     so we skip traefik setup *)
  let context = { Simple.current_traefik = None; current_workload = None } in
  let input =
    { minimal_input with traefik_image = None; traefik_acme_email = None }
  in
  match Simple.plan input context with
  | Error _ -> Alcotest.fail "plan should succeed with valid input"
  | Ok actions ->
      check (list string) "no traefik setup actions"
        [ "PullImage(myapp:v1,false)"; "RunWorkload(bondi-workload)" ]
        (List.map action_string actions)

let test_plan_empty_context_with_traefik () =
  let context = { Simple.current_traefik = None; current_workload = None } in
  match Simple.plan minimal_input context with
  | Error _ -> Alcotest.fail "plan should succeed"
  | Ok actions ->
      check (list string) "includes traefik setup"
        [
          "CreateNetwork(bondi-network)";
          "EnsureTraefik";
          "PullImage(myapp:v1,false)";
          "RunWorkload(bondi-workload)";
        ]
        (List.map action_string actions)

let test_plan_with_existing_workload () =
  let workload = mock_container ~id:"workload-1" ~image:"myapp:v0.9" in
  let context =
    { Simple.current_traefik = None; current_workload = Some workload }
  in
  match Simple.plan minimal_input context with
  | Error _ -> Alcotest.fail "plan should succeed"
  | Ok actions ->
      let has_stop_workload =
        List.exists
          (function
            | Simple.StopAndRemoveContainer _ -> true
            | _ -> false)
          actions
      in
      check bool "includes StopAndRemoveContainer for workload" true
        has_stop_workload

let test_plan_traefik_version_mismatch () =
  let traefik = mock_container ~id:"traefik-1" ~image:"traefik:v2.0" in
  let context =
    { Simple.current_traefik = Some traefik; current_workload = None }
  in
  match Simple.plan minimal_input context with
  | Error _ -> Alcotest.fail "plan should succeed"
  | Ok actions ->
      let action_strs = List.map action_string actions in
      check bool "includes StopAndRemoveContainer for traefik"
        (List.mem "StopAndRemoveContainer" action_strs)
        true;
      check bool "includes EnsureTraefik"
        (List.mem "EnsureTraefik" action_strs)
        true

let test_plan_traefik_same_version_skips_redeploy () =
  let traefik = mock_container ~id:"traefik-1" ~image:"traefik:v3.3.0" in
  let context =
    { Simple.current_traefik = Some traefik; current_workload = None }
  in
  match Simple.plan minimal_input context with
  | Error _ -> Alcotest.fail "plan should succeed"
  | Ok actions ->
      let action_strs = List.map action_string actions in
      check bool "does not include StopAndRemoveContainer for traefik"
        (List.mem "StopAndRemoveContainer" action_strs)
        false;
      check bool "does not include EnsureTraefik"
        (List.mem "EnsureTraefik" action_strs)
        false;
      check bool "includes CreateNetwork"
        (List.mem "CreateNetwork(bondi-network)" action_strs)
        true

let test_plan_with_registry_auth () =
  let context = { Simple.current_traefik = None; current_workload = None } in
  match Simple.plan input_with_registry context with
  | Error _ -> Alcotest.fail "plan should succeed"
  | Ok actions -> (
      let pull =
        List.find_opt
          (function
            | Simple.PullImage _ -> true
            | _ -> false)
          actions
      in
      match pull with
      | Some (Simple.PullImage { with_auth; _ }) ->
          check bool "PullImage uses auth" true with_auth
      | _ -> Alcotest.fail "expected PullImage with auth")

let test_plan_cron_only_skips_workload () =
  let input =
    {
      minimal_input with
      traefik_domain_name = None;
      traefik_image = Some "traefik:v3";
      traefik_acme_email = Some "a@b.com";
    }
  in
  let context = { Simple.current_traefik = None; current_workload = None } in
  match Simple.plan input context with
  | Error _ -> Alcotest.fail "plan should succeed for cron-only (no workload)"
  | Ok actions ->
      let has_workload =
        List.exists
          (function
            | Simple.PullImage _ | Simple.RunWorkload _ -> true
            | _ -> false)
          actions
      in
      check bool "no workload actions when traefik_domain_name is None" false
        has_workload

let () =
  run "Simple.plan"
    [
      ( "empty context",
        [
          test_case "no traefik config" `Quick
            test_plan_empty_context_no_traefik;
          test_case "with traefik config" `Quick
            test_plan_empty_context_with_traefik;
        ] );
      ( "existing containers",
        [
          test_case "stops existing workload" `Quick
            test_plan_with_existing_workload;
          test_case "redeploys traefik on version mismatch" `Quick
            test_plan_traefik_version_mismatch;
          test_case "skips traefik redeploy when same version" `Quick
            test_plan_traefik_same_version_skips_redeploy;
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
    ]
