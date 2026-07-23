open Alcotest
module Crontab = Bondi_server__Crontab
module Alert = Bondi_common.Alert

let test_escape_for_shell_no_quotes () =
  check string "no quotes unchanged" "hello world"
    (Crontab.escape_for_shell "hello world")

let test_escape_for_shell_single_quote () =
  check string "single quote escaped" "it'\\''s"
    (Crontab.escape_for_shell "it's")

let test_escape_for_shell_multiple_quotes () =
  check string "multiple quotes escaped" "a'\\''b'\\''c"
    (Crontab.escape_for_shell "a'b'c")

let test_job_name_from_cron_line_valid () =
  let line =
    "* * * * * /usr/bin/curl -s -X POST http://localhost:3030/api/v1/run -H \
     \"Content-Type: application/json\" -d \
     '{\"job\":\"backup\",\"image\":\"img:v1\"}'"
  in
  check (option string) "extracts job name" (Some "backup")
    (Crontab.job_name_from_cron_line line)

let test_job_name_from_cron_line_malformed () =
  let line = "* * * * * echo hello" in
  check (option string) "no -d flag" None (Crontab.job_name_from_cron_line line)

let test_job_name_from_cron_line_no_json () =
  let line = "* * * * * curl -d 'not json'" in
  check (option string) "invalid json" None
    (Crontab.job_name_from_cron_line line)

let test_parse_bondi_section_empty () =
  let outside, bondi = Crontab.parse_bondi_section [] in
  check (list string) "no outside lines" [] outside;
  check (list (pair string string)) "no bondi entries" [] bondi

let test_parse_bondi_section_with_markers () =
  let line =
    "0 * * * * /usr/bin/curl -s -X POST http://localhost:3030/api/v1/run -H \
     \"Content-Type: application/json\" -d \
     '{\"job\":\"backup\",\"image\":\"img:v1\"}'"
  in
  let lines =
    [
      "# some other cron";
      "# BEGIN BONDI CRON";
      line;
      "# END BONDI CRON";
      "# another line";
    ]
  in
  let outside, bondi = Crontab.parse_bondi_section lines in
  check (list string) "outside lines"
    [ "# some other cron"; "# another line" ]
    outside;
  check int "one bondi entry" 1 (List.length bondi);
  check string "job name" "backup" (fst (List.hd bondi))

let test_parse_bondi_section_without_markers () =
  let lines = [ "0 * * * * echo hello"; "30 * * * * echo world" ] in
  let outside, bondi = Crontab.parse_bondi_section lines in
  check (list string) "all lines outside" lines outside;
  check (list (pair string string)) "no bondi entries" [] bondi

let mk_cron_job ?network ?alert_sinks ?exit_code_severities ~name ~image
    ~schedule () : Bondi_server__Strategy__Simple.cron_job =
  {
    name;
    image;
    schedule;
    network;
    env_vars = None;
    registry_user = None;
    registry_pass = None;
    alert_sinks;
    exit_code_severities;
  }

(* The crontab line is written by Crontab.run_payload and parsed back by
   Run.run_payload; the round trip is what pins the two in sync. *)
let network_of_cron_line line =
  match Crontab.json_from_cron_line line with
  | None -> Alcotest.fail "no JSON payload in cron line"
  | Some json -> (
      match Bondi_server__Run.run_payload_of_yojson json with
      | Error msg -> Alcotest.fail ("run payload rejected the cron line: " ^ msg)
      | Ok (payload : Bondi_server__Run.run_payload) -> payload.network)

let test_cron_line_preserves_network () =
  let job =
    mk_cron_job ~network:"bondi-network" ~name:"backup" ~image:"myimg:v1"
      ~schedule:"0 * * * *" ()
  in
  check (option string) "network survives write and parse"
    (Some "bondi-network")
    (network_of_cron_line (Crontab.entry_of_cron_job job))

