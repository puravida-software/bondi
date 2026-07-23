open Alcotest
module A = Bondi_common.Alert

let severity_to_string = function
  | A.Success -> "success"
  | A.Failure -> "failure"
  | A.Critical -> "critical"

let severity =
  testable (fun ppf s -> Format.fprintf ppf "%s" (severity_to_string s)) ( = )

(* Build a severity map from the wire shape, failing the test if the codec
   rejects a map the test intends to be valid. *)
let map_of pairs =
  match A.severity_map_of_yojson (`Assoc pairs) with
  | Ok m -> m
  | Error e ->
      fail ("expected a valid severity map: " ^ A.severity_map_error_to_string e)

let critical_42 = map_of [ ("critical", `List [ `Int 42 ]) ]

(* Unwrap a sink or fail the test — the fixture is meant to be a valid https
   target. *)
let https url =
  match A.sink_of_string url with
  | Ok s -> s
  | Error e ->
      fail (url ^ " should be a valid sink: " ^ A.sink_error_to_string e)

let pager = "https://pager.example.com/a"
let record = "https://record.example.com/b"
let dashboard = "https://dashboard.example.com/f"

let sinks =
  { A.critical = [ https pager; https record ]; failure = [ https dashboard ] }

(* --- severity classification --- *)

let test_severity_default_zero_success () =
  check severity "exit 0 with no overrides is success" A.Success
    (A.severity_of_exit_code A.default_severity_map 0)

let test_severity_default_nonzero_failure () =
  check severity "exit 1 with no overrides is failure" A.Failure
    (A.severity_of_exit_code A.default_severity_map 1);
  check severity "exit 137 with no overrides is failure" A.Failure
    (A.severity_of_exit_code A.default_severity_map 137)

let test_severity_configured_code_critical () =
  check severity "a code mapped to critical classifies as critical" A.Critical
    (A.severity_of_exit_code critical_42 42)

let test_severity_unmapped_nonzero_failure () =
  check severity "a non-zero code absent from the map falls to failure"
    A.Failure
    (A.severity_of_exit_code critical_42 99)

let test_severity_start_failure_failure () =
  (* FR-2: an orchestrator start failure has no exit code and is failure
     regardless of the per-job map. *)
  check severity "start failure is failure under the default map" A.Failure
    (A.severity_of_outcome A.default_severity_map (A.Start_failed "pull failed"));
  check severity "start failure is failure even when 0 is mapped to critical"
    A.Failure
    (A.severity_of_outcome
       (map_of [ ("critical", `List [ `Int 0 ]) ])
       (A.Start_failed "never started"))

(* --- severity map codec validation --- *)

let test_severity_map_rejects_unknown_key () =
  check bool "a key outside {success,failure,critical} is rejected" true
    (A.severity_map_of_yojson (`Assoc [ ("emergency", `List [ `Int 1 ]) ])
    = Error (A.Unknown_severity "emergency"))

