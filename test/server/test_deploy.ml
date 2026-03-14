module Deploy = Bondi_server__Deploy
module Simple = Bondi_server__Strategy__Simple

let minimal_input =
  {
    Simple.service_name = Some "my-service";
    image = Some "myapp:v1";
    port = Some 8080;
    registry_user = None;
    registry_pass = None;
    env_vars = None;
    traefik_domain_name = Some "example.com";
    traefik_image = Some "traefik:v3.3.0";
    traefik_acme_email = Some "admin@example.com";
    force_traefik_redeploy = None;
    cron_jobs = None;
    drain_grace_period = None;
    deployment_strategy = None;
    health_timeout = None;
    poll_interval = None;
    logs = None;
  }

let action_string = function
  | Deploy.PullCronImages _ -> "PullCronImages"
  | Deploy.UpsertCrontab jobs -> (
      match jobs with
      | None -> "UpsertCrontab(None)"
      | Some jobs -> "UpsertCrontab(" ^ string_of_int (List.length jobs) ^ ")")

let result_testable ok_t =
  Alcotest.testable
    (fun fmt r ->
      match r with
      | Ok v -> Fmt.pf fmt "Ok(%a)" (Alcotest.pp ok_t) v
      | Error msg -> Fmt.pf fmt "Error(%s)" msg)
    (fun a b ->
      match (a, b) with
      | Ok a, Ok b -> Alcotest.equal ok_t a b
      | Error a, Error b -> String.equal a b
      | _ -> false)

let test_serveraddress_from_image () =
  Alcotest.check
    (result_testable Alcotest.string)
    "registry from full image" (Ok "registry.gitlab.com")
    (Deploy.serveraddress_from_image "registry.gitlab.com/org/repo:v1.2.3");
  (match Deploy.serveraddress_from_image "nginx:latest" with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "expected error for image without registry");
  Alcotest.check
    (result_testable Alcotest.string)
    "first path component" (Ok "library")
    (Deploy.serveraddress_from_image "library/nginx")

let test_tag_from_image () =
  Alcotest.check Alcotest.string "extracts tag" "v1.2.3"
    (Deploy.tag_from_image "registry.example.com/app:v1.2.3");
  Alcotest.check Alcotest.string "unknown when no tag" "unknown"
    (Deploy.tag_from_image "registry.example.com/app")

let test_image_name_and_tag () =
  Alcotest.check
    (result_testable (Alcotest.pair Alcotest.string Alcotest.string))
    "name and tag"
    (Ok ("backup", "v1"))
    (Deploy.image_name_and_tag "backup:v1");
  match Deploy.image_name_and_tag "backup" with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "expected error for missing tag"

let test_build_response () =
  let input = { minimal_input with image = Some "app:v2.0" } in
  let response =
    Deploy.build_response ~strategy:Deploy.Simple
      ~strategy_reason:"image has no HEALTHCHECK" input
  in
  Alcotest.check Alcotest.string "status" "Deploy initiated" response.status;
  Alcotest.check Alcotest.string "tag" "v2.0" response.tag;
  Alcotest.check Alcotest.string "strategy" "simple" response.strategy;
  Alcotest.check Alcotest.string "strategy_reason" "image has no HEALTHCHECK"
    response.strategy_reason

let test_cron_plan_empty_cron_jobs () =
  let input = { minimal_input with cron_jobs = Some [] } in
  let actions = Deploy.cron_plan input in
  Alcotest.check
    (Alcotest.list Alcotest.string)
    "no cron actions when cron_jobs is empty" []
    (List.map action_string actions)

let test_cron_plan_with_cron_jobs () =
  let cron =
    {
      Simple.name = "backup";
      image = "backup:v1";
      schedule = "0 0 * * *";
      env_vars = None;
      registry_user = None;
      registry_pass = None;
    }
  in
  let input = { minimal_input with cron_jobs = Some [ cron ] } in
  let actions = Deploy.cron_plan input in
  Alcotest.check
    (Alcotest.list Alcotest.string)
    "includes PullCronImages and UpsertCrontab"
    [ "PullCronImages"; "UpsertCrontab(1)" ]
    (List.map action_string actions)

let test_cron_plan_no_cron_jobs () =
  let actions = Deploy.cron_plan minimal_input in
  Alcotest.check
    (Alcotest.list Alcotest.string)
    "no cron actions when cron_jobs is None" []
    (List.map action_string actions)

let test_deploy_response_with_strategy_json () =
  let response : Deploy.deploy_response =
    {
      status = "Deploy initiated";
      tag = "v2.0";
      strategy = "blue-green";
      strategy_reason = "image has HEALTHCHECK";
    }
  in
  let json = Deploy.deploy_response_to_yojson response in
  let strategy =
    Yojson.Safe.Util.member "strategy" json |> Yojson.Safe.Util.to_string
  in
  let strategy_reason =
    Yojson.Safe.Util.member "strategy_reason" json |> Yojson.Safe.Util.to_string
  in
  Alcotest.check Alcotest.string "strategy field" "blue-green" strategy;
  Alcotest.check Alcotest.string "strategy_reason field" "image has HEALTHCHECK"
    strategy_reason

