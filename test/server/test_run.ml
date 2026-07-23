module Run = Bondi_server__Run
module Docker = Bondi_server__Docker__Client
module Alert = Bondi_common.Alert

let outcome_testable =
  let pp fmt = function
    | Alert.Exited code -> Format.fprintf fmt "Exited %d" code
    | Alert.Start_failed msg -> Format.fprintf fmt "Start_failed %S" msg
  in
  Alcotest.testable pp ( = )

let show_networking_conf = function
  | None -> "None"
  | Some conf ->
      Docker.networking_config_to_yojson conf |> Yojson.Safe.to_string

let check_networking_conf msg ~expected ~actual =
  Alcotest.check Alcotest.string msg
    (show_networking_conf expected)
    (show_networking_conf actual)

let endpoint_on network : Docker.networking_config =
  let endpoint : Docker.endpoint_config =
    { aliases = None; ipv4_address = None }
  in
  { endpoints_config = Some [ (network, endpoint) ] }

let mk_payload ?network () : Run.run_payload =
  {
    job = "nightly";
    image = "myapp:v1";
    network;
    env_vars = None;
    alert_sinks = None;
    exit_code_severities = None;
  }

let test_networking_conf_from_network () =
  check_networking_conf "network produces one endpoint entry"
    ~expected:(Some (endpoint_on "bondi-network"))
    ~actual:(Run.networking_conf_of_network (Some "bondi-network"))

let test_run_opts_carries_network () =
  let opts : Docker.run_image_options =
    Run.run_opts ~container_name:"nightly-1" ~full_image:"myapp:v1"
      (mk_payload ~network:"bondi-network" ())
  in
  check_networking_conf "payload network reaches the run options"
    ~expected:(Some (endpoint_on "bondi-network"))
    ~actual:opts.networking_conf

let test_run_opts_absent_network () =
  let opts : Docker.run_image_options =
    Run.run_opts ~container_name:"nightly-1" ~full_image:"myapp:v1"
      (mk_payload ())
  in
  check_networking_conf "absent payload network reaches the run options"
    ~expected:None ~actual:opts.networking_conf

let test_networking_conf_none_when_network_absent () =
  check_networking_conf "absent network produces no networking config"
    ~expected:None
    ~actual:(Run.networking_conf_of_network None)

let test_run_response_with_warning_json () =
  let response : Run.run_response =
    { exit_code = 1; warning = Some "failed to remove old container" }
  in
  let json = Run.run_response_to_yojson response in
  let expected =
    `Assoc
      [
        ("exit_code", `Int 1);
        ("warning", `String "failed to remove old container");
      ]
  in
  Alcotest.check Alcotest.string "run_response with warning"
    (Yojson.Safe.to_string expected)
    (Yojson.Safe.to_string json)

let test_run_response_without_warning_json () =
  let response : Run.run_response = { exit_code = 0; warning = None } in
  let json = Run.run_response_to_yojson response in
  let expected = `Assoc [ ("exit_code", `Int 0) ] in
  Alcotest.check Alcotest.string "run_response without warning"
    (Yojson.Safe.to_string expected)
    (Yojson.Safe.to_string json)

let sinks_of pairs =
  match Alert.sinks_of_yojson (`Assoc pairs) with
  | Ok s -> s
  | Error e -> Alcotest.fail e

let failure_sinks () =
  sinks_of [ ("failure", `List [ `String "https://sink.example.com/x" ]) ]

let critical_sinks () =
  sinks_of [ ("critical", `List [ `String "https://page.example.com/x" ]) ]

