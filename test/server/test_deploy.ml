module Deploy = Bondi_server__Deploy
module Simple = Bondi_server__Strategy__Simple
module Crontab = Bondi_server__Crontab
module Run = Bondi_server__Run
module Alert = Bondi_common.Alert
module Client_deploy = Bondi_client.Cmd.Deploy
module Client_config = Bondi_client.Config_file

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

(* The action carries no name, so the one network it may ever create is printed
   from the same constant the planner compares against. *)
let action_string = function
  | Deploy.EnsureCronNetwork ->
      "EnsureCronNetwork(" ^ Bondi_common.Defaults.network_name ^ ")"
  | Deploy.PullCronImages _ -> "PullCronImages"
  | Deploy.UpsertCrontab jobs -> (
      match jobs with
      | None -> "UpsertCrontab(None)"
      | Some jobs -> "UpsertCrontab(" ^ string_of_int (List.length jobs) ^ ")")

let planned_actions ~context input =
  match Deploy.cron_plan input with
  | Error err ->
      Alcotest.fail
        (context ^ ": cron_plan failed: " ^ Deploy.deploy_error_message err)
  | Ok actions -> List.map action_string actions

let plan_error ~context input =
  match Deploy.cron_plan input with
  | Ok actions ->
      Alcotest.fail
        (Printf.sprintf "%s: expected an error, planned [%s]" context
           (String.concat "; " (List.map action_string actions)))
  | Error err -> err

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

(* One builder for every cron-plan network arm, so the three arms differ in the
   declared network and nothing else. *)
let cron_job_on_network ~name ~network : Simple.cron_job =
  {
    name;
    image = "backup:v1";
    schedule = "0 0 * * *";
    network;
    env_vars = None;
    registry_user = None;
    registry_pass = None;
    alert_sinks = None;
    exit_code_severities = None;
  }

let test_cron_plan_empty_cron_jobs () =
  let input = { minimal_input with cron_jobs = Some [] } in
  Alcotest.check
    (Alcotest.list Alcotest.string)
    "no cron actions when cron_jobs is empty" []
    (planned_actions ~context:"empty cron jobs" input)

let test_cron_plan_with_cron_jobs () =
  let cron = cron_job_on_network ~name:"backup" ~network:None in
  let input = { minimal_input with cron_jobs = Some [ cron ] } in
  Alcotest.check
    (Alcotest.list Alcotest.string)
    "includes PullCronImages and UpsertCrontab"
    [ "PullCronImages"; "UpsertCrontab(1)" ]
    (planned_actions ~context:"one cron job" input)

(* A job declaring the network Bondi owns gets it ensured on the deploy path,
   because a deploy cannot assume setup has run. The ensure precedes the pull so
   the network exists before anything can reference it. *)
let test_cron_plan_ensures_shared_network () =
  let cron =
    cron_job_on_network ~name:"backup"
      ~network:(Some Bondi_common.Defaults.network_name)
  in
  let input = { minimal_input with cron_jobs = Some [ cron ] } in
  Alcotest.check
    (Alcotest.list Alcotest.string)
    "ensures the shared network before pulling"
    [ "EnsureCronNetwork(bondi-network)"; "PullCronImages"; "UpsertCrontab(1)" ]
    (planned_actions ~context:"job on the shared network" input);
  (* The ensure is idempotent and there is only one name it can carry, so two
     jobs declaring it plan one action, not two. *)
  let two_jobs =
    {
      minimal_input with
      cron_jobs =
        Some
          [
            cron;
            cron_job_on_network ~name:"report"
              ~network:(Some Bondi_common.Defaults.network_name);
          ];
    }
  in
  Alcotest.check
    (Alcotest.list Alcotest.string)
    "two jobs on the shared network ensure it once"
    [ "EnsureCronNetwork(bondi-network)"; "PullCronImages"; "UpsertCrontab(2)" ]
    (planned_actions ~context:"two jobs on the shared network" two_jobs)

(* Creating a typo'd network would hand the job an empty network it cannot reach
   anything through — the silent failure this feature removes.

   The check is over the declared name alone, against a constant accepted set,
   so every remedy the message offers must be one the operator can apply in
   bondi.yaml. Creating the network with Docker is not such a remedy: this
   function receives only the cron jobs, so a network created out of band stays
   invisible to it and the next deploy fails identically. *)
