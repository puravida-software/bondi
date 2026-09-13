open Alcotest
module Cron_divergence = Bondi_common.Cron_divergence

let divergence =
  of_pp (fun formatter divergence ->
      match divergence with
      | Cron_divergence.Line_without_files { job } ->
          Format.fprintf formatter "Line_without_files %s" job
      | Cron_divergence.Files_without_a_line { job } ->
          Format.fprintf formatter "Files_without_a_line %s" job)

let divergences = list divergence

(* The paths are fixture values and not the box's own, because what is asserted
   is that the remedy names whatever file and directory it was handed. Literals
   taken from the writer would pass against a remedy that names constants of its
   own. *)
let crontab_path = "/var/spool/cron/crontabs/root"
let payload_dir = "/fixture/cron/payloads"

(* The first direction. The section fires a job and the payload directory holds
   nothing under that name, so the line runs a job whose files are gone. This is
   the direction with no remedy, and the one an operator has to be told about
   because nothing else on the box will ever say it. *)
let test_a_line_whose_files_are_gone () =
  let found =
    Cron_divergence.divergences
      ~crontab_jobs:(Some [ "rotate"; "backup" ])
      ~payload_jobs:(Some [])
  in
  check divergences
    "every line is reported, in the order the section names them"
    [
      Cron_divergence.Line_without_files { job = "rotate" };
      Cron_divergence.Line_without_files { job = "backup" };
    ]
    found

(* The second direction. The directory holds a job's payload and no line fires
   it, so the job never runs. A narrow fix that only walks the section's names
   reports nothing here, which is why it is its own case. *)
let test_files_with_no_line_firing_them () =
  let found =
    Cron_divergence.divergences ~crontab_jobs:(Some [])
      ~payload_jobs:(Some [ "rotate"; "backup"; "archive" ])
  in
  check divergences "every orphaned payload is reported, in name order"
    [
      Cron_divergence.Files_without_a_line { job = "archive" };
      Cron_divergence.Files_without_a_line { job = "backup" };
      Cron_divergence.Files_without_a_line { job = "rotate" };
    ]
    found

(* The ordinary box. Both sources name the job, so there is nothing to say. The
   emptiness is only meaningful if this fixture reaches the comparison at all,
   so the same names are run again with one job's files gone and another's
   arrived: that arm is what proves the silence above is agreement rather than
   a fixture that compares nothing, and it pins which direction is reported
   first, which a caller printing the list unchanged depends on. *)
let test_a_job_under_a_line_that_names_it_is_silent () =
  let agreeing =
    Cron_divergence.divergences
      ~crontab_jobs:(Some [ "backup"; "rotate" ])
      ~payload_jobs:(Some [ "rotate"; "backup" ])
  in
  check divergences "two sources naming the same jobs say nothing" [] agreeing;
  let one_dropped_and_one_added =
    Cron_divergence.divergences
      ~crontab_jobs:(Some [ "backup"; "rotate" ])
      ~payload_jobs:(Some [ "rotate"; "archive" ])
  in
  check divergences
    "and the same fixture is loud, lines before files, when one job's files go \
     and another's arrive"
    [
      Cron_divergence.Line_without_files { job = "backup" };
      Cron_divergence.Files_without_a_line { job = "archive" };
    ]
    one_dropped_and_one_added

(* A source nobody read is not a source that disagreed. Claiming a divergence
   off a read that failed would report every job on the box as diverging on the
   strength of an answer never received. Both unread directions are silent, and
   the same names read from both sources are loud in both directions -- which is
   what proves the silence comes from the unread source and not from names that
   would have agreed anyway. *)
let test_an_unread_source_yields_nothing () =
  check divergences "a crontab nobody read yields nothing" []
    (Cron_divergence.divergences ~crontab_jobs:None
       ~payload_jobs:(Some [ "backup" ]));
  check divergences "a payload directory nobody listed yields nothing" []
    (Cron_divergence.divergences ~crontab_jobs:(Some [ "backup" ])
       ~payload_jobs:None);
  check divergences "the same names read from both are loud one way"
    [ Cron_divergence.Files_without_a_line { job = "backup" } ]
    (Cron_divergence.divergences ~crontab_jobs:(Some [])
       ~payload_jobs:(Some [ "backup" ]));
  check divergences "and loud the other way"
    [ Cron_divergence.Line_without_files { job = "backup" } ]
    (Cron_divergence.divergences ~crontab_jobs:(Some [ "backup" ])
       ~payload_jobs:(Some []))

(* A fault an operator cannot act on is worse than no fault at all. One
   direction closes by deploying the service, so the remedy says so. The other
   has no command that clears it: nothing converges the section, and the only
   lever that exists removes the whole of it. Its remedy therefore names the
   file to open by hand, and must not name the deploy -- a reader who tries it
   watches the stale line survive and learns the report is wrong. *)
let test_each_direction_names_what_closes_it () =
  let closes_by_deploying =
    Cron_divergence.remedy ~crontab_path ~payload_dir
      (Cron_divergence.Files_without_a_line { job = "backup" })
  in
  check bool "the fixable direction names the job" true
    (Bondi_common.String_utils.contains ~needle:"backup" closes_by_deploying);
  check bool "and names the deploy that writes the line" true
    (Bondi_common.String_utils.contains ~needle:"bondi deploy"
       closes_by_deploying);
  check bool "and names the payload directory it was handed" true
    (Bondi_common.String_utils.contains ~needle:payload_dir closes_by_deploying);
  let cleared_by_hand =
    Cron_divergence.remedy ~crontab_path ~payload_dir
      (Cron_divergence.Line_without_files { job = "backup" })
  in
  check bool "the unfixable direction names the job" true
    (Bondi_common.String_utils.contains ~needle:"backup" cleared_by_hand);
  check bool "and names the file to open" true
    (Bondi_common.String_utils.contains ~needle:crontab_path cleared_by_hand);
  check bool "and names the payload directory it was handed" true
    (Bondi_common.String_utils.contains ~needle:payload_dir cleared_by_hand);
  check bool "and says no command clears it" true
    (Bondi_common.String_utils.contains ~needle:"no command" cleared_by_hand);
  check bool "and names no deploy, which would not clear it" false
    (Bondi_common.String_utils.contains ~needle:"bondi deploy" cleared_by_hand)

let () =
  run "Cron divergence"
    [
      ( "comparing the two sources",
        [
          test_case "a line whose payload files are gone is a divergence" `Quick
            test_a_line_whose_files_are_gone;
          test_case "files with no line firing them are a divergence" `Quick
            test_files_with_no_line_firing_them;
          test_case
            "a job holding both its files under a line that names it is silent"
            `Quick test_a_job_under_a_line_that_names_it_is_silent;
          test_case
            "a source that was never read yields nothing in either direction"
            `Quick test_an_unread_source_yields_nothing;
        ] );
      ( "what closes a divergence",
        [
          test_case
            "each direction names what closes it, and the direction with no \
             command says so"
            `Quick test_each_direction_names_what_closes_it;
        ] );
    ]
