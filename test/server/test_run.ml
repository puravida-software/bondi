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

(* The pre-start half of [/run]. [Run.prepare] is the seam these exercise
   because everything past it needs a Docker client and an Eio net; the two
   status cases assert the failure classifier, which is what [route] reads. *)

let alerting_sinks_json =
  `Assoc
    [
      ("critical", `List [ `String "https://page.example.com/x" ]);
      ("failure", `List [ `String "https://sink.example.com/x" ]);
    ]

let run_body ?alert_sinks ~image () =
  let fields =
    [ ("job", `String "nightly"); ("image", `String image) ]
    @
    match alert_sinks with
    | None -> []
    | Some sinks -> [ ("alert_sinks", sinks) ]
  in
  Yojson.Safe.to_string (`Assoc fields)

let recording_deliver dispatched ~targets ~payload:_ =
  dispatched := !dispatched @ [ List.map Alert.sink_url targets ]

let prepare_must_fail ~deliver body =
  match Run.prepare ~deliver body with
  | Ok _ -> Alcotest.fail ("prepare accepted a body it must reject: " ^ body)
  | Error err -> err

(* Without this the dispatch tests are vacuous in the same direction: a fixture
   the decoder rejected would also dispatch nothing, and the absence arm would
   pass for the wrong reason. *)
let check_untagged_image_failure err =
  Alcotest.(check bool)
    "the failure is the untagged image, not an earlier rejection" true
    (Bondi_common.String_utils.contains ~needle:"has no tag"
       (Run.run_error_message err))

let test_prepare_accepts_a_tagged_image () =
  let dispatched = ref [] in
  match
    Run.prepare
      ~deliver:(recording_deliver dispatched)
      (run_body ~alert_sinks:alerting_sinks_json ~image:"myapp:v1" ())
  with
  | Error err ->
      Alcotest.fail
        ("prepare rejected a valid body: " ^ Run.run_error_message err)
  | Ok (payload, full_image) ->
      Alcotest.(check string) "the tagged image survives" "myapp:v1" full_image;
      Alcotest.(check string) "the job name survives" "nightly" payload.Run.job;
      Alcotest.(check (list (list string)))
        "a run that is about to start dispatches nothing" [] !dispatched

let test_run_dispatches_alert_on_image_parse_failure () =
  let dispatched = ref [] in
  let body = run_body ~alert_sinks:alerting_sinks_json ~image:"myapp" () in
  check_untagged_image_failure
    (prepare_must_fail ~deliver:(recording_deliver dispatched) body);
  (* Only the failure sink: a job that never started routes to [Failure], so a
     dispatch reaching the critical sink would be a mis-route, not a pass. *)
  Alcotest.(check (list (list string)))
    "one alert, routed to the configured failure sink"
    [ [ "https://sink.example.com/x" ] ]
    !dispatched

let test_run_dispatches_no_alert_when_unconfigured () =
  let dispatched = ref [] in
  let body = run_body ~image:"myapp" () in
  check_untagged_image_failure
    (prepare_must_fail ~deliver:(recording_deliver dispatched) body);
  Alcotest.(check (list (list string)))
    "the same failure with no sinks configured dispatches nothing" []
    !dispatched

let test_run_status_for_malformed_body () =
  let dispatched = ref [] in
  let err =
    prepare_must_fail ~deliver:(recording_deliver dispatched) "{\"job\": "
  in
  Alcotest.(check int)
    "a malformed body answers a client error, not 404" 400
    (Dream.status_to_int (Run.status_of_run_error err));
  Alcotest.(check (list (list string)))
    "a body that names no job has no sinks to alert to" [] !dispatched

(* The ppx names only the type that failed, so on its own the message cannot
   tell a misspelled key from a missing one. The keys that arrived are named to
   close that gap; their values never are, because a run payload carries
   env_vars and sink URLs that may embed credentials and this message is
   returned over HTTP and mailed by cron. *)
let test_run_decode_error_names_keys_not_values () =
  let dispatched = ref [] in
  let body =
    Yojson.Safe.to_string
      (`Assoc
         [
           ("job", `String "nightly");
           ("imag", `String "myapp:v1");
           ("env_vars", `Assoc [ ("TOKEN", `String "s3cr3t") ]);
         ])
  in
  let msg =
    Run.run_error_message
      (prepare_must_fail ~deliver:(recording_deliver dispatched) body)
  in
  List.iter
    (fun needle ->
      Alcotest.(check bool)
        (Printf.sprintf "the message names the key %s: %s" needle msg)
        true
        (Bondi_common.String_utils.contains ~needle msg))
    [ "job"; "imag"; "env_vars" ];
  Alcotest.(check bool)
    ("no value from the rejected body is echoed: " ^ msg)
    false
    (Bondi_common.String_utils.contains ~needle:"s3cr3t" msg)

(* Cleanup runs only when the container both started and finished. Removing the
   previous container before a failed run has been reported would destroy the
   only copy of what ran last, and renaming a container that never started has
   nothing to rename — so both failure arms skip it and carry no warning. *)
let warning_with ~started ~run_result =
  let cleaned = ref false in
  let warning =
    Run.warning_of_run ~started ~run_result ~cleanup:(fun _container_id ->
        cleaned := true;
        Some "cleanup ran")
  in
  (!cleaned, warning)

let test_warning_runs_cleanup_when_the_run_completed () =
  let cleaned, warning =
    warning_with ~started:(Ok "abc123") ~run_result:(Ok 0)
  in
  Alcotest.(check bool) "a completed run cleans up" true cleaned;
  Alcotest.(check (option string))
    "and carries whatever the cleanup reported" (Some "cleanup ran") warning

let test_warning_skips_cleanup_when_the_wait_failed () =
  let cleaned, warning =
    warning_with ~started:(Ok "abc123") ~run_result:(Error "wait failed")
  in
  Alcotest.(check bool)
    "a run that never finished does not clean up" false cleaned;
  Alcotest.(check (option string)) "and carries no warning" None warning

let test_warning_skips_cleanup_when_the_start_failed () =
  let cleaned, warning =
    warning_with ~started:(Error "no such image")
      ~run_result:(Error "no such image")
  in
  Alcotest.(check bool)
    "a run that never started does not clean up" false cleaned;
  Alcotest.(check (option string)) "and carries no warning" None warning

let test_run_status_for_orchestrator_failure () =
  match
    Run.response_of_run_result ~warning:None
      (Error "docker http 500: internal server error")
  with
  | Ok _ ->
      Alcotest.fail "a Docker-level failure must not answer as a run result"
  | Error err ->
      Alcotest.(check int)
        "an orchestrator fault answers a server error, not 404" 500
        (Dream.status_to_int (Run.status_of_run_error err))

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
      ( "prepare",
        [
          Alcotest.test_case "accepts a tagged image" `Quick
            test_prepare_accepts_a_tagged_image;
          Alcotest.test_case "dispatches an alert on image parse failure" `Quick
            test_run_dispatches_alert_on_image_parse_failure;
          Alcotest.test_case "dispatches no alert when unconfigured" `Quick
            test_run_dispatches_no_alert_when_unconfigured;
          Alcotest.test_case "decode error names keys, not values" `Quick
            test_run_decode_error_names_keys_not_values;
        ] );
      ( "run failure status",
        [
          Alcotest.test_case "malformed body" `Quick
            test_run_status_for_malformed_body;
          Alcotest.test_case "orchestrator failure" `Quick
            test_run_status_for_orchestrator_failure;
        ] );
      ( "warning_of_run",
        [
          Alcotest.test_case "cleans up after a completed run" `Quick
            test_warning_runs_cleanup_when_the_run_completed;
          Alcotest.test_case "skips cleanup when the wait failed" `Quick
            test_warning_skips_cleanup_when_the_wait_failed;
          Alcotest.test_case "skips cleanup when the start failed" `Quick
            test_warning_skips_cleanup_when_the_start_failed;
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