let test_cron_plan_rejects_unknown_network () =
  let cron =
    cron_job_on_network ~name:"backup" ~network:(Some "bondi-netwrok")
  in
  let input = { minimal_input with cron_jobs = Some [ cron ] } in
  let msg =
    Deploy.deploy_error_message
      (plan_error ~context:"job on an unmanaged network" input)
  in
  Alcotest.check Alcotest.bool
    ("error names the declared network: " ^ msg)
    true
    (Bondi_common.String_utils.contains ~needle:"bondi-netwrok" msg);
  (* The affirmative arm for the negative check below: the one accepted value is
     named, so "no docker remedy" cannot pass by naming no remedy at all. *)
  Alcotest.check Alcotest.bool
    ("error names the network bondi accepts: " ^ msg)
    true
    (Bondi_common.String_utils.contains
       ~needle:Bondi_common.Defaults.network_name msg);
  Alcotest.check Alcotest.bool
    ("error prescribes no docker-level remedy it cannot observe: " ^ msg)
    false
    (Bondi_common.String_utils.contains ~needle:"docker network create" msg)

(* The whole declared set is in hand and the check is pure, so reporting only
   the first offender would make the operator rediscover the next bad name on
   the next deploy. Each offending job is named alongside the network it
   declared, so a two-job message is not ambiguous about which is which. *)
let test_cron_plan_rejects_every_unknown_network () =
  let input =
    {
      minimal_input with
      cron_jobs =
        Some
          [
            cron_job_on_network ~name:"backup" ~network:(Some "bondi-netwrok");
            cron_job_on_network ~name:"report" ~network:(Some "reporting-net");
          ];
    }
  in
  let msg =
    Deploy.deploy_error_message
      (plan_error ~context:"two jobs on unmanaged networks" input)
  in
  List.iter
    (fun needle ->
      Alcotest.check Alcotest.bool
        (Printf.sprintf "error names %s: %s" needle msg)
        true
        (Bondi_common.String_utils.contains ~needle msg))
    [ "backup"; "bondi-netwrok"; "report"; "reporting-net" ]

(* A network name bondi does not manage is a value the operator wrote, so the
   endpoint answers 400 rather than reporting the operator's typo as a bondi
   fault. This is the classification the sibling /run endpoint already uses. *)
let test_deploy_status_for_invalid_request () =
  let cron =
    cron_job_on_network ~name:"backup" ~network:(Some "bondi-netwrok")
  in
  let input = { minimal_input with cron_jobs = Some [ cron ] } in
  let err = plan_error ~context:"job on an unmanaged network" input in
  Alcotest.check Alcotest.int "declared-network rejection answers 400" 400
    (Dream.status_to_int (Deploy.status_of_deploy_error err))

(* The affirmative arm for the test above: without it, a classifier that
   answered 400 for everything would pass. *)
let test_deploy_status_for_orchestrator_failure () =
  Alcotest.check Alcotest.int "an orchestrator fault answers 500" 500
    (Dream.status_to_int
       (Deploy.status_of_deploy_error
          (Deploy.Orchestrator_failure "docker daemon unreachable")))

(* The affirmative arm above with the network field removed — a job declaring
   none plans exactly what it planned before the network check existed. *)
let test_cron_plan_without_network_unchanged () =
  let cron = cron_job_on_network ~name:"backup" ~network:None in
  let input = { minimal_input with cron_jobs = Some [ cron ] } in
  Alcotest.check
    (Alcotest.list Alcotest.string)
    "no network action for a job declaring none"
    [ "PullCronImages"; "UpsertCrontab(1)" ]
    (planned_actions ~context:"job declaring no network" input)

(* The client emits this shape from its own deploy_cron_job type; the two are
   structural duplicates, so the wire key is pinned on both sides. *)
let test_cron_job_decodes_network_from_wire () =
  let json =
    Yojson.Safe.from_string
      {|{"name":"backup","image":"backup:v1","schedule":"0 0 * * *","network":"bondi-network"}|}
  in
  match Simple.cron_job_of_yojson json with
  | Error msg -> Alcotest.fail ("cron job rejected: " ^ msg)
  | Ok (job : Simple.cron_job) ->
      Alcotest.check
        (Alcotest.option Alcotest.string)
        "network decoded from the wire" (Some "bondi-network") job.network

