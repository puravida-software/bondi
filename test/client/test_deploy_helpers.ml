open Alcotest
module Deploy = Bondi_client.Cmd.Deploy
module Config_file = Bondi_client.Config_file
module Alert = Bondi_common.Alert

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
    bondi_server = { version = "0.1.0"; bind_address = None; api_token = None };
    traefik = None;
    cron_jobs;
    alloy = None;
    managed_containers = None;
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
    drain_grace_period = None;
    deployment_strategy = None;
    health_timeout = None;
    poll_interval = None;
    logs = None;
  }

let mk_cron_job ?network ?alert_sinks ?exit_code_severities name ip :
    Config_file.cron_job =
  {
    name;
    image = "img";
    schedule = "* * * * *";
    network;
    env_vars = None;
    secret_env_vars = None;
    registry_user = None;
    registry_pass = None;
    alert_sinks;
    exit_code_severities;
    server = { ip_address = ip; ssh = None; port = None };
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

let test_cron_job_to_deploy_carries_network () =
  let job = mk_cron_job ~network:"bondi-network" "backup" "1.2.3.4" in
  let result = Deploy.cron_job_to_deploy job ~image:"img:v1" in
  check (option string) "network reaches the deploy payload"
    (Some "bondi-network") result.network

let test_cron_job_to_deploy_absent_network () =
  let job = mk_cron_job "backup" "1.2.3.4" in
  let result = Deploy.cron_job_to_deploy job ~image:"img:v1" in
  check (option string) "absent network stays absent" None result.network

let alerting_sinks () =
  match
    Alert.sinks_of_yojson
      (Yojson.Safe.from_string
         {|{"critical":["https://pager.example.com/hook"],"failure":["https://dash.example.com/hook"]}|})
  with
  | Ok s -> s
  | Error msg -> Alcotest.fail ("bad sinks fixture: " ^ msg)

let alerting_severities () =
  match
    Alert.severity_map_of_yojson (Yojson.Safe.from_string {|{"critical":[70]}|})
  with
  | Ok m -> m
  | Error e ->
      Alcotest.fail
        ("bad severity fixture: " ^ Alert.severity_map_error_to_string e)

let alerting_cron_job () =
  mk_cron_job ~alert_sinks:(alerting_sinks ())
    ~exit_code_severities:(alerting_severities ()) "backup" "1.2.3.4"

let test_cron_job_to_deploy_carries_alert_sinks () =
  let result =
    Deploy.cron_job_to_deploy (alerting_cron_job ()) ~image:"img:v1"
  in
  match result.alert_sinks with
  | None -> Alcotest.fail "alert_sinks did not reach the deploy payload"
  | Some Alert.{ critical; failure } ->
      check (list string) "critical sinks"
        [ "https://pager.example.com/hook" ]
        (List.map Alert.sink_url critical);
      check (list string) "failure sinks"
        [ "https://dash.example.com/hook" ]
        (List.map Alert.sink_url failure)

(* Observed through the classifier because the map is abstract: 70 is the
   configured critical override, and the defaults still apply to the codes the
   map does not mention. Asserting the slot holds a working severity map is what
   catches the map landing in the wrong field. *)
let test_cron_job_to_deploy_carries_exit_code_severities () =
  let result =
    Deploy.cron_job_to_deploy (alerting_cron_job ()) ~image:"img:v1"
  in
  match result.exit_code_severities with
  | None ->
      Alcotest.fail "exit_code_severities did not reach the deploy payload"
  | Some map ->
      check bool "code 70 is critical" true
        (Alert.severity_of_exit_code map 70 = Alert.Critical);
      check bool "code 1 defaults to failure" true
        (Alert.severity_of_exit_code map 1 = Alert.Failure);
      check bool "code 0 defaults to success" true
        (Alert.severity_of_exit_code map 0 = Alert.Success)

(* The server decodes by string key, so these two key names are the contract the
   matching decode in test/server asserts against. *)
let test_deploy_wire_keys_for_alert_config () =
  let json =
    Deploy.deploy_cron_job_to_yojson
      (Deploy.cron_job_to_deploy (alerting_cron_job ()) ~image:"img:v1")
  in
  match json with
  | `Assoc fields ->
      check bool "emits the \"alert_sinks\" key" true
        (List.mem_assoc "alert_sinks" fields);
      check bool "emits the \"exit_code_severities\" key" true
        (List.mem_assoc "exit_code_severities" fields);
      check (option string) "critical sink survives encoding"
        (Some "https://pager.example.com/hook")
        (match List.assoc_opt "alert_sinks" fields with
        | Some (`Assoc sink_fields) -> (
            match List.assoc_opt "critical" sink_fields with
            | Some (`List [ `String url ]) -> Some url
            | Some _
            | None ->
                None)
        | Some _
        | None ->
            None);
      check (option string) "critical exit codes survive encoding" (Some "[70]")
        (match List.assoc_opt "exit_code_severities" fields with
        | Some (`Assoc severity_fields) ->
            Option.map Yojson.Safe.to_string
              (List.assoc_opt "critical" severity_fields)
        | Some _
        | None ->
            None)
  | _ -> Alcotest.fail "expected a JSON object"

(* A job with no alert config must emit no key at all, not a null: the payload
   bytes stay identical to what a pre-alerting server already accepts. *)
let test_deploy_wire_omits_alert_fields_when_unconfigured () =
  let json =
    Deploy.deploy_cron_job_to_yojson
      (Deploy.cron_job_to_deploy
         (mk_cron_job "backup" "1.2.3.4")
         ~image:"img:v1")
  in
  match json with
  | `Assoc fields ->
      check bool "omits the \"alert_sinks\" key" false
        (List.mem_assoc "alert_sinks" fields);
      check bool "omits the \"exit_code_severities\" key" false
        (List.mem_assoc "exit_code_severities" fields)
  | _ -> Alcotest.fail "expected a JSON object"

(* The server decodes this into its own structurally-duplicate cron_job, so the
   emitted key is pinned here and the matching decode in test/server. *)
let test_cron_job_wire_key_is_network () =
  let job = mk_cron_job ~network:"bondi-network" "backup" "1.2.3.4" in
  let json =
    Deploy.deploy_cron_job_to_yojson
      (Deploy.cron_job_to_deploy job ~image:"img:v1")
  in
  match json with
  | `Assoc fields ->
      check (option string) "emitted under the \"network\" key"
        (Some "bondi-network")
        (match List.assoc_opt "network" fields with
        | Some (`String s) -> Some s
        | Some _
        | None ->
            None)
  | _ -> Alcotest.fail "expected a JSON object"