let test_deploy_response_simple_strategy_json () =
  let response : Deploy.deploy_response =
    {
      status = "Deploy initiated";
      tag = "v1.0";
      strategy = "simple";
      strategy_reason = "image has no HEALTHCHECK";
    }
  in
  let json = Deploy.deploy_response_to_yojson response in
  let strategy =
    Yojson.Safe.Util.member "strategy" json |> Yojson.Safe.Util.to_string
  in
  let strategy_reason =
    Yojson.Safe.Util.member "strategy_reason" json |> Yojson.Safe.Util.to_string
  in
  Alcotest.check Alcotest.string "strategy field" "simple" strategy;
  Alcotest.check Alcotest.string "strategy_reason field"
    "image has no HEALTHCHECK" strategy_reason

let test_deployment_strategy_of_string_blue_green () =
  Alcotest.check
    (Alcotest.option Alcotest.string)
    "blue-green parses" (Some "blue-green")
    (Option.map Deploy.string_of_deployment_strategy
       (Deploy.deployment_strategy_of_string "blue-green"))

let test_deployment_strategy_of_string_simple () =
  Alcotest.check
    (Alcotest.option Alcotest.string)
    "simple parses" (Some "simple")
    (Option.map Deploy.string_of_deployment_strategy
       (Deploy.deployment_strategy_of_string "simple"))

let test_deployment_strategy_of_string_unknown () =
  Alcotest.check
    (Alcotest.option Alcotest.string)
    "unknown returns None" None
    (Option.map Deploy.string_of_deployment_strategy
       (Deploy.deployment_strategy_of_string "unknown"))

let test_string_of_deployment_strategy () =
  Alcotest.check Alcotest.string "Simple to string" "simple"
    (Deploy.string_of_deployment_strategy Deploy.Simple);
  Alcotest.check Alcotest.string "Blue_green to string" "blue-green"
    (Deploy.string_of_deployment_strategy Deploy.Blue_green)

let test_deploy_input_logs_flag () =
  let input = { minimal_input with logs = Some false } in
  Alcotest.check
    (Alcotest.option Alcotest.bool)
    "logs is Some false" (Some false) input.logs;
  (* Round-trip through yojson *)
  let json = Simple.deploy_input_to_yojson input in
  let decoded =
    match Simple.deploy_input_of_yojson json with
    | Ok v -> v
    | Error msg -> Alcotest.fail ("unexpected error: " ^ msg)
  in
  Alcotest.check
    (Alcotest.option Alcotest.bool)
    "logs survives JSON round-trip" (Some false) decoded.logs;
  (* Default when absent *)
  let input_no_logs = { minimal_input with logs = None } in
  let json2 = Simple.deploy_input_to_yojson input_no_logs in
  let decoded2 =
    match Simple.deploy_input_of_yojson json2 with
    | Ok v -> v
    | Error msg -> Alcotest.fail ("unexpected error: " ^ msg)
  in
  Alcotest.check
    (Alcotest.option Alcotest.bool)
    "logs defaults to None" None decoded2.logs

let () =
  Alcotest.run "Deploy"
    [
      ( "pure helpers",
        [
          Alcotest.test_case "serveraddress_from_image" `Quick
            test_serveraddress_from_image;
          Alcotest.test_case "tag_from_image" `Quick test_tag_from_image;
          Alcotest.test_case "image_name_and_tag" `Quick test_image_name_and_tag;
          Alcotest.test_case "build_response" `Quick test_build_response;
        ] );
      ( "cron plan",
        [
          Alcotest.test_case "no cron jobs" `Quick test_cron_plan_no_cron_jobs;
          Alcotest.test_case "empty cron jobs" `Quick
            test_cron_plan_empty_cron_jobs;
          Alcotest.test_case "with cron jobs" `Quick
            test_cron_plan_with_cron_jobs;
        ] );
      ( "response",
        [
          Alcotest.test_case "response with strategy fields" `Quick
            test_deploy_response_with_strategy_json;
          Alcotest.test_case "simple strategy response" `Quick
            test_deploy_response_simple_strategy_json;
        ] );
      ( "logs flag",
        [
          Alcotest.test_case "deploy_input logs flag" `Quick
            test_deploy_input_logs_flag;
        ] );
      ( "strategy dispatch",
        [
          Alcotest.test_case "deployment_strategy_of_string blue-green" `Quick
            test_deployment_strategy_of_string_blue_green;
          Alcotest.test_case "deployment_strategy_of_string simple" `Quick
            test_deployment_strategy_of_string_simple;
          Alcotest.test_case "deployment_strategy_of_string unknown" `Quick
            test_deployment_strategy_of_string_unknown;
          Alcotest.test_case "string_of_deployment_strategy roundtrip" `Quick
            test_string_of_deployment_strategy;
        ] );
    ]