let test_cron_job_decodes_absent_network () =
  let json =
    Yojson.Safe.from_string
      {|{"name":"backup","image":"backup:v1","schedule":"0 0 * * *"}|}
  in
  match Simple.cron_job_of_yojson json with
  | Error msg -> Alcotest.fail ("cron job rejected: " ^ msg)
  | Ok (job : Simple.cron_job) ->
      Alcotest.check
        (Alcotest.option Alcotest.string)
        "absent network decodes to None" None job.network

(* Copied verbatim from what the client's own encoder emits in
   test/client/test_deploy_helpers.ml's wire-key test, embedded in a deploy
   payload. Hand-writing it would let the two halves of the wire contract
   drift. *)
let wire_cron_job_json =
  {|{"name":"backup","image":"img:v1","schedule":"* * * * *","alert_sinks":{"critical":["https://pager.example.com/hook"],"failure":["https://dash.example.com/hook"]},"exit_code_severities":{"critical":[70]}}|}

let alerting_deploy_payload_json =
  {|{"cron_jobs":[|} ^ wire_cron_job_json ^ {|]}|}

(* The rejected payload travels with the message: the ppx reports only which
   type failed, which on a key-name change reads as "Simple.cron_job" and names
   nothing useful. *)
let cron_job_from_deploy_json json_str : Simple.cron_job =
  match Simple.deploy_input_of_yojson (Yojson.Safe.from_string json_str) with
  | Error msg ->
      Alcotest.fail
        (Printf.sprintf "deploy payload rejected: %s; payload: %s" msg json_str)
  | Ok (input : Simple.deploy_input) -> (
      match input.cron_jobs with
      | None -> Alcotest.fail "deploy payload decoded with no cron jobs"
      | Some [ job ] -> job
      | Some jobs ->
          Alcotest.fail
            (Printf.sprintf "expected exactly one cron job, got %d"
               (List.length jobs)))

(* The configured values the fixture carries. Both the decode test and the
   composition test end here; only the path they take to get here differs. The
   severity map is observed through the classifier because it is abstract: 70 is
   the configured override and 1 still falls to the default, so a map landing in
   the wrong slot cannot pass. *)
let check_alert_config ~context ~(alert_sinks : Alert.sinks option)
    ~(exit_code_severities : Simple.exit_code_severities option) =
  (match alert_sinks with
  | None -> Alcotest.fail (context ^ ": alert_sinks did not arrive")
  | Some Alert.{ critical; failure } ->
      Alcotest.check
        (Alcotest.list Alcotest.string)
        (context ^ ": critical sinks")
        [ "https://pager.example.com/hook" ]
        (List.map Alert.sink_url critical);
      Alcotest.check
        (Alcotest.list Alcotest.string)
        (context ^ ": failure sinks")
        [ "https://dash.example.com/hook" ]
        (List.map Alert.sink_url failure));
  match exit_code_severities with
  | None -> Alcotest.fail (context ^ ": exit_code_severities did not arrive")
  | Some map ->
      Alcotest.check Alcotest.bool
        (context ^ ": code 70 is critical")
        true
        (Alert.severity_of_exit_code map 70 = Alert.Critical);
      Alcotest.check Alcotest.bool
        (context ^ ": code 1 falls to the default failure")
        true
        (Alert.severity_of_exit_code map 1 = Alert.Failure)

let test_deploy_input_decodes_alert_config () =
  let job = cron_job_from_deploy_json alerting_deploy_payload_json in
  check_alert_config ~context:"decoded deploy payload"
    ~alert_sinks:job.alert_sinks ~exit_code_severities:job.exit_code_severities

(* The end of the path the defect broke: the sink URLs must reach the line the
   orchestrator writes to the crontab, not merely the decoded record. *)
let test_crontab_line_carries_alert_config_from_deploy_json () =
  let line =
    Crontab.entry_of_cron_job
      (cron_job_from_deploy_json alerting_deploy_payload_json)
  in
  Alcotest.check Alcotest.bool "critical sink URL reaches the crontab line" true
    (Bondi_common.String_utils.contains ~needle:"https://pager.example.com/hook"
       line);
  Alcotest.check Alcotest.bool "failure sink URL reaches the crontab line" true
    (Bondi_common.String_utils.contains ~needle:"https://dash.example.com/hook"
       line)