let critical_map () =
  match
    Alert.severity_map_of_yojson (`Assoc [ ("critical", `List [ `Int 42 ]) ])
  with
  | Ok m -> m
  | Error e -> Alcotest.fail (Alert.severity_map_error_to_string e)

let test_plan_for_payload_unconfigured_dispatches_nothing () =
  Alcotest.(check bool)
    "an unconfigured payload routes nowhere" true
    (Run.plan_for_payload (mk_payload ()) (Alert.Exited 1) ~timestamp:0.0 = None)

let test_plan_for_payload_failure_targets_configured_sinks () =
  let payload =
    { (mk_payload ()) with alert_sinks = Some (failure_sinks ()) }
  in
  match Run.plan_for_payload payload (Alert.Exited 1) ~timestamp:0.0 with
  | None -> Alcotest.fail "a failure with configured sinks should dispatch"
  | Some dispatch ->
      Alcotest.(check (list string))
        "targets the configured failure sink"
        [ "https://sink.example.com/x" ]
        (List.map Alert.sink_url dispatch.Alert.targets)

let test_plan_for_payload_success_dispatches_nothing () =
  let payload =
    { (mk_payload ()) with alert_sinks = Some (failure_sinks ()) }
  in
  Alcotest.(check bool)
    "a success outcome routes nowhere even with sinks" true
    (Run.plan_for_payload payload (Alert.Exited 0) ~timestamp:0.0 = None)

let test_plan_for_payload_critical_map_targets_critical_sinks () =
  let payload =
    {
      (mk_payload ()) with
      alert_sinks = Some (critical_sinks ());
      exit_code_severities = Some (critical_map ());
    }
  in
  match Run.plan_for_payload payload (Alert.Exited 42) ~timestamp:0.0 with
  | None -> Alcotest.fail "a mapped critical code should dispatch"
  | Some dispatch ->
      Alcotest.(check (list string))
        "targets the configured critical sink"
        [ "https://page.example.com/x" ]
        (List.map Alert.sink_url dispatch.Alert.targets)

let test_run_outcome_from_exit_code () =
  Alcotest.check outcome_testable "completed run classifies as Exited n"
    (Alert.Exited 137)
    (Run.outcome_of_result (Ok 137))

let test_run_outcome_from_start_failure () =
  Alcotest.check outcome_testable
    "orchestrator-start error classifies as Start_failed"
    (Alert.Start_failed "container never started")
    (Run.outcome_of_result (Error "container never started"))

let test_combine_warnings_none_none () =
  Alcotest.check
    (Alcotest.option Alcotest.string)
    "both None" None
    (Run.combine_warnings None None)

let test_combine_warnings_some_none () =
  Alcotest.check
    (Alcotest.option Alcotest.string)
    "first Some" (Some "a")
    (Run.combine_warnings (Some "a") None)

let test_combine_warnings_none_some () =
  Alcotest.check
    (Alcotest.option Alcotest.string)
    "second Some" (Some "b")
    (Run.combine_warnings None (Some "b"))

let test_combine_warnings_some_some () =
  Alcotest.check
    (Alcotest.option Alcotest.string)
    "both Some" (Some "a; b")
    (Run.combine_warnings (Some "a") (Some "b"))

let () =
  Alcotest.run "Run"
    [
      ( "run_response JSON",
        [
          Alcotest.test_case "with warning" `Quick
            test_run_response_with_warning_json;
          Alcotest.test_case "without warning" `Quick
            test_run_response_without_warning_json;
        ] );
      ( "outcome_of_result",
        [
          Alcotest.test_case "exit code" `Quick test_run_outcome_from_exit_code;
          Alcotest.test_case "start failure" `Quick
            test_run_outcome_from_start_failure;
        ] );
      ( "plan_for_payload",
        [
          Alcotest.test_case "unconfigured dispatches nothing" `Quick
            test_plan_for_payload_unconfigured_dispatches_nothing;
          Alcotest.test_case "failure targets configured sinks" `Quick
            test_plan_for_payload_failure_targets_configured_sinks;
          Alcotest.test_case "success dispatches nothing" `Quick
            test_plan_for_payload_success_dispatches_nothing;
          Alcotest.test_case "critical map targets critical sinks" `Quick
            test_plan_for_payload_critical_map_targets_critical_sinks;
        ] );
      ( "combine_warnings",
        [
          Alcotest.test_case "None + None" `Quick
            test_combine_warnings_none_none;
          Alcotest.test_case "Some + None" `Quick
            test_combine_warnings_some_none;
          Alcotest.test_case "None + Some" `Quick
            test_combine_warnings_none_some;
          Alcotest.test_case "Some + Some" `Quick
            test_combine_warnings_some_some;
        ] );
      ( "networking_conf_of_network",
        [
          Alcotest.test_case "from network" `Quick
            test_networking_conf_from_network;
          Alcotest.test_case "none when network absent" `Quick
            test_networking_conf_none_when_network_absent;
        ] );
      ( "run_opts",
        [
          Alcotest.test_case "carries network" `Quick
            test_run_opts_carries_network;
          Alcotest.test_case "absent network" `Quick
            test_run_opts_absent_network;
        ] );
    ]
