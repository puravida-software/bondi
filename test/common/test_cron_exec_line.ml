open Alcotest
module Cron_exec_line = Bondi_common.Cron_exec_line

(* The line as its generator assembles it: the marker and the path come from
   this module, so a case here reads the shape the orchestrator writes rather
   than a hand-written copy of it that could outlive the real one. *)
let line_for ~schedule ~path =
  Printf.sprintf "%s docker exec bondi-orchestrator sh -c '%s%s'" schedule
    Cron_exec_line.exec_marker path

let test_run_file_sits_in_the_job_s_own_directory () =
  check string "one directory per job, under the cron root"
    "/etc/bondi/cron/daily-close/run.json"
    (Cron_exec_line.run_file_of "daily-close")

let test_a_generated_line_names_its_job () =
  check (option string) "the name is the directory the run file sits in"
    (Some "daily-close")
    (Cron_exec_line.job_name_of
       (line_for ~schedule:"5 21 * * 1-5"
          ~path:(Cron_exec_line.run_file_of "daily-close")))

(* The path is rebuilt from the name taken out of it and the line is named only
   when the two are the same string, so a hand-edited line pointing outside the
   cron root reports nothing rather than a job called "passwd". *)
let test_a_traversing_path_names_nothing () =
  check (option string) "a path no writer could have written names no job" None
    (Cron_exec_line.job_name_of
       (line_for ~schedule:"0 3 * * *"
          ~path:"/etc/bondi/cron/../../passwd/run.json"))

let test_a_line_of_another_shape_names_nothing () =
  check (option string) "a line without the marker is not this shape" None
    (Cron_exec_line.job_name_of
       "0 6 * * * /usr/bin/curl -sS -d '{\"job\":\"x\"}'")

(* The one spelling of the container name. Pinned as a literal rather than read
   back off the module under test, which would agree with any value at all: what
   the hosts actually run is a container called bondi-orchestrator, and a typo
   here is a setup run that cannot find the container it just started. *)
let test_the_orchestrator_container_has_one_name () =
  check string "the name every command on a host uses" "bondi-orchestrator"
    Cron_exec_line.orchestrator_container

let () =
  run "Cron_exec_line"
    [
      ( "orchestrator_container",
        [
          test_case "the orchestrator container has one name" `Quick
            test_the_orchestrator_container_has_one_name;
        ] );
      ( "run_file_of",
        [
          test_case "path under the cron root" `Quick
            test_run_file_sits_in_the_job_s_own_directory;
        ] );
      ( "job_name_of",
        [
          test_case "a generated line names its job" `Quick
            test_a_generated_line_names_its_job;
          test_case "a traversing path names nothing" `Quick
            test_a_traversing_path_names_nothing;
          test_case "another shape names nothing" `Quick
            test_a_line_of_another_shape_names_nothing;
        ] );
    ]
