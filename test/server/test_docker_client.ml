module Docker = Bondi_server__Docker__Client

let unwrap = function
  | Ok v -> v
  | Error msg -> Alcotest.fail ("unexpected error: " ^ msg)

let test_image_inspect_response_with_healthcheck_json () =
  let json =
    Yojson.Safe.from_string
      {|{
        "ContainerConfig": {
          "Healthcheck": {
            "Test": ["CMD-SHELL", "curl -f http://localhost:8080/health"]
          }
        }
      }|}
  in
  let response = Docker.image_inspect_response_of_yojson json |> unwrap in
  let cc = Option.get response.container_config in
  let healthcheck = cc.healthcheck in
  Alcotest.check Alcotest.bool "healthcheck is present" true
    (Option.is_some healthcheck);
  let hc = Option.get healthcheck in
  Alcotest.check
    (Alcotest.list Alcotest.string)
    "healthcheck test command"
    [ "CMD-SHELL"; "curl -f http://localhost:8080/health" ]
    hc.test

let test_image_inspect_response_without_healthcheck_json () =
  let json =
    Yojson.Safe.from_string
      {|{
        "ContainerConfig": {
          "Hostname": "abc123"
        }
      }|}
  in
  let response = Docker.image_inspect_response_of_yojson json |> unwrap in
  let cc = Option.get response.container_config in
  let healthcheck = cc.healthcheck in
  Alcotest.check Alcotest.bool "healthcheck is absent" false
    (Option.is_some healthcheck)

let test_inspect_state_with_health_json () =
  let json =
    Yojson.Safe.from_string
      {|{
        "Status": "running",
        "ExitCode": 0,
        "Health": {
          "Status": "healthy",
          "FailingStreak": 0,
          "Log": [
            {"Output": "OK\n", "ExitCode": 0}
          ]
        }
      }|}
  in
  let state = Docker.inspect_state_of_yojson json |> unwrap in
  Alcotest.check Alcotest.string "status" "running" state.status;
  Alcotest.check Alcotest.bool "health is present" true
    (Option.is_some state.health);
  let health = Option.get state.health in
  Alcotest.check Alcotest.string "health status" "healthy" health.status;
  Alcotest.check Alcotest.int "failing streak" 0 health.failing_streak;
  Alcotest.check Alcotest.int "log entries" 1 (List.length health.log);
  let entry = List.hd health.log in
  Alcotest.check Alcotest.string "log output" "OK\n" entry.output;
  Alcotest.check Alcotest.int "log exit code" 0 entry.exit_code

let test_inspect_state_without_health_json () =
  let json =
    Yojson.Safe.from_string
      {|{
        "Status": "running",
        "ExitCode": 0
      }|}
  in
  let state = Docker.inspect_state_of_yojson json |> unwrap in
  Alcotest.check Alcotest.string "status" "running" state.status;
  Alcotest.check Alcotest.bool "health is absent" false
    (Option.is_some state.health)

let test_inspect_state_unhealthy_with_streak_json () =
  let json =
    Yojson.Safe.from_string
      {|{
        "Status": "running",
        "ExitCode": 0,
        "Health": {
          "Status": "unhealthy",
          "FailingStreak": 3,
          "Log": [
            {"Output": "connection refused\n", "ExitCode": 1},
            {"Output": "connection refused\n", "ExitCode": 1},
            {"Output": "connection refused\n", "ExitCode": 1}
          ]
        }
      }|}
  in
  let state = Docker.inspect_state_of_yojson json |> unwrap in
  let health = Option.get state.health in
  Alcotest.check Alcotest.string "health status" "unhealthy" health.status;
  Alcotest.check Alcotest.int "failing streak" 3 health.failing_streak;
  Alcotest.check Alcotest.int "log entries" 3 (List.length health.log)

let test_health_state_defaults_json () =
  let json =
    Yojson.Safe.from_string {|{
        "Status": "starting"
      }|}
  in
  let health = Docker.health_state_of_yojson json |> unwrap in
  Alcotest.check Alcotest.string "status" "starting" health.status;
  Alcotest.check Alcotest.int "default failing streak" 0 health.failing_streak;
  Alcotest.check Alcotest.int "default log" 0 (List.length health.log)

(* An inspect payload shaped like the one the Engine actually returns: the
   restart policy Bondi has to read back sits inside a HostConfig object
   carrying dozens of sibling keys this client models none of. *)
let inspect_payload : host_config:string -> string =
 fun ~host_config ->
  Printf.sprintf
    {|{
        "Created": "2026-09-02T10:00:00Z",
        "RestartCount": 0,
        "State": {"Status": "running", "ExitCode": 0}%s
      }|}
    host_config

let applied_host_config : string =
  {|,
        "HostConfig": {
          "Annotations": {},
          "AutoRemove": false,
          "Binds": [],
          "CapAdd": [],
          "CgroupnsMode": "private",
          "ConsoleSize": [0, 0],
          "ContainerIDFile": "",
          "NetworkMode": "bridge",
          "PortBindings": {},
          "RestartPolicy": {"Name": "unless-stopped", "MaximumRetryCount": 0}
        }|}

let test_inspect_response_decodes_the_applied_restart_policy () =
  let json =
    Yojson.Safe.from_string (inspect_payload ~host_config:applied_host_config)
  in
  let response = Docker.inspect_response_of_yojson json |> unwrap in
  Alcotest.check Alcotest.string "state status" "running" response.state.status;
  match response.host_config with
  | None -> Alcotest.fail "inspect response carries no host config"
  | Some host_config -> (
      match host_config.restart_policy with
      | None -> Alcotest.fail "host config carries no restart policy"
      | Some policy ->
          Alcotest.check Alcotest.string "applied restart policy"
            "unless-stopped" policy.name;
          Alcotest.check
            (Alcotest.option Alcotest.int)
            "applied maximum retry count" (Some 0) policy.maximum_retry_count)

