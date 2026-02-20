open Alcotest
module Deploy = Bondi_client.Cmd.Deploy
module Config_file = Bondi_client.Config_file

let result_testable ok_t =
  testable
    (fun fmt r ->
      match r with
      | Ok v -> Fmt.pf fmt "Ok(%a)" (pp ok_t) v
      | Error msg -> Fmt.pf fmt "Error(%s)" msg)
    (fun a b ->
      match (a, b) with
      | Ok a, Ok b -> equal ok_t a b
      | Error a, Error b -> String.equal a b
      | _ -> false)

(* parse_name_tag *)

let test_parse_name_tag_valid () =
  check
    (result_testable (pair string string))
    "valid name:tag"
    (Ok ("my-service", "v1.2.3"))
    (Deploy.parse_name_tag "my-service:v1.2.3")

let test_parse_name_tag_missing_tag () =
  match Deploy.parse_name_tag "my-service" with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "expected error for missing tag"

let test_parse_name_tag_empty () =
  match Deploy.parse_name_tag "" with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "expected error for empty input"

let test_parse_name_tag_colon_in_tag () =
  check
    (result_testable (pair string string))
    "colon in tag"
    (Ok ("name", "tag:extra"))
    (Deploy.parse_name_tag "name:tag:extra")

(* validate_deployments *)

let mk_config ?user_service ?cron_jobs () : Config_file.t =
  {
    user_service;
    bondi_server = { version = "0.1.0" };
    traefik = None;
    cron_jobs;
  }

let mk_service name : Config_file.user_service =
  {
    name;
    image = "img";
    port = 8080;
    registry_user = None;
    registry_pass = None;
    env_vars = [];
    servers = [];
  }

let mk_cron_job name ip : Config_file.cron_job =
  {
    name;
    image = "img";
    schedule = "* * * * *";
    env_vars = None;
    registry_user = None;
    registry_pass = None;
    server = { ip_address = ip; ssh = None };
  }

let test_validate_deployments_valid () =
  let config =
    mk_config ~user_service:(mk_service "web")
      ~cron_jobs:[ mk_cron_job "backup" "1.2.3.4" ]
      ()
  in
  match
    Deploy.validate_deployments config [ ("web", "v1"); ("backup", "v2") ]
  with
  | Ok _ -> ()
  | Error msg -> Alcotest.fail ("unexpected error: " ^ msg)

let test_validate_deployments_unknown () =
  let config = mk_config ~user_service:(mk_service "web") () in
  match Deploy.validate_deployments config [ ("unknown", "v1") ] with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "expected error for unknown target"

let test_validate_deployments_empty () =
  let config = mk_config ~user_service:(mk_service "web") () in
  match Deploy.validate_deployments config [] with
  | Ok _ -> ()
  | Error _ -> Alcotest.fail "empty list should be valid"

(* cron_jobs_for_server *)

let test_cron_jobs_for_server_matching () =
  let jobs = [ mk_cron_job "backup" "1.2.3.4" ] in
  let deployments = [ ("backup", "v1") ] in
  match Deploy.cron_jobs_for_server "1.2.3.4" (Some jobs) deployments with
  | Some [ j ] ->
      check string "job name" "backup" j.name;
      check string "image has tag" "img:v1" j.image
  | _ -> Alcotest.fail "expected one matching job"

let test_cron_jobs_for_server_non_matching () =
  let jobs = [ mk_cron_job "backup" "1.2.3.4" ] in
  let deployments = [ ("backup", "v1") ] in
  match Deploy.cron_jobs_for_server "5.6.7.8" (Some jobs) deployments with
  | None -> ()
  | Some _ -> Alcotest.fail "expected no matching jobs for different server"

let test_cron_jobs_for_server_none () =
  let deployments = [ ("backup", "v1") ] in
  match Deploy.cron_jobs_for_server "1.2.3.4" None deployments with
  | None -> ()
  | Some _ -> Alcotest.fail "expected None when no cron jobs"

(* cron_job_to_deploy *)

let test_cron_job_to_deploy () =
  let job = mk_cron_job "backup" "1.2.3.4" in
  let result = Deploy.cron_job_to_deploy job ~image:"img:v1" in
  check string "name" "backup" result.name;
  check string "image" "img:v1" result.image;
  check string "schedule" "* * * * *" result.schedule

let () =
  run "Deploy_helpers"
    [
      ( "parse_name_tag",
        [
          test_case "valid name:tag" `Quick test_parse_name_tag_valid;
          test_case "missing tag" `Quick test_parse_name_tag_missing_tag;
          test_case "empty input" `Quick test_parse_name_tag_empty;
          test_case "colon in tag" `Quick test_parse_name_tag_colon_in_tag;
        ] );
      ( "validate_deployments",
        [
          test_case "valid targets" `Quick test_validate_deployments_valid;
          test_case "unknown target" `Quick test_validate_deployments_unknown;
          test_case "empty list" `Quick test_validate_deployments_empty;
        ] );
      ( "cron_jobs_for_server",
        [
          test_case "matching server" `Quick test_cron_jobs_for_server_matching;
          test_case "non-matching server" `Quick
            test_cron_jobs_for_server_non_matching;
          test_case "no cron jobs" `Quick test_cron_jobs_for_server_none;
        ] );
      ( "cron_job_to_deploy",
        [ test_case "correct field mapping" `Quick test_cron_job_to_deploy ] );
    ]