let alerting_config_cron_job () : Client_config.cron_job =
  let sink url =
    match Alert.sink_of_string url with
    | Ok s -> s
    | Error e ->
        Alcotest.fail ("bad sink fixture: " ^ Alert.sink_error_to_string e)
  in
  let severities =
    match
      Alert.severity_map_of_yojson
        (Yojson.Safe.from_string {|{"critical":[70]}|})
    with
    | Ok m -> m
    | Error e ->
        Alcotest.fail
          ("bad severity fixture: " ^ Alert.severity_map_error_to_string e)
  in
  {
    name = "backup";
    image = "img";
    schedule = "* * * * *";
    network = None;
    env_vars = None;
    registry_user = None;
    registry_pass = None;
    alert_sinks =
      Some
        {
          critical = [ sink "https://pager.example.com/hook" ];
          failure = [ sink "https://dash.example.com/hook" ];
        };
    exit_code_severities = Some severities;
    server = { ip_address = "1.2.3.4"; ssh = None; port = None };
  }

(* The seam itself: the client's encoder feeds the server's decoder with no JSON
   literal and no field name written down in between, so a rename or a dropped
   field on either side fails this by construction. The two tests above cannot
   have that property — they start from bytes the client has already produced,
   which is where the original defect was invisible. *)
let test_config_to_crontab_payload_carries_alert_config () =
  let wire =
    Client_deploy.cron_job_to_deploy
      (alerting_config_cron_job ())
      ~image:"img:v1"
  in
  let encoded = Client_deploy.deploy_cron_job_to_yojson wire in
  match Simple.cron_job_of_yojson encoded with
  | Error msg ->
      Alcotest.fail
        (Printf.sprintf
           "server rejected the client's cron job: %s; the client emitted: %s"
           msg
           (Yojson.Safe.to_string encoded))
  | Ok (job : Simple.cron_job) -> (
      let line = Crontab.entry_of_cron_job job in
      match Crontab.json_from_cron_line line with
      | None -> Alcotest.fail "no JSON payload in the emitted crontab line"
      | Some json -> (
          match Run.run_payload_of_yojson json with
          | Error msg ->
              Alcotest.fail ("run payload rejected the cron line: " ^ msg)
          | Ok (payload : Run.run_payload) ->
              check_alert_config
                ~context:"config through the wire to the crontab payload"
                ~alert_sinks:payload.alert_sinks
                ~exit_code_severities:payload.exit_code_severities))

let test_cron_plan_no_cron_jobs () =
  Alcotest.check
    (Alcotest.list Alcotest.string)
    "no cron actions when cron_jobs is None" []
    (planned_actions ~context:"no cron jobs" minimal_input)

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
          Alcotest.test_case "ensures the shared network" `Quick
            test_cron_plan_ensures_shared_network;
          Alcotest.test_case "rejects an unknown network" `Quick
            test_cron_plan_rejects_unknown_network;
          Alcotest.test_case "rejects every unknown network" `Quick
            test_cron_plan_rejects_every_unknown_network;
          Alcotest.test_case "no network declared is unchanged" `Quick
            test_cron_plan_without_network_unchanged;
        ] );
      ( "failure status",
        [
          Alcotest.test_case "invalid request" `Quick
            test_deploy_status_for_invalid_request;
          Alcotest.test_case "orchestrator failure" `Quick
            test_deploy_status_for_orchestrator_failure;
        ] );
      ( "cron job wire shape",
        [
          Alcotest.test_case "decodes network" `Quick
            test_cron_job_decodes_network_from_wire;
          Alcotest.test_case "decodes absent network" `Quick
            test_cron_job_decodes_absent_network;
          Alcotest.test_case "decodes alert config" `Quick
            test_deploy_input_decodes_alert_config;
          Alcotest.test_case "crontab line carries alert config" `Quick
            test_crontab_line_carries_alert_config_from_deploy_json;
          Alcotest.test_case "config through wire to crontab payload" `Quick
            test_config_to_crontab_payload_carries_alert_config;
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