(* deploy_payload logs flag *)

let test_deploy_payload_includes_logs_flag () =
  let config =
    mk_config ~user_service:{ (mk_service "web") with logs = Some false } ()
  in
  let service = Option.get config.user_service in
  let payload : Deploy.deploy_payload =
    {
      service_name = Some service.name;
      image = Some (service.image ^ ":v1");
      port = Some service.port;
      env_vars = service.env_vars;
      traefik_domain_name = None;
      traefik_image = None;
      traefik_acme_email = None;
      registry_user = service.registry_user;
      registry_pass = service.registry_pass;
      force_traefik_redeploy = None;
      cron_jobs = None;
      drain_grace_period = None;
      deployment_strategy = None;
      health_timeout = None;
      poll_interval = None;
      logs = Some false;
    }
  in
  check (option bool) "logs flag is Some false" (Some false) payload.logs;
  (* Round-trip through JSON *)
  let json = Deploy.deploy_payload_to_yojson payload in
  let decoded =
    match Deploy.deploy_payload_of_yojson json with
    | Ok v -> v
    | Error msg -> Alcotest.fail ("unexpected error: " ^ msg)
  in
  check (option bool) "logs survives JSON round-trip" (Some false) decoded.logs

(* cron_version_gate *)

(* The gate protects the exec-shaped crontab line: a box whose orchestrator
   predates the [run] subcommand would take the line happily and fail at its
   next fire, at whatever hour that is. The refusal has to arrive before the
   deploy is posted, so the decision is made from the box's reported version
   rather than from anything the server answers. *)
let test_cron_deploy_against_an_under_version_box_is_refused () =
  let jobs =
    Deploy.cron_jobs_for_server "1.2.3.4"
      (Some [ mk_cron_job "backup" "1.2.3.4" ])
      [ ("backup", "v1") ]
  in
  let read_version () = Ok "0.12.0" in
  match Deploy.cron_version_gate ~read_version jobs with
  | Ok () -> Alcotest.fail "expected a cron-declaring deploy to be refused"
  | Error msg ->
      check bool
        ("the refusal names what the box reported: " ^ msg)
        true
        (Bondi_common.String_utils.contains ~needle:"0.12.0" msg)

