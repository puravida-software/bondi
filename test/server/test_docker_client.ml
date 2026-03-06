module Docker = Bondi_server__Docker__Client

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
  let response = Docker.image_inspect_response_of_yojson json in
  let healthcheck = response.container_config.healthcheck in
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
  let response = Docker.image_inspect_response_of_yojson json in
  let healthcheck = response.container_config.healthcheck in
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
  let state = Docker.inspect_state_of_yojson json in
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
  let state = Docker.inspect_state_of_yojson json in
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
  let state = Docker.inspect_state_of_yojson json in
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
  let health = Docker.health_state_of_yojson json in
  Alcotest.check Alcotest.string "status" "starting" health.status;
  Alcotest.check Alcotest.int "default failing streak" 0 health.failing_streak;
  Alcotest.check Alcotest.int "default log" 0 (List.length health.log)

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