let test_severity_map_rejects_duplicate_code () =
  check bool "one code under two severities is rejected" true
    (A.severity_map_of_yojson
       (`Assoc [ ("critical", `List [ `Int 5 ]); ("failure", `List [ `Int 5 ]) ])
    = Error (A.Duplicate_code 5))

let test_severity_map_non_integer_code_carries_value () =
  check bool "a non-integer code is rejected carrying the offending value" true
    (A.severity_map_of_yojson
       (`Assoc [ ("critical", `List [ `String "oops" ]) ])
    = Error (A.Malformed ("critical", `String "oops")))

(* The map is abstract, so the round trip is observed through the classification
   it drives rather than by comparing representations. A success override (3) is
   included because it is the one override the defaults would otherwise hide. *)
let test_severity_map_json_round_trip () =
  let map =
    map_of
      [
        ("critical", `List [ `Int 42 ]);
        ("failure", `List [ `Int 7 ]);
        ("success", `List [ `Int 3 ]);
      ]
  in
  match A.severity_map_of_yojson (A.severity_map_to_yojson map) with
  | Error e ->
      fail
        ("the severity map should round-trip: "
        ^ A.severity_map_error_to_string e)
  | Ok decoded ->
      check severity "critical override survives" A.Critical
        (A.severity_of_exit_code decoded 42);
      check severity "failure override survives" A.Failure
        (A.severity_of_exit_code decoded 7);
      check severity "success override survives" A.Success
        (A.severity_of_exit_code decoded 3);
      check severity "an unmapped non-zero code still falls to failure"
        A.Failure
        (A.severity_of_exit_code decoded 99)

(* --- plan --- *)

let target_urls dispatch = List.map A.sink_url dispatch.A.targets

let test_plan_success_no_dispatch () =
  check bool "a success outcome dispatches nothing" true
    (A.plan A.default_severity_map (A.Exited 0) sinks ~job:"nightly"
       ~timestamp:0.0
    = None)

let test_plan_critical_targets_all_critical_sinks () =
  match
    A.plan critical_42 (A.Exited 42) sinks ~job:"nightly" ~timestamp:0.0
  with
  | None -> fail "a critical outcome with sinks should dispatch"
  | Some dispatch ->
      check (list string) "every critical sink is targeted" [ pager; record ]
        (target_urls dispatch)

let test_plan_failure_targets_all_failure_sinks () =
  match
    A.plan A.default_severity_map (A.Exited 1) sinks ~job:"nightly"
      ~timestamp:0.0
  with
  | None -> fail "a failure outcome with sinks should dispatch"
  | Some dispatch ->
      check (list string) "every failure sink is targeted" [ dashboard ]
        (target_urls dispatch)

let test_plan_payload_has_job_severity_exit_timestamp () =
  match
    A.plan A.default_severity_map (A.Exited 1) sinks ~job:"nightly"
      ~timestamp:1234.0
  with
  | None -> fail "a failure outcome with sinks should dispatch"
  | Some dispatch -> (
      match A.payload_to_yojson dispatch.A.payload with
      | `Assoc fields ->
          let field name = List.assoc_opt name fields in
          check bool "job" true (field "job" = Some (`String "nightly"));
          check bool "severity" true
            (field "severity" = Some (`String "failure"));
          check bool "exit_code" true (field "exit_code" = Some (`Int 1));
          check bool "timestamp" true (field "timestamp" = Some (`Float 1234.0))
      | _ -> fail "the payload should encode as a JSON object")

(* --- sink validation --- *)

let test_sink_rejects_non_https () =
  check bool "an empty url is rejected" true
    (A.sink_of_string "" = Error A.Empty_url);
  check bool "an http url is rejected as non-https" true
    (A.sink_of_string "http://x.example.com"
    = Error (A.Not_https "http://x.example.com"));
  check bool "a url with no scheme is rejected" true
    (Result.is_error (A.sink_of_string "pager.example.com/hook"))

let test_sink_rejects_invalid_hostname () =
  check bool "an https url whose host is not a valid hostname is rejected" true
    (Result.is_error (A.sink_of_string "https://bad_host.example.com/hook"))

let test_sink_accepts_https () =
  let url = "https://hooks.example.com/services/xyz" in
  match A.sink_of_string url with
  | Error e -> fail ("expected a valid sink: " ^ A.sink_error_to_string e)
  | Ok sink ->
      check string "the url survives" url (A.sink_url sink);
      check string "the host is extracted for redacted logging"
        "hooks.example.com" (A.sink_host sink)

let test_sinks_json_round_trip () =
  match A.sinks_of_yojson (A.sinks_to_yojson sinks) with
  | Error e -> fail ("sinks should round-trip: " ^ e)
  | Ok decoded ->
      check (list string) "critical urls survive the round trip"
        (List.map A.sink_url sinks.A.critical)
        (List.map A.sink_url decoded.A.critical);
      check (list string) "failure urls survive the round trip"
        (List.map A.sink_url sinks.A.failure)
        (List.map A.sink_url decoded.A.failure)

let () =
  run "Alert"
    [
      ( "severity",
        [
          test_case "exit 0 defaults to success" `Quick
            test_severity_default_zero_success;
          test_case "non-zero exit defaults to failure" `Quick
            test_severity_default_nonzero_failure;
          test_case "a configured code is critical" `Quick
            test_severity_configured_code_critical;
          test_case "an unmapped non-zero code is failure" `Quick
            test_severity_unmapped_nonzero_failure;
          test_case "start failure is always failure" `Quick
            test_severity_start_failure_failure;
        ] );
      ( "severity_map",
        [
          test_case "rejects an unknown severity key" `Quick
            test_severity_map_rejects_unknown_key;
          test_case "rejects a duplicated exit code" `Quick
            test_severity_map_rejects_duplicate_code;
          test_case "json round trip preserves overrides" `Quick
            test_severity_map_json_round_trip;
          test_case "a non-integer code carries the offending value" `Quick
            test_severity_map_non_integer_code_carries_value;
        ] );
      ( "plan",
        [
          test_case "success dispatches nothing" `Quick
            test_plan_success_no_dispatch;
          test_case "critical targets all critical sinks" `Quick
            test_plan_critical_targets_all_critical_sinks;
          test_case "failure targets all failure sinks" `Quick
            test_plan_failure_targets_all_failure_sinks;
          test_case "payload carries job, severity, exit and timestamp" `Quick
            test_plan_payload_has_job_severity_exit_timestamp;
        ] );
      ( "sink",
        [
          test_case "rejects non-https urls" `Quick test_sink_rejects_non_https;
          test_case "rejects invalid hostnames" `Quick
            test_sink_rejects_invalid_hostname;
          test_case "accepts https urls" `Quick test_sink_accepts_https;
          test_case "sinks json round trip" `Quick test_sinks_json_round_trip;
        ] );
    ]