let test_cron_line_absent_network_round_trips () =
  let job =
    mk_cron_job ~name:"backup" ~image:"myimg:v1" ~schedule:"0 * * * *" ()
  in
  check (option string) "absent network stays absent" None
    (network_of_cron_line (Crontab.entry_of_cron_job job))

(* The alert fields are written by Crontab.run_payload and parsed back by
   Run.run_payload; the round trip is what pins the two records in sync. *)
let alert_config_of_cron_line line =
  match Crontab.json_from_cron_line line with
  | None -> Alcotest.fail "no JSON payload in cron line"
  | Some json -> (
      match Bondi_server__Run.run_payload_of_yojson json with
      | Error msg -> Alcotest.fail ("run payload rejected the cron line: " ^ msg)
      | Ok (payload : Bondi_server__Run.run_payload) ->
          (payload.alert_sinks, payload.exit_code_severities))

let test_cron_alert_config_round_trip () =
  let sinks =
    match
      Alert.sinks_of_yojson
        (Yojson.Safe.from_string
           {|{"critical":["https://pager.example.com/hook","https://record.example.com/hook"],"failure":["https://dash.example.com/hook"]}|})
    with
    | Ok s -> s
    | Error msg -> fail ("bad sinks fixture: " ^ msg)
  in
  let severities =
    match
      Alert.severity_map_of_yojson
        (Yojson.Safe.from_string {|{"critical":[70]}|})
    with
    | Ok m -> m
    | Error _ -> fail "bad severity_map fixture"
  in
  let job =
    mk_cron_job ~alert_sinks:sinks ~exit_code_severities:severities
      ~name:"backup" ~image:"myimg:v1" ~schedule:"0 * * * *" ()
  in
  let alert_sinks, exit_code_severities =
    alert_config_of_cron_line (Crontab.entry_of_cron_job job)
  in
  (match alert_sinks with
  | None -> fail "alert_sinks did not survive the round trip"
  | Some Alert.{ critical; failure } -> (
      (match critical with
      | [ a; b ] ->
          check string "critical sink 0" "https://pager.example.com/hook"
            (Alert.sink_url a);
          check string "critical sink 1" "https://record.example.com/hook"
            (Alert.sink_url b)
      | _ -> fail "expected two critical sinks after round trip");
      match failure with
      | [ f ] ->
          check string "failure sink" "https://dash.example.com/hook"
            (Alert.sink_url f)
      | _ -> fail "expected one failure sink after round trip"));
  match exit_code_severities with
  | None -> fail "exit_code_severities did not survive the round trip"
  | Some map ->
      check bool "code 70 is critical after round trip" true
        (Alert.severity_of_exit_code map 70 = Alert.Critical);
      check bool "code 1 defaults to failure after round trip" true
        (Alert.severity_of_exit_code map 1 = Alert.Failure)

let test_entry_of_cron_job () =
  let job =
    mk_cron_job ~name:"backup" ~image:"myimg:v1" ~schedule:"0 * * * *" ()
  in
  let entry = Crontab.entry_of_cron_job job in
  check bool "starts with schedule" true
    (Bondi_common.String_utils.starts_with ~prefix:"0 * * * *" entry);
  check bool "contains curl" true
    (Bondi_common.String_utils.contains ~needle:"curl" entry);
  check bool "contains job name" true
    (Bondi_common.String_utils.contains ~needle:"backup" entry)

let test_generate_bondi_entries () =
  let jobs =
    [
      mk_cron_job ~name:"a" ~image:"img:v1" ~schedule:"0 * * * *" ();
      mk_cron_job ~name:"b" ~image:"img:v2" ~schedule:"30 * * * *" ();
    ]
  in
  let entries = Crontab.generate_bondi_entries jobs in
  check string "first line is begin marker" "# BEGIN BONDI CRON"
    (List.hd entries);
  check string "last line is end marker" "# END BONDI CRON"
    (List.nth entries (List.length entries - 1));
  check int "3 lines total (marker + 2 jobs + marker)" 4 (List.length entries)