(* A deploy with no cron jobs on this server writes no crontab line, so there is
   nothing for the version to gate -- and consulting the box anyway would make
   every service-only deploy pay for a question nobody asked. The reader here
   fails if it is called at all. *)
let test_deploy_without_cron_jobs_is_not_gated () =
  let read_version () = Error "the box was consulted" in
  match Deploy.cron_version_gate ~read_version None with
  | Ok () -> ()
  | Error msg -> Alcotest.fail ("expected no gate, got: " ^ msg)

(* [Some []] is not a shape [cron_jobs_for_server] produces, but it is a shape
   the gate accepts, and it writes no crontab line either -- so the reader must
   stay unasked for it too. *)
let test_deploy_with_an_empty_cron_list_is_not_gated () =
  let read_version () = Error "the box was consulted" in
  match Deploy.cron_version_gate ~read_version (Some []) with
  | Ok () -> ()
  | Error msg -> Alcotest.fail ("expected no gate, got: " ^ msg)

(* The arm the gate exists to let through: cron jobs declared *and* a box
   carrying the [run] subcommand, so the deploy proceeds. Refusing an
   under-version box and skipping a service-only deploy are both satisfied by an
   implementation that reads the version and then refuses whatever it read, so
   without this case nothing establishes that anyone can deploy a cron job at
   all. *)
let test_cron_deploy_against_a_supported_box_proceeds () =
  let jobs =
    Deploy.cron_jobs_for_server "1.2.3.4"
      (Some [ mk_cron_job "backup" "1.2.3.4" ])
      [ ("backup", "v1") ]
  in
  let read_version () = Ok Bondi_client.Server_version.minimum_for_exec_lines in
  match Deploy.cron_version_gate ~read_version jobs with
  | Ok () -> ()
  | Error msg ->
      Alcotest.fail ("expected a supported box to be deployed to: " ^ msg)

(* [reported_orchestrator_version] is the reader the gate is handed in
   production, and for a server with no [ssh] block nothing is ever spawned: the
   refusal comes from the configuration rather than from a host. The refusal
   itself stands -- an unreadable box is deliberately not deployed to -- but it
   has to send the operator to bondi.yaml rather than to the network. *)
let test_a_server_without_an_ssh_block_is_told_so () =
  let server : Config_file.server =
    { ip_address = "1.2.3.4"; ssh = None; port = None }
  in
  match Deploy.reported_orchestrator_version server with
  | Ok version -> Alcotest.fail ("expected a refusal, got: " ^ version)
  | Error msg ->
      check bool
        ("the refusal names the missing ssh: block: " ^ msg)
        true
        (Bondi_common.String_utils.contains ~needle:"ssh:" msg);
      check bool
        ("the refusal is not worded as a failed read: " ^ msg)
        false
        (Bondi_common.String_utils.contains ~needle:"could not be read" msg)

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
        [
          test_case "correct field mapping" `Quick test_cron_job_to_deploy;
          test_case "carries network" `Quick
            test_cron_job_to_deploy_carries_network;
          test_case "absent network" `Quick
            test_cron_job_to_deploy_absent_network;
          test_case "wire key is network" `Quick
            test_cron_job_wire_key_is_network;
          test_case "carries alert_sinks" `Quick
            test_cron_job_to_deploy_carries_alert_sinks;
          test_case "carries exit_code_severities" `Quick
            test_cron_job_to_deploy_carries_exit_code_severities;
          test_case "wire keys for alert config" `Quick
            test_deploy_wire_keys_for_alert_config;
          test_case "omits alert fields when unconfigured" `Quick
            test_deploy_wire_omits_alert_fields_when_unconfigured;
        ] );
      ( "cron_version_gate",
        [
          test_case
            "a cron-declaring deploy against an under-version box is refused"
            `Quick test_cron_deploy_against_an_under_version_box_is_refused;
          test_case "a deploy declaring no cron jobs is not gated" `Quick
            test_deploy_without_cron_jobs_is_not_gated;
          test_case "a deploy with an empty cron list is not gated" `Quick
            test_deploy_with_an_empty_cron_list_is_not_gated;
          test_case "a cron-declaring deploy against a supported box proceeds"
            `Quick test_cron_deploy_against_a_supported_box_proceeds;
          test_case
            "a server with no ssh block is told that, not that a read failed"
            `Quick test_a_server_without_an_ssh_block_is_told_so;
        ] );
      ( "deploy_payload",
        [
          test_case "includes logs flag" `Quick
            test_deploy_payload_includes_logs_flag;
        ] );
    ]
