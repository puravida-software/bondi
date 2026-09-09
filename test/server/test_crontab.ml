open Alcotest
module Crontab = Bondi_server__Crontab
module Alert = Bondi_common.Alert

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

let mk_cron_job ?network ?env_vars ?alert_sinks ?exit_code_severities ~name
    ~image ~schedule () : Bondi_server__Strategy__Simple.cron_job =
  {
    name;
    image;
    schedule;
    network;
    env_vars;
    secret_env_vars = None;
    registry_user = None;
    registry_pass = None;
    alert_sinks;
    exit_code_severities;
  }

(* A legacy line: the [curl -d '<json>'] shape Bondi wrote before the payload
   moved to a file. Nothing generates this any more, so the fixtures below are
   literals rather than calls to the generator -- a line built by the generator
   would pin the new shape, not the shape the scanner has to keep reading. Every
   crontab in the estate holds lines like this and they still fire. *)
let legacy_line payload_json =
  "0 * * * * /usr/bin/curl -sS --fail-with-body -X POST \
   http://localhost:3030/api/v1/run -H \"Content-Type: application/json\" -d '"
  ^ payload_json ^ "'"

let network_of_cron_line line =
  match Crontab.json_from_cron_line line with
  | None -> Alcotest.fail "no JSON payload in cron line"
  | Some json -> (
      match Bondi_server__Run.run_payload_of_yojson json with
      (* The message is dropped rather than shown: a decoder error can quote the
         value it rejected, and a legacy line's payload is the job. *)
      | Error _ -> Alcotest.fail "the run decoder rejected the legacy line"
      | Ok (payload : Bondi_server__Run.run_payload) -> payload.network)

let test_legacy_line_preserves_network () =
  check (option string) "network survives the scanner and the decoder"
    (Some "bondi-network")
    (network_of_cron_line
       (legacy_line
          {|{"job":"backup","image":"myimg:v1","network":"bondi-network"}|}))

let test_legacy_line_absent_network_round_trips () =
  check (option string) "absent network stays absent" None
    (network_of_cron_line (legacy_line {|{"job":"backup","image":"myimg:v1"}|}))

let alert_config_of_cron_line line =
  match Crontab.json_from_cron_line line with
  | None -> Alcotest.fail "no JSON payload in cron line"
  | Some json -> (
      match Bondi_server__Run.run_payload_of_yojson json with
      | Error _ -> Alcotest.fail "the run decoder rejected the legacy line"
      | Ok (payload : Bondi_server__Run.run_payload) ->
          (payload.alert_sinks, payload.exit_code_severities))

let test_legacy_line_alert_config_round_trip () =
  let alert_sinks, exit_code_severities =
    alert_config_of_cron_line
      (legacy_line
         {|{"job":"backup","image":"myimg:v1","alert_sinks":{"critical":["https://pager.example.com/hook","https://record.example.com/hook"],"failure":["https://dash.example.com/hook"]},"exit_code_severities":{"critical":[70]}}|})
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

(* Cron only learns a run failed if the command exits non-zero, and the operator
   only learns why if the server's message survives. Measured against curl
   8.5.0: [curl -s] exits 0 on a 400 and prints nothing; [curl -fsS] exits 22
   but -f discards the response body, so the message reads only "curl: (22) The
   requested URL returned error: 400"; [curl -sS --fail-with-body] exits 22 and
   prints the server's own text after it. Those flags sit ahead of the payload
   in every hardened legacy line, and the scanner anchors on the first "-d '",
   so what is left to pin is that the flags do not shift that anchor. *)
let test_legacy_hardened_flags_do_not_shift_the_anchor () =
  let line = legacy_line {|{"job":"backup","image":"myimg:v1"}|} in
  check bool "the hardened flags precede the payload" true
    (Bondi_common.String_utils.contains
       ~needle:"/usr/bin/curl -sS --fail-with-body -X POST" line);
  check (option string) "the payload is still found after them" (Some "backup")
    (Crontab.job_name_from_cron_line line)

(* Both arms run on one fixture. An absence assertion over a job with no
   environment passes whatever the generator does, so the fixture carries a
   value distinctive enough that finding it anywhere in the line is proof. *)
let distinctive_env_value = "paper-9f3c2a"

let payload_fixture () =
  mk_cron_job ~network:"bondi-network"
    ~env_vars:[ ("RUN_ENV", distinctive_env_value) ]
    ~name:"backup" ~image:"myimg:v1" ~schedule:"0 * * * *" ()

(* The oracle is the run endpoint's own decoder, which rejects unknown fields:
   what the generator writes into the file and what the endpoint accepts are one
   contract, and a hand-written expected string would let the two drift. The
   decoder's message is dropped rather than shown, because a decode error can
   quote the value it rejected and that value is the payload. *)
let run_payload_of job =
  match
    Bondi_server__Run.run_payload_of_yojson
      (Crontab.run_payload_of_cron_job job)
  with
  | Error _ ->
      Alcotest.fail "the run decoder rejected the generated run payload"
  | Ok (payload : Bondi_server__Run.run_payload) -> payload

let test_generated_line_carries_no_payload () =
  let entry = Crontab.entry_of_cron_job (payload_fixture ()) in
  check bool "no environment value in the line" false
    (Bondi_common.String_utils.contains ~needle:distinctive_env_value entry);
  check bool "no environment key in the line" false
    (Bondi_common.String_utils.contains ~needle:"RUN_ENV" entry);
  check bool "no image in the line" false
    (Bondi_common.String_utils.contains ~needle:"myimg:v1" entry);
  check bool "no curl payload flag in the line" false
    (Bondi_common.String_utils.contains ~needle:"-d '" entry)

let test_run_payload_carries_what_the_line_omits () =
  let payload = run_payload_of (payload_fixture ()) in
  check string "job" "backup" payload.job;
  check string "image" "myimg:v1" payload.image;
  check (option string) "network" (Some "bondi-network") payload.network;
  match payload.env_vars with
  | None -> fail "the run payload dropped the job's environment"
  | Some env ->
      check (option string) "the value the line omits is in the run payload"
        (Some distinctive_env_value)
        (List.assoc_opt "RUN_ENV" env)

let test_run_payload_omits_absent_network () =
  let job =
    mk_cron_job ~name:"backup" ~image:"myimg:v1" ~schedule:"0 * * * *" ()
  in
  check (option string) "absent network stays absent" None
    (run_payload_of job).network

let test_line_names_the_jobs_run_file () =
  let entry = Crontab.entry_of_cron_job (payload_fixture ()) in
  check bool "starts with the schedule" true
    (Bondi_common.String_utils.starts_with ~prefix:"0 * * * *" entry);
  check bool "execs the run subcommand inside the orchestrator" true
    (Bondi_common.String_utils.contains
       ~needle:"docker exec bondi-orchestrator sh -c" entry);
  check bool "reads the job's run file" true
    (Bondi_common.String_utils.contains
       ~needle:"bondi-server run < /etc/bondi/cron/backup/run.json" entry)

(* /etc/bondi/cron/api/ is a prefix of /etc/bondi/cron/api2/, so a check on the
   directory alone passes for the wrong job. The needle carries the /run.json
   that bounds the segment on the right, and api2 is asserted against api's
   needle so the bound is shown to do work. *)
let test_line_path_is_delimiter_bounded () =
  let line_for name =
    Crontab.entry_of_cron_job
      (mk_cron_job ~name ~image:"img:v1" ~schedule:"0 * * * *" ())
  in
  let api_run_file = "/etc/bondi/cron/api/run.json" in
  check bool "api's line names api's run file" true
    (Bondi_common.String_utils.contains ~needle:api_run_file (line_for "api"));
  check bool "api2's line does not name api's run file" false
    (Bondi_common.String_utils.contains ~needle:api_run_file (line_for "api2"));
  check bool "api2's line names its own run file" true
    (Bondi_common.String_utils.contains ~needle:"/etc/bondi/cron/api2/run.json"
       (line_for "api2"))

let test_generate_bondi_entries () =
  let jobs =
    [
      mk_cron_job ~name:"a" ~image:"img:v1" ~schedule:"0 * * * *" ();
      mk_cron_job ~name:"b" ~image:"img:v2" ~schedule:"30 * * * *" ();
    ]
  in
  match Crontab.generate_bondi_entries jobs with
  | [ first; _; _; last ] ->
      check string "first line is begin marker" "# BEGIN BONDI CRON" first;
      check string "last line is end marker" "# END BONDI CRON" last
  | _ -> fail "expected a begin marker, two job lines and an end marker"

let listed_job_testable =
  let pp fmt (j : Crontab.listed_job) =
    match j with
    | Crontab.Job { name; image } ->
        Format.fprintf fmt "Job { name = %s; image = %s }" name image
    | Crontab.Unreadable { position } ->
        Format.fprintf fmt "Unreadable { position = %d }" position
  in
  testable pp Crontab.equal_listed_job

(* The reader's file seam, closed over a fixed table. Answering [None] for
   every path but the ones listed is what makes a resolver that opened a path
   the line did not name fail here rather than pass. *)
let reader_for files path = List.assoc_opt path files
let no_files (_ : string) = None
let backup_run_file = "/etc/bondi/cron/backup/run.json"

let run_file_contents (job : Bondi_server__Strategy__Simple.cron_job) =
  Yojson.Safe.to_string (Crontab.run_payload_of_cron_job job)

let section lines = ("# BEGIN BONDI CRON" :: lines) @ [ "# END BONDI CRON" ]

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

let test_parse_listed_jobs () =
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
  let expected : Crontab.listed_job list =
    [
      Crontab.Job { name = "backup"; image = "ghcr.io/org/backup:v2.1.0" };
      Crontab.Job { name = "cleanup"; image = "ghcr.io/org/cleanup:latest" };
    ]
  in
  check (list listed_job_testable) "parses two scheduled jobs" expected
    (Crontab.parse_listed_jobs ~read_file:no_files lines)

let test_parse_listed_jobs_empty () =
  check (list listed_job_testable) "empty input" []
    (Crontab.parse_listed_jobs ~read_file:no_files [])

(* [upsert] leaves a line for a job the deploy does not name exactly where it
   found it, so both legacy shapes outlive this change and both must still read.
   The [curl -s] fixtures above are the unhardened one; this is the hardened
   one, whose extra flags sit between the schedule and the payload. Neither is
   generated any more, which is why this fixture is a literal. *)
let test_crontab_parse_reads_hardened_line () =
  let line =
    legacy_line {|{"job":"backup","image":"ghcr.io/org/backup:v2.1.0"}|}
  in
  check (option string) "job name from hardened line" (Some "backup")
    (Crontab.job_name_from_cron_line line);
  check (option string) "image from hardened line"
    (Some "ghcr.io/org/backup:v2.1.0")
    (Crontab.image_from_cron_line line);
  check (list listed_job_testable) "scheduled jobs from hardened line"
    [ Crontab.Job { name = "backup"; image = "ghcr.io/org/backup:v2.1.0" } ]
    (Crontab.parse_listed_jobs ~read_file:no_files (section [ line ]))

(* --- the reader: two shapes, and a third answer that is not silence ------- *)

(* The line comes from the real generator and the file from the real payload
   builder, so a change that repointed one without the other fails here. *)
let test_exec_line_resolves_through_its_run_file () =
  let job = payload_fixture () in
  check (list listed_job_testable)
    "the exec line resolves to the job its file declares"
    [ Crontab.Job { name = "backup"; image = "myimg:v1" } ]
    (Crontab.parse_listed_jobs
       ~read_file:(reader_for [ (backup_run_file, run_file_contents job) ])
       (section [ Crontab.entry_of_cron_job job ]))

(* [no_files] is the assertion: a legacy line carries its own payload, so a
   reader that consulted the filesystem for one would come back empty here. *)
let test_legacy_line_still_resolves_through_the_scanner () =
  check (list listed_job_testable) "the legacy line resolves without any file"
    [ Crontab.Job { name = "backup"; image = "ghcr.io/org/backup:v2.1.0" } ]
    (Crontab.parse_listed_jobs ~read_file:no_files
       (section
          [
            legacy_line {|{"job":"backup","image":"ghcr.io/org/backup:v2.1.0"}|};
          ]))

(* Two entries out, not one. The section reader this feature replaced dropped
   the second, and the section read as a single job; this test exists to end
   exactly that. *)
let test_unparseable_line_is_unreadable_not_omitted () =
  let job = payload_fixture () in
  check (list listed_job_testable)
    "the line neither reader resolves is reported in place"
    [
      Crontab.Job { name = "backup"; image = "myimg:v1" };
      Crontab.Unreadable { position = 2 };
    ]
    (Crontab.parse_listed_jobs
       ~read_file:(reader_for [ (backup_run_file, run_file_contents job) ])
       (section [ Crontab.entry_of_cron_job job; "0 * * * * echo hello" ]))

let test_missing_run_file_is_unreadable_not_omitted () =
  let job = payload_fixture () in
  let lines = section [ Crontab.entry_of_cron_job job ] in
  check (list listed_job_testable)
    "a line whose file is gone is reported, not dropped"
    [ Crontab.Unreadable { position = 1 } ]
    (Crontab.parse_listed_jobs ~read_file:no_files lines);
  (* Affirmative arm on the same fixture: the line does reach the resolver and
     the resolver can answer [Job] for it, so the entry above is unreadable
     because of the missing file and not because the line was never resolved. *)
  check (list listed_job_testable) "the same line with its file present"
    [ Crontab.Job { name = "backup"; image = "myimg:v1" } ]
    (Crontab.parse_listed_jobs
       ~read_file:(reader_for [ (backup_run_file, run_file_contents job) ])
       lines)

(* The name comes from the path and the image from the file. They are one
   contract, so a file sitting under backup/ and declaring itself restore makes
   neither fact trustworthy. *)
let test_job_disagreeing_with_path_is_unreadable () =
  let job = payload_fixture () in
  let lines = section [ Crontab.entry_of_cron_job job ] in
  let impostor =
    run_file_contents
      (mk_cron_job ~name:"restore" ~image:"myimg:v1" ~schedule:"0 * * * *" ())
  in
  check (list listed_job_testable)
    "backup's file declaring restore is unreadable"
    [ Crontab.Unreadable { position = 1 } ]
    (Crontab.parse_listed_jobs
       ~read_file:(reader_for [ (backup_run_file, impostor) ])
       lines);
  (* Affirmative arm: the same path, the same reader, a file that agrees. *)
  check (list listed_job_testable) "backup's file declaring backup reads"
    [ Crontab.Job { name = "backup"; image = "myimg:v1" } ]
    (Crontab.parse_listed_jobs
       ~read_file:(reader_for [ (backup_run_file, run_file_contents job) ])
       lines)

(* The unreadable line here carries a value, so a report quoting it would be a
   leak. [listed_job] has nowhere to put a line, which closes that half by
   construction the way {!Crontab_listing.Unnamed} does -- a field carrying the
   line could only arrive by editing this expectation.

   The half that is behaviour is the position: it is the entry's place in the
   SECTION, counting from one, which is what makes "go and look" possible
   without rendering the line. The offending line is the fourth in the file and
   the second in the section, so a reader counting file lines fails here. *)
let test_unreadable_entry_reports_a_position_not_a_line () =
  let job = payload_fixture () in
  let line_holding_a_value =
    "0 * * * * /usr/bin/curl -d 'RUN_ENV=" ^ distinctive_env_value ^ "'"
  in
  check (list listed_job_testable)
    "the position is the entry's place in the section"
    [
      Crontab.Job { name = "backup"; image = "myimg:v1" };
      Crontab.Unreadable { position = 2 };
    ]
    (Crontab.parse_listed_jobs
       ~read_file:(reader_for [ (backup_run_file, run_file_contents job) ])
       ("# some other cron"
       :: section [ Crontab.entry_of_cron_job job; line_holding_a_value ]))

(* --- upsert: merging across a section that holds both shapes -------------- *)

(* The state every box in the estate is in for at least one deploy: a legacy
   line for a job the next deploy names, a legacy line for one it does not, a
   line this feature's generator wrote, and a line neither reader can resolve.

   The legacy JSON carries spaces the encoder does not emit, so a merge that
   re-rendered a preserved line from its parsed payload would not produce these
   bytes: "byte for byte" below is a claim about the literal, not about a
   payload that happens to round-trip. *)
let backup_legacy_line =
  legacy_line {|{"job": "backup", "image": "ghcr.io/org/backup:v1"}|}

let cleanup_legacy_line =
  legacy_line {|{"job": "cleanup", "image": "ghcr.io/org/cleanup:v1"}|}

let unresolvable_line = "0 4 * * * echo hand-written"

let reports_job =
  mk_cron_job ~name:"reports" ~image:"ghcr.io/org/reports:v3"
    ~schedule:"15 6 * * *" ()

let redeployed_backup =
  mk_cron_job ~network:"bondi-network" ~name:"backup"
    ~image:"ghcr.io/org/backup:v2" ~schedule:"0 * * * *" ()

let added_metrics =
  mk_cron_job ~name:"metrics" ~image:"ghcr.io/org/metrics:v1"
    ~schedule:"*/5 * * * *" ()

let mixed_crontab_lines =
  "# some other cron"
  :: section
       [
         backup_legacy_line;
         Crontab.entry_of_cron_job reports_job;
         unresolvable_line;
         cleanup_legacy_line;
       ]

let merged_mixed_section () =
  Crontab.merge_bondi_section
    (Some [ redeployed_backup; added_metrics ])
    mixed_crontab_lines

let is_legacy_line line = Option.is_some (Crontab.json_from_cron_line line)

(* A legacy line for a job this deploy does not name survives unchanged.
   Filtering rather than searching gives the affirmative arm on the same
   fixture: backup's legacy line is the one that had to go, and if the merge
   kept both -- or kept neither -- this list is not the one below. *)
let test_legacy_line_for_an_unnamed_job_is_preserved_byte_for_byte () =
  check (list string) "the legacy lines the merge left in the crontab"
    [ cleanup_legacy_line ]
    (List.filter is_legacy_line (merged_mixed_section ()))

(* A section holding one job twice: a restored crontab backup, or a hand edit
   applied to half the file, leaves the legacy line and the exec line for the
   same job side by side. Rewriting each of them where it stood emits the job's
   line twice, and cron fires the job twice a schedule. *)
let doubly_held_backup_lines =
  section
    [
      backup_legacy_line;
      Crontab.entry_of_cron_job redeployed_backup;
      cleanup_legacy_line;
    ]

let test_a_name_the_section_holds_twice_is_written_once () =
  let merged =
    Crontab.merge_bondi_section (Some [ redeployed_backup ])
      doubly_held_backup_lines
  in
  check int "the redeployed job's line is written once, not once per entry" 1
    (List.length
       (List.filter
          (String.equal (Crontab.entry_of_cron_job redeployed_backup))
          merged));
  check (list string) "and an entry naming another job is untouched"
    [ cleanup_legacy_line ]
    (List.filter is_legacy_line merged)

(* The other half of the same rule. The place matters as much as the shape: the new line
   stands where the legacy one stood, which is what keeps a redeploy from
   reordering a section it only meant to update. *)
let test_legacy_line_for_a_redeployed_job_is_replaced_by_the_new_shape () =
  let merged = merged_mixed_section () in
  check (option int) "the legacy line for backup stood third in the crontab"
    (Some 2)
    (List.find_index (String.equal backup_legacy_line) mixed_crontab_lines);
  check (option int) "backup's new-shape line stands where it stood" (Some 2)
    (List.find_index
       (String.equal (Crontab.entry_of_cron_job redeployed_backup))
       merged);
  check (option int) "and the legacy line for backup is gone" None
    (List.find_index (String.equal backup_legacy_line) merged)

(* The section goes out through the real generator and comes back through
   the real reader, with the run files the deploy would have written: the
   payload moves at three sites in this feature and a partial reroute leaves
   this red. cleanup is resolved from its own legacy line and needs no file. *)
let test_mixed_section_round_trips_through_generate_and_parse () =
  let files =
    [
      ("/etc/bondi/cron/backup/run.json", run_file_contents redeployed_backup);
      ("/etc/bondi/cron/reports/run.json", run_file_contents reports_job);
      ("/etc/bondi/cron/metrics/run.json", run_file_contents added_metrics);
    ]
  in
  check (list listed_job_testable)
    "every entry of the merged section, resolved in place"
    [
      Crontab.Job { name = "backup"; image = "ghcr.io/org/backup:v2" };
      Crontab.Job { name = "reports"; image = "ghcr.io/org/reports:v3" };
      Crontab.Unreadable { position = 3 };
      Crontab.Job { name = "cleanup"; image = "ghcr.io/org/cleanup:v1" };
      Crontab.Job { name = "metrics"; image = "ghcr.io/org/metrics:v1" };
    ]
    (Crontab.parse_listed_jobs ~read_file:(reader_for files)
       (merged_mixed_section ()))

(* A line no reader names cannot be merged by name, and dropping it is what the
   merge did before: the whole crontab is asserted here rather than the line's
   presence, because presence is not placement -- an entry appended at the end
   of the section would satisfy "it survived" and still have moved. *)
let test_unreadable_line_keeps_its_place_in_the_section () =
  check (list string) "the whole crontab the merge writes"
    [
      "# some other cron";
      "# BEGIN BONDI CRON";
      Crontab.entry_of_cron_job redeployed_backup;
      Crontab.entry_of_cron_job reports_job;
      unresolvable_line;
      cleanup_legacy_line;
      Crontab.entry_of_cron_job added_metrics;
      "# END BONDI CRON";
    ]
    (merged_mixed_section ())

let test_merge_of_no_lines_at_all () =
  check (list string) "no jobs and no crontab is no crontab" []
    (Crontab.merge_bondi_section None [])

(* The lines outside the section keep their content but not their place: they
   are hoisted above the section, trimmed, which is the carve-out the section
   itself does not get. *)
let test_merge_keeps_the_lines_outside_the_section () =
  check (list string) "outside lines kept, section rewritten"
    [
      "# some other cron";
      "# another line";
      "# BEGIN BONDI CRON";
      Crontab.entry_of_cron_job redeployed_backup;
      "# END BONDI CRON";
    ]
    (Crontab.merge_bondi_section (Some [ redeployed_backup ])
       [
         "  # some other cron  ";
         "# BEGIN BONDI CRON";
         backup_legacy_line;
         "# END BONDI CRON";
         "# another line";
       ])

let test_merge_without_markers_touches_no_line () =
  let lines = [ "0 * * * * echo hello"; "30 * * * * echo world" ] in
  check (list string) "a crontab Bondi does not own is left as it is" lines
    (Crontab.merge_bondi_section None lines)

let () =
  run "Crontab"
    [
      ( "job_name_from_cron_line",
        [
          test_case "valid cron line" `Quick test_job_name_from_cron_line_valid;
          test_case "malformed line" `Quick
            test_job_name_from_cron_line_malformed;
          test_case "no json" `Quick test_job_name_from_cron_line_no_json;
        ] );
      ( "merge_bondi_section",
        [
          test_case "no jobs and no lines" `Quick test_merge_of_no_lines_at_all;
          test_case "keeps the lines outside the section" `Quick
            test_merge_keeps_the_lines_outside_the_section;
          test_case "a crontab without markers is untouched" `Quick
            test_merge_without_markers_touches_no_line;
          test_case
            "a legacy line for an unnamed job is preserved byte for byte" `Quick
            test_legacy_line_for_an_unnamed_job_is_preserved_byte_for_byte;
          test_case
            "a legacy line for a redeployed job is replaced by the new shape"
            `Quick
            test_legacy_line_for_a_redeployed_job_is_replaced_by_the_new_shape;
          test_case "a name the section holds twice is written once" `Quick
            test_a_name_the_section_holds_twice_is_written_once;
          test_case "a mixed section round-trips through generate and parse"
            `Quick test_mixed_section_round_trips_through_generate_and_parse;
          test_case "an unreadable line keeps its place in the section" `Quick
            test_unreadable_line_keeps_its_place_in_the_section;
        ] );
      ( "entry_of_cron_job",
        [
          test_case "generated line carries no payload" `Quick
            test_generated_line_carries_no_payload;
          test_case "the payload the line omits is in the run file" `Quick
            test_run_payload_carries_what_the_line_omits;
          test_case "absent network stays absent in the run payload" `Quick
            test_run_payload_omits_absent_network;
          test_case "line names the job's run file path" `Quick
            test_line_names_the_jobs_run_file;
          test_case "a job named api does not match api2's path" `Quick
            test_line_path_is_delimiter_bounded;
        ] );
      ( "legacy lines",
        [
          test_case "preserves network" `Quick
            test_legacy_line_preserves_network;
          test_case "absent network round trips" `Quick
            test_legacy_line_absent_network_round_trips;
          test_case "preserves alert config" `Quick
            test_legacy_line_alert_config_round_trip;
          test_case "hardened flags do not shift the anchor" `Quick
            test_legacy_hardened_flags_do_not_shift_the_anchor;
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
          test_case "parse scheduled jobs" `Quick test_parse_listed_jobs;
          test_case "parse scheduled jobs empty" `Quick
            test_parse_listed_jobs_empty;
          test_case "parse reads hardened line" `Quick
            test_crontab_parse_reads_hardened_line;
        ] );
      ( "parse_listed_jobs",
        [
          test_case "exec line resolves through its run file" `Quick
            test_exec_line_resolves_through_its_run_file;
          test_case "legacy line still resolves through the scanner" `Quick
            test_legacy_line_still_resolves_through_the_scanner;
          test_case "an unparseable line is unreadable, not omitted" `Quick
            test_unparseable_line_is_unreadable_not_omitted;
          test_case "a missing run file is unreadable, not omitted" `Quick
            test_missing_run_file_is_unreadable_not_omitted;
          test_case "a run file whose job disagrees with its path is unreadable"
            `Quick test_job_disagreeing_with_path_is_unreadable;
          test_case "an unreadable entry reports a position and no line text"
            `Quick test_unreadable_entry_reports_a_position_not_a_line;
        ] );
    ]