let scheduled_job_testable =
  let pp fmt (j : Crontab.scheduled_job) =
    Format.fprintf fmt "{ name = %s; image = %s }" j.name j.image
  in
  testable pp Crontab.equal_scheduled_job

let test_image_from_cron_line () =
  let line =
    "0 * * * * /usr/bin/curl -s -X POST http://localhost:3030/api/v1/run -H \
     \"Content-Type: application/json\" -d \
     '{\"job\":\"backup\",\"image\":\"ghcr.io/org/backup:v2.1.0\"}'"
  in
  check (option string) "extracts image" (Some "ghcr.io/org/backup:v2.1.0")
    (Crontab.image_from_cron_line line)

let test_image_from_cron_line_no_match () =
  let line = "0 * * * * echo hello" in
  check (option string) "no match for non-bondi line" None
    (Crontab.image_from_cron_line line)

let test_parse_scheduled_jobs () =
  let lines =
    [
      "# some other cron";
      "# BEGIN BONDI CRON";
      "0 * * * * /usr/bin/curl -s -X POST http://localhost:3030/api/v1/run -H \
       \"Content-Type: application/json\" -d \
       '{\"job\":\"backup\",\"image\":\"ghcr.io/org/backup:v2.1.0\"}'";
      "30 2 * * * /usr/bin/curl -s -X POST http://localhost:3030/api/v1/run -H \
       \"Content-Type: application/json\" -d \
       '{\"job\":\"cleanup\",\"image\":\"ghcr.io/org/cleanup:latest\"}'";
      "# END BONDI CRON";
    ]
  in
  let expected : Crontab.scheduled_job list =
    [
      { name = "backup"; image = "ghcr.io/org/backup:v2.1.0" };
      { name = "cleanup"; image = "ghcr.io/org/cleanup:latest" };
    ]
  in
  check
    (list scheduled_job_testable)
    "parses two scheduled jobs" expected
    (Crontab.parse_scheduled_jobs lines)

let test_parse_scheduled_jobs_empty () =
  check
    (list scheduled_job_testable)
    "empty input" []
    (Crontab.parse_scheduled_jobs [])

let () =
  run "Crontab"
    [
      ( "escape_for_shell",
        [
          test_case "no quotes" `Quick test_escape_for_shell_no_quotes;
          test_case "single quote" `Quick test_escape_for_shell_single_quote;
          test_case "multiple quotes" `Quick
            test_escape_for_shell_multiple_quotes;
        ] );
      ( "job_name_from_cron_line",
        [
          test_case "valid cron line" `Quick test_job_name_from_cron_line_valid;
          test_case "malformed line" `Quick
            test_job_name_from_cron_line_malformed;
          test_case "no json" `Quick test_job_name_from_cron_line_no_json;
        ] );
      ( "parse_bondi_section",
        [
          test_case "empty" `Quick test_parse_bondi_section_empty;
          test_case "with markers" `Quick test_parse_bondi_section_with_markers;
          test_case "without markers" `Quick
            test_parse_bondi_section_without_markers;
        ] );
      ( "entry_of_cron_job",
        [
          test_case "produces valid entry" `Quick test_entry_of_cron_job;
          test_case "preserves network" `Quick test_cron_line_preserves_network;
          test_case "absent network round trips" `Quick
            test_cron_line_absent_network_round_trips;
          test_case "preserves alert config" `Quick
            test_cron_alert_config_round_trip;
        ] );
      ( "generate_bondi_entries",
        [
          test_case "includes markers and entries" `Quick
            test_generate_bondi_entries;
        ] );
      ( "scheduled_jobs",
        [
          test_case "image from cron line" `Quick test_image_from_cron_line;
          test_case "image from non-bondi line" `Quick
            test_image_from_cron_line_no_match;
          test_case "parse scheduled jobs" `Quick test_parse_scheduled_jobs;
          test_case "parse scheduled jobs empty" `Quick
            test_parse_scheduled_jobs_empty;
        ] );
    ]