(* The Engine adds keys to its leaf objects the same way it adds them to
   HostConfig itself: a daemon newer than this client returns fields no record
   here models. A leaf that rejects them fails the whole inspect decode, which
   is every caller of inspect_container at once. *)
let host_config_with_unmodelled_leaf_keys : string =
  {|,
        "HostConfig": {
          "NetworkMode": "bridge",
          "PortBindings": {
            "8080/tcp": [
              {"HostIp": "127.0.0.1", "HostPort": "8080", "HostPortRange": ""}
            ]
          },
          "RestartPolicy": {
            "Name": "unless-stopped",
            "MaximumRetryCount": 0,
            "MaximumTimeout": 0
          }
        }|}

let test_inspect_response_tolerates_unmodelled_leaf_keys () =
  let json =
    Yojson.Safe.from_string
      (inspect_payload ~host_config:host_config_with_unmodelled_leaf_keys)
  in
  let response = Docker.inspect_response_of_yojson json |> unwrap in
  match response.host_config with
  | None -> Alcotest.fail "inspect response carries no host config"
  | Some host_config -> (
      (match host_config.restart_policy with
      | None -> Alcotest.fail "host config carries no restart policy"
      | Some policy ->
          Alcotest.check Alcotest.string "applied restart policy"
            "unless-stopped" policy.name);
      match host_config.port_bindings with
      | None -> Alcotest.fail "host config carries no port bindings"
      | Some bindings -> (
          match List.assoc_opt "8080/tcp" bindings with
          | Some [ binding ] ->
              Alcotest.check
                (Alcotest.option Alcotest.string)
                "host port" (Some "8080") binding.host_port
          | Some _
          | None ->
              Alcotest.fail "port binding for 8080/tcp missing"))

let test_inspect_response_without_host_config_decodes () =
  let json = Yojson.Safe.from_string (inspect_payload ~host_config:"") in
  let response = Docker.inspect_response_of_yojson json |> unwrap in
  Alcotest.check Alcotest.string "state status" "running" response.state.status;
  Alcotest.check Alcotest.bool "host config is absent" false
    (Option.is_some response.host_config)

let test_update_container_serialises_the_restart_policy () =
  let request : Docker.update_container_request =
    {
      restart_policy =
        { Docker.name = "unless-stopped"; maximum_retry_count = None };
    }
  in
  Alcotest.check Alcotest.string "update request body"
    {|{"RestartPolicy":{"Name":"unless-stopped"}}|}
    (Yojson.Safe.to_string (Docker.update_container_request_to_yojson request))

(* The bound is the only place a stalled Engine socket becomes a value. The
   mock clock advances on its own once nothing is runnable, so the deadline
   fires without the test waiting ten real seconds. *)
let test_request_bound_reports_the_deadline () =
  Eio_mock.Backend.run_full @@ fun env ->
  let clock = env#clock in
  let result =
    Docker.with_request_bound ~clock ~what:"inspect of container abc123"
      (fun () ->
        Eio.Time.sleep clock 3600.0;
        Ok ())
  in
  match result with
  | Ok () -> Alcotest.fail "expected the request bound to report a timeout"
  | Error msg ->
      Alcotest.check Alcotest.string "timeout message"
        "docker inspect of container abc123 did not answer within 10 seconds"
        msg

(* The affirmative arm: a request that answers inside the bound is returned
   untouched, so the arm above is caused by the deadline and not by the bound
   rejecting every request. *)
let test_request_bound_passes_a_prompt_answer_through () =
  Eio_mock.Backend.run_full @@ fun env ->
  let clock = env#clock in
  let result =
    Docker.with_request_bound ~clock ~what:"inspect of container abc123"
      (fun () ->
        Eio.Time.sleep clock 1.0;
        Ok "answered")
  in
  Alcotest.check
    (Alcotest.result Alcotest.string Alcotest.string)
    "answer passed through" (Ok "answered") result

let () =
  Alcotest.run "Docker.Client"
    [
      ( "image inspect",
        [
          Alcotest.test_case "with healthcheck" `Quick
            test_image_inspect_response_with_healthcheck_json;
          Alcotest.test_case "without healthcheck" `Quick
            test_image_inspect_response_without_healthcheck_json;
        ] );
      ( "restart policy",
        [
          Alcotest.test_case "inspect decodes the applied policy" `Quick
            test_inspect_response_decodes_the_applied_restart_policy;
          Alcotest.test_case "inspect tolerates unmodelled leaf keys" `Quick
            test_inspect_response_tolerates_unmodelled_leaf_keys;
          Alcotest.test_case "inspect without host config" `Quick
            test_inspect_response_without_host_config_decodes;
          Alcotest.test_case "update serialises the policy" `Quick
            test_update_container_serialises_the_restart_policy;
        ] );
      ( "request bound",
        [
          Alcotest.test_case "reports the deadline" `Quick
            test_request_bound_reports_the_deadline;
          Alcotest.test_case "passes a prompt answer through" `Quick
            test_request_bound_passes_a_prompt_answer_through;
        ] );
      ( "inspect state health",
        [
          Alcotest.test_case "with health" `Quick
            test_inspect_state_with_health_json;
          Alcotest.test_case "without health" `Quick
            test_inspect_state_without_health_json;
          Alcotest.test_case "unhealthy with streak" `Quick
            test_inspect_state_unhealthy_with_streak_json;
          Alcotest.test_case "health state defaults" `Quick
            test_health_state_defaults_json;
        ] );
    ]
