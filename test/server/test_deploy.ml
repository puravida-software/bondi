module Deploy = Bondi_server__Deploy
module Simple = Bondi_server__Strategy__Simple

let minimal_input =
  {
    Simple.image = "myapp:v1";
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

let action_string = function
  | Deploy.DeployWorkload -> "DeployWorkload"
  | Deploy.PullCronImages _ -> "PullCronImages"
  | Deploy.UpsertCrontab jobs -> (
      match jobs with
      | None -> "UpsertCrontab(None)"
      | Some jobs -> "UpsertCrontab(" ^ string_of_int (List.length jobs) ^ ")")

let test_serveraddress_from_image () =
  Alcotest.check Alcotest.string "registry from full image"
    "registry.gitlab.com"
    (Deploy.serveraddress_from_image "registry.gitlab.com/org/repo:v1.2.3");
  Alcotest.check Alcotest.string "image name when no registry (nginx:latest)"
    "nginx"
    (Deploy.serveraddress_from_image "nginx:latest");
  Alcotest.check Alcotest.string "first path component" "library"
    (Deploy.serveraddress_from_image "library/nginx")

let test_tag_from_image () =
  Alcotest.check Alcotest.string "extracts tag" "v1.2.3"
    (Deploy.tag_from_image "registry.example.com/app:v1.2.3");
  Alcotest.check Alcotest.string "defaults to latest" "latest"
    (Deploy.tag_from_image "registry.example.com/app")

let test_parse_cron_image () =
  Alcotest.check
    (Alcotest.pair Alcotest.string Alcotest.string)
    "name and tag" ("backup", "v1")
    (Deploy.parse_cron_image "backup:v1");
  Alcotest.check
    (Alcotest.pair Alcotest.string Alcotest.string)
    "default tag" ("backup", "latest")
    (Deploy.parse_cron_image "backup")

let test_build_response () =
  let input = { minimal_input with image = "app:v2.0" } in
  let response = Deploy.build_response input in
  Alcotest.check Alcotest.string "status" "Deploy initiated" response.status;
  Alcotest.check Alcotest.string "tag" "v2.0" response.tag

let test_plan_empty_cron_jobs () =
  let input = { minimal_input with cron_jobs = Some [] } in
  let actions = Deploy.plan input in
  Alcotest.check
    (Alcotest.list Alcotest.string)
    "UpsertCrontab with empty list (clears bondi section)"
    [ "DeployWorkload"; "UpsertCrontab(0)" ]
    (List.map action_string actions)

let test_plan_with_cron_jobs () =
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
  let actions = Deploy.plan input in
  Alcotest.check
    (Alcotest.list Alcotest.string)
    "includes PullCronImages and UpsertCrontab"
    [ "DeployWorkload"; "PullCronImages"; "UpsertCrontab(1)" ]
    (List.map action_string actions)

let test_plan_no_cron_jobs () =
  let actions = Deploy.plan minimal_input in
  Alcotest.check
    (Alcotest.list Alcotest.string)
    "DeployWorkload + UpsertCrontab(None)"
    [ "DeployWorkload"; "UpsertCrontab(None)" ]
    (List.map action_string actions)

let () =
  Alcotest.run "Deploy"
    [
      ( "pure helpers",
        [
          Alcotest.test_case "serveraddress_from_image" `Quick
            test_serveraddress_from_image;
          Alcotest.test_case "tag_from_image" `Quick test_tag_from_image;
          Alcotest.test_case "parse_cron_image" `Quick test_parse_cron_image;
          Alcotest.test_case "build_response" `Quick test_build_response;
        ] );
      ( "plan",
        [
          Alcotest.test_case "no cron jobs" `Quick test_plan_no_cron_jobs;
          Alcotest.test_case "empty cron jobs" `Quick test_plan_empty_cron_jobs;
          Alcotest.test_case "with cron jobs" `Quick test_plan_with_cron_jobs;
        ] );
    ]
