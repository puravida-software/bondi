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
      | Ok _, Error _
      | Error _, Ok _ ->
          false)

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
  | Some []
  | Some (_ :: _ :: _)
  | None ->
      Alcotest.fail "expected one matching job"

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
  | `String _
  | `Int _
  | `Float _
  | `Bool _
  | `Null
  | `List _
  | `Intlit _ ->
      Alcotest.fail "expected a JSON object"

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
  | `String _
  | `Int _
  | `Float _
  | `Bool _
  | `Null
  | `List _
  | `Intlit _ ->
      Alcotest.fail "expected a JSON object"

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
  | `String _
  | `Int _
  | `Float _
  | `Bool _
  | `Null
  | `List _
  | `Intlit _ ->
      Alcotest.fail "expected a JSON object"

(* deploy_payload logs flag *)

let test_deploy_payload_includes_logs_flag () =
  let config =
    mk_config ~user_service:{ (mk_service "web") with logs = Some false } ()
  in
  let service =
    match config.user_service with
    | Some service -> service
    | None -> Alcotest.fail "the fixture declares a service"
  in
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

(* version_gate *)

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
  match Deploy.version_gate ~read_version jobs with
  | Ok () -> Alcotest.fail "expected a cron-declaring deploy to be refused"
  | Error msg ->
      check bool
        ("the refusal names what the box reported: " ^ msg)
        true
        (Bondi_common.String_utils.contains ~needle:"0.12.0" msg)

(* A deploy with no cron jobs on this server writes no crontab line, so the
   crontab floor is not what it is held to -- but it still runs a command inside
   the orchestrator's container to get there, and a binary with no subcommands
   answers that by ignoring the arguments and serving. So the box is read for
   every deploy now, and the floor applied to a service-only one is the lower of
   the two. *)
let test_a_service_only_deploy_is_held_to_the_command_surface () =
  let read_version () = Ok "0.14.0" in
  match Deploy.version_gate ~read_version None with
  | Ok () ->
      Alcotest.fail
        "expected a box with no subcommands to be refused a service deploy"
  | Error msg ->
      check bool
        ("the refusal names what the box reported: " ^ msg)
        true
        (Bondi_common.String_utils.contains ~needle:"0.14.0" msg);
      check bool
        ("and what is required of it: " ^ msg)
        true
        (Bondi_common.String_utils.contains
           ~needle:Bondi_client.Server_version.minimum_for_command_surface msg)

(* The other side of the same box: at the command surface floor and below the
   crontab one, a deploy that writes no crontab line proceeds. Without this arm
   the case above is satisfied by a gate that refuses everything, and the two
   floors would have collapsed back into one. *)
let test_a_service_only_deploy_is_not_held_to_the_crontab_floor () =
  let read_version () =
    Ok Bondi_client.Server_version.minimum_for_command_surface
  in
  match Deploy.version_gate ~read_version None with
  | Ok () -> ()
  | Error msg -> Alcotest.fail ("expected the deploy to proceed, got: " ^ msg)

(* [Some []] is not a shape [cron_jobs_for_server] produces, but it is a shape
   the gate accepts, and it writes no crontab line either -- so it is held to
   the same floor as [None] and not to the crontab one. *)
let test_a_deploy_with_an_empty_cron_list_is_held_to_the_lower_floor () =
  let read_version () =
    Ok Bondi_client.Server_version.minimum_for_command_surface
  in
  match Deploy.version_gate ~read_version (Some []) with
  | Ok () -> ()
  | Error msg -> Alcotest.fail ("expected the deploy to proceed, got: " ^ msg)

(* Every deploy reads the box now, so a box that cannot be read stops a
   service-only deploy as surely as it stops a cron-declaring one. There is no
   longer a path that reaches a server without having seen what it is running:
   the read and the command the deploy runs go over the same connection, so a
   box that could not answer the first was never going to answer the second. *)
let test_a_deploy_against_an_unreadable_box_is_refused () =
  let read_version () = Error "the orchestrator's version could not be read" in
  match Deploy.version_gate ~read_version None with
  | Ok () -> Alcotest.fail "expected an unreadable box to refuse a deploy"
  | Error msg ->
      check string "the reader's own words reach the operator"
        "the orchestrator's version could not be read" msg

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
  match Deploy.version_gate ~read_version jobs with
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

(* cron_divergence_report *)

(* The markers below have no exported constant, so they are spelled here as
   [test_crontab_listing] and [test_cron_payload] already spell them. What keeps
   that honest is those files' own cases pinning the command strings that print
   them: a renamed marker turns these fixtures into answers carrying no marker at
   all, which both readers call "never read", and the cases below then fail
   loudly rather than quietly agreeing. *)
let crontab_naming job =
  Ok
    (String.concat "\n"
       [
         "BONDI_CRONTAB_CONTENTS";
         "# BEGIN BONDI CRON";
         Printf.sprintf "0 3 * * * docker exec %s sh -c '%s%s'"
           Bondi_common.Builtin_container.orchestrator
           Bondi_common.Cron_exec_line.exec_marker
           (Bondi_common.Cron_exec_line.run_file_of job);
         "# END BONDI CRON";
         "BONDI_CRONTAB_END";
       ])

(* A directory the host listed and found empty: the opening marker, no path, and
   the marker that says the listing reached its end. Without the closing one
   this is a listing that stopped part-way through, which is a different outcome
   carrying a different report. *)
let empty_payload_directory =
  Ok "BONDI_CRON_PAYLOAD_LISTED\nBONDI_CRON_PAYLOAD_END\n"

(* The payload directory as a host that listed it answers, holding both files
   of every job named. The paths come from the writer's own module rather than
   being spelled here, so a fixture cannot go on passing after the writer and
   the reader of a path have drifted apart. *)
let payload_directory_holding jobs =
  Ok
    (String.concat "\n"
       ("BONDI_CRON_PAYLOAD_LISTED"
        :: List.concat_map
             (fun job ->
               [
                 Bondi_common.Cron_exec_line.run_file_of job;
                 Bondi_common.Cron_exec_line.env_file_of job;
               ])
             jobs
       @ [ "BONDI_CRON_PAYLOAD_END" ]))

let nightly_report_on ip =
  Deploy.cron_jobs_for_server ip
    (Some [ mk_cron_job "nightly-report" ip ])
    [ ("nightly-report", "v1") ]

(* The direction a deploy is best placed to catch: the section still fires a job
   whose files the box no longer holds, so the job fails at its next fire, and
   the deploy an operator is running right now is the thing that repairs it. The
   two sources are read off the same box and neither is asked what the other
   said, which is the whole of what makes them a comparison. *)
let test_cron_deploy_reports_what_the_two_sources_disagree_on () =
  match
    Deploy.cron_divergence_report ~server:"1.2.3.4"
      ~read_crontab:(fun () -> crontab_naming "nightly-report")
      ~read_payloads:(fun () -> empty_payload_directory)
      (nightly_report_on "1.2.3.4")
  with
  | [ line ] ->
      check bool
        ("the report names the job: " ^ line)
        true
        (Bondi_common.String_utils.contains ~needle:"nightly-report" line);
      check bool
        ("the report names the server: " ^ line)
        true
        (Bondi_common.String_utils.contains ~needle:"1.2.3.4" line);
      check bool
        ("the report says what the divergence costs: " ^ line)
        true
        (Bondi_common.String_utils.contains ~needle:"fails at its next fire"
           line)
  | lines ->
      Alcotest.fail
        (Printf.sprintf "expected one line, got %d: %s" (List.length lines)
           (String.concat " | " lines))

(* Report, never refuse. Nothing the comparison finds reaches the run's exit:
   the report is lines and not a verdict, and the one value the run does consult
   before it posts -- the version gate's -- answers Ok for the same server on the
   same box. Refusing would block the command that repairs the divergence, and
   would do so on the strength of a remote read that can itself fail. *)
let test_a_deploy_that_finds_a_divergence_still_proceeds () =
  let jobs = nightly_report_on "1.2.3.4" in
  let read_version () = Ok Bondi_client.Server_version.minimum_for_exec_lines in
  check int "the two sources disagree on exactly one job" 1
    (List.length
       (Deploy.cron_divergence_report ~server:"1.2.3.4"
          ~read_crontab:(fun () -> crontab_naming "nightly-report")
          ~read_payloads:(fun () -> empty_payload_directory)
          jobs));
  match Deploy.version_gate ~read_version jobs with
  | Ok () -> ()
  | Error msg -> Alcotest.fail ("a divergence became a refusal: " ^ msg)

(* A deploy writing no crontab line to this server has nothing to compare, and
   consulting the box anyway would make every service-only deploy pay for two
   questions nobody asked. Both readers fail if they are called at all. *)
let test_deploy_without_cron_jobs_reads_neither_source () =
  let refuse source () =
    Alcotest.fail (source ^ " was read for a deploy declaring no cron jobs")
  in
  check (list string) "nothing is read and nothing is said" []
    (Deploy.cron_divergence_report ~server:"1.2.3.4"
       ~read_crontab:(refuse "the crontab section")
       ~read_payloads:(refuse "the payload directory")
       None)

(* [Some []] is not [None], and the two are not one arm. [None] is a server
   with no cron jobs declared against it at all; [Some []] is a server that has
   them and none of them named by this invocation. Neither writes a crontab
   line, so neither has anything to compare -- and collapsing them into
   [Some _] would make the second pay two round trips per server for a report
   about jobs it is not touching. Both readers fail if they are called at
   all. *)
let test_deploy_with_an_empty_cron_list_reads_neither_source () =
  let refuse source () =
    Alcotest.fail (source ^ " was read for a deploy writing no crontab line")
  in
  check (list string) "nothing is read and nothing is said" []
    (Deploy.cron_divergence_report ~server:"1.2.3.4"
       ~read_crontab:(refuse "the crontab section")
       ~read_payloads:(refuse "the payload directory")
       (Some []))

(* The other direction, reached the way a deploy actually reaches it. Withdraw a
   cron job from bondi.yaml and its files stay on the box under no line; what a
   deploy can see of that is bounded by whether this server still has some
   other cron job to write, and only the run where the withdrawn job was the
   last one goes past the orphan in silence. Two jobs are declared on this
   server and one of them is named by the invocation, which is the ordinary
   partial deploy: the list is not empty, both sources are read, and the job
   that left is named.

   It is the direction a report built out of what the deploy is about to write
   could not produce, because the job it names is one the invocation never
   mentions and bondi.yaml no longer declares -- so the line can only have come
   from the box. *)
let test_a_partial_cron_deploy_sees_the_orphan_a_withdrawal_left () =
  let jobs =
    Deploy.cron_jobs_for_server "1.2.3.4"
      (Some
         [
           mk_cron_job "nightly-report" "1.2.3.4";
           mk_cron_job "price-alert" "1.2.3.4";
         ])
      [ ("nightly-report", "v1") ]
  in
  match
    Deploy.cron_divergence_report ~server:"1.2.3.4"
      ~read_crontab:(fun () -> crontab_naming "nightly-report")
      ~read_payloads:(fun () ->
        payload_directory_holding [ "nightly-report"; "stale-digest" ])
      jobs
  with
  | [ line ] ->
      check bool
        ("the report names the job the section no longer fires: " ^ line)
        true
        (Bondi_common.String_utils.contains ~needle:"stale-digest" line);
      check bool
        ("and says what the box will do with it: " ^ line)
        true
        (Bondi_common.String_utils.contains ~needle:"no crontab line fires them"
           line)
  | lines ->
      Alcotest.fail
        (Printf.sprintf "expected the orphan alone, got %d line(s): %s"
           (List.length lines)
           (String.concat " | " lines))

(* the command the box runs, and what comes back from it *)

(* The one string this client and the box have to agree on. The box's binary is
   a group of subcommands and [deploy] is the one that reads a payload on
   standard input; [-i] is what keeps that input open through the container.
   Spelled here as a literal rather than assembled from the pieces a reader
   would have to reassemble in their head: a change to any of them is a change
   to what every deployed box is asked to do, and this line is where that shows
   up. The [docker] itself is the runner's -- it prefixes it so no call site can
   spell it differently. *)
let test_the_exec_command_a_deploy_runs () =
  check string "the deploy runs the box's own deploy subcommand"
    "exec -i bondi-orchestrator bondi-server deploy" Deploy.deploy_exec_command

(* A box answering something no orchestrator produces -- a container that is not
   there, a daemon that refused, an image whose binary knows no such
   subcommand -- is the box's answer and is reported as one, with the words it
   used. The failure this guards against is the opposite: a client that replaces
   what the box said with its own account of not having understood it, which
   leaves an operator with nothing to act on and points them at their own
   machine. *)
let test_an_answer_no_orchestrator_produces_is_the_boxs () =
  let answered = "Error: No such container: bondi-orchestrator" in
  match
    Deploy.deploy_outcome ~ip_address:"1.2.3.4"
      (Error
         (Bondi_client.Remote_exec.Command_failed
            { code = 1; output = answered }))
  with
  | Ok () -> Alcotest.fail "expected the box's refusal to be a failure"
  | Error msg ->
      check bool
        ("the failure names the server it came from: " ^ msg)
        true
        (Bondi_common.String_utils.contains ~needle:"1.2.3.4" msg);
      check bool
        ("and carries the box's own words: " ^ msg)
        true
        (Bondi_common.String_utils.contains ~needle:answered msg);
      check bool
        ("and says the box ran it and refused: " ^ msg)
        true
        (Bondi_common.String_utils.contains ~needle:"ran on the host and failed"
           msg)

(* The arm that makes the one above mean something: a box that answered is a
   deploy that happened. What the box wrote is not read -- the exit code is the
   verdict, and a client that parsed the report would refuse a deploy that
   succeeded the first time the report gained a field. *)
let test_a_box_that_answered_is_a_deploy_that_happened () =
  match
    Deploy.deploy_outcome ~ip_address:"1.2.3.4"
      (Ok "{\"status\":\"success\",\"tag\":\"v1\"}")
  with
  | Ok () -> ()
  | Error msg -> Alcotest.fail ("expected a success, got: " ^ msg)

let gated_server ip : Config_file.server =
  {
    ip_address = ip;
    ssh =
      Some
        {
          user = "deploy";
          private_key_contents = "not-a-real-key";
          private_key_pass = "";
        };
    port = None;
  }

(* A refusal that arrives after the first box has been written to is not a
   refusal. Two boxes, the second of them too old: the run has to end without
   the first having been deployed to, which is a property of the order the two
   loops run in and not of either one alone. The deployer here reports what it
   was asked to do, so being asked at all is visible in the outcome. *)
let test_the_gate_refuses_before_anything_is_posted () =
  let servers =
    [ (gated_server "10.0.0.1", None); (gated_server "10.0.0.2", None) ]
  in
  let read_version (server : Config_file.server) =
    if server.ip_address = "10.0.0.2" then Ok "0.14.0"
    else Ok Bondi_client.Server_version.minimum_for_exec_lines
  in
  let deploy (server : Config_file.server) _cron_jobs =
    Error ("deployed to " ^ server.ip_address)
  in
  match Deploy.deploy_servers ~read_version ~deploy servers with
  | Ok () -> Alcotest.fail "expected the old box to refuse the run"
  | Error messages ->
      let said = String.concat " | " messages in
      check bool
        ("the refusal names the box that was too old: " ^ said)
        true
        (Bondi_common.String_utils.contains ~needle:"10.0.0.2" said);
      check bool
        ("and nothing was deployed: " ^ said)
        false
        (Bondi_common.String_utils.contains ~needle:"deployed to" said)

(* The same two servers, both current, so the loop is reached and every server
   in it is reached in turn. Without this arm the absence above passes against a
   deployer that is never called on any fixture.

   Both failures are asserted, in order. One message could not tell "both
   servers ran and the first was reported" apart from "only the first ran", and
   the sink these reach is a terminal that shows every line it is given -- two
   boxes that both failed are two things the operator has to fix. *)
let test_every_gated_server_is_deployed_to_in_order () =
  let servers =
    [ (gated_server "10.0.0.1", None); (gated_server "10.0.0.2", None) ]
  in
  let read_version _ = Ok Bondi_client.Server_version.minimum_for_exec_lines in
  let deploy (server : Config_file.server) _cron_jobs =
    Error ("deployed to " ^ server.ip_address)
  in
  match Deploy.deploy_servers ~read_version ~deploy servers with
  | Ok () -> Alcotest.fail "expected the deployer's own failure to be reported"
  | Error messages ->
      check (list string)
        "every server is reached, in order, and every failure is the run's"
        [ "deployed to 10.0.0.1"; "deployed to 10.0.0.2" ]
        messages

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
      ( "version_gate",
        [
          test_case
            "a cron-declaring deploy against an under-version box is refused"
            `Quick test_cron_deploy_against_an_under_version_box_is_refused;
          test_case "a service-only deploy is held to the command surface"
            `Quick test_a_service_only_deploy_is_held_to_the_command_surface;
          test_case "a service-only deploy is not held to the crontab floor"
            `Quick test_a_service_only_deploy_is_not_held_to_the_crontab_floor;
          test_case
            "a deploy with an empty cron list is held to the lower floor" `Quick
            test_a_deploy_with_an_empty_cron_list_is_held_to_the_lower_floor;
          test_case "a deploy against a box that cannot be read is refused"
            `Quick test_a_deploy_against_an_unreadable_box_is_refused;
          test_case "a cron-declaring deploy against a supported box proceeds"
            `Quick test_cron_deploy_against_a_supported_box_proceeds;
          test_case
            "a server with no ssh block is told that, not that a read failed"
            `Quick test_a_server_without_an_ssh_block_is_told_so;
        ] );
      ( "cron_divergence_report",
        [
          test_case
            "a cron-declaring deploy reports what the two sources disagree on"
            `Quick test_cron_deploy_reports_what_the_two_sources_disagree_on;
          test_case "a deploy that finds a divergence still proceeds" `Quick
            test_a_deploy_that_finds_a_divergence_still_proceeds;
          test_case "a deploy declaring no cron jobs reads neither source"
            `Quick test_deploy_without_cron_jobs_reads_neither_source;
          test_case "a deploy with an empty cron list reads neither source"
            `Quick test_deploy_with_an_empty_cron_list_reads_neither_source;
          test_case "a partial cron deploy sees the orphan a withdrawal left"
            `Quick test_a_partial_cron_deploy_sees_the_orphan_a_withdrawal_left;
        ] );
      ( "deploy_payload",
        [
          test_case "includes logs flag" `Quick
            test_deploy_payload_includes_logs_flag;
        ] );
      ( "the exec a deploy runs",
        [
          test_case "the exec command a deploy runs" `Quick
            test_the_exec_command_a_deploy_runs;
          test_case "an answer no orchestrator produces is the box's" `Quick
            test_an_answer_no_orchestrator_produces_is_the_boxs;
          test_case "a box that answered is a deploy that happened" `Quick
            test_a_box_that_answered_is_a_deploy_that_happened;
          test_case "the gate refuses before anything is posted" `Quick
            test_the_gate_refuses_before_anything_is_posted;
          test_case "every gated server is deployed to, in order" `Quick
            test_every_gated_server_is_deployed_to_in_order;
        ] );
    ]
