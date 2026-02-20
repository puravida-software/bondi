open Alcotest
module Crontab = Bondi_server__Crontab

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

let mk_cron_job ~name ~image ~schedule : Bondi_server__Strategy__Simple.cron_job
    =
  {
    name;
    image;
    schedule;
    env_vars = None;
    registry_user = None;
    registry_pass = None;
  }

let test_entry_of_cron_job () =
  let job =
    mk_cron_job ~name:"backup" ~image:"myimg:v1" ~schedule:"0 * * * *"
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
      mk_cron_job ~name:"a" ~image:"img:v1" ~schedule:"0 * * * *";
      mk_cron_job ~name:"b" ~image:"img:v2" ~schedule:"30 * * * *";
    ]
  in
  let entries = Crontab.generate_bondi_entries jobs in
  check string "first line is begin marker" "# BEGIN BONDI CRON"
    (List.hd entries);
  check string "last line is end marker" "# END BONDI CRON"
    (List.nth entries (List.length entries - 1));
  check int "3 lines total (marker + 2 jobs + marker)" 4 (List.length entries)

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
        [ test_case "produces valid entry" `Quick test_entry_of_cron_job ] );
      ( "generate_bondi_entries",
        [
          test_case "includes markers and entries" `Quick
            test_generate_bondi_entries;
        ] );
    ]
