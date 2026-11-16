open Alcotest
module Journal_storage = Bondi_client.Journal_storage

let contains = Test_helpers.contains

(* The commands are spelled out rather than built from the module's own
   constants: through the constants these would pass for whatever path the
   constants named, including one Alloy does not mount. *)
let provisioning_commands =
  [
    "sudo mkdir -p '/var/log/journal'";
    "sudo systemd-tmpfiles --create --prefix '/var/log/journal'";
    "sudo systemctl restart systemd-journald";
  ]

let planned_commands = function
  | Ok Journal_storage.Nothing_to_do -> Ok []
  | Ok (Journal_storage.Provision_then_recheck commands) -> Ok commands
  | Error message -> Error message

let commands_or_error = result (list string) string

let test_present_plans_nothing () =
  check commands_or_error "nothing to run" (Ok [])
    (planned_commands (Journal_storage.plan Journal_storage.Present));
  (* The affirmative arm: the same plan does provision, so the empty list above
     is the present reading's doing and not a plan that never provisions. *)
  check bool "an absent journal does plan commands" true
    (planned_commands (Journal_storage.plan Journal_storage.Absent) <> Ok [])

let test_absent_plans_provision_then_recheck () =
  (match Journal_storage.plan Journal_storage.Absent with
  | Ok (Journal_storage.Provision_then_recheck commands) ->
      check (list string) "provisioning, in order" provisioning_commands
        commands
  | Ok Journal_storage.Nothing_to_do -> fail "an absent journal planned nothing"
  | Error message -> fail message);
  check (result unit string) "a journal present after provisioning is accepted"
    (Ok ())
    (Journal_storage.recheck Journal_storage.Present)

let test_still_absent_after_provision_is_an_error_naming_the_path () =
  match Journal_storage.recheck Journal_storage.Absent with
  | Ok () -> fail "a journal still absent after provisioning was accepted"
  | Error message ->
      check bool "names the path" true
        (contains ~needle:"/var/log/journal" message);
      check bool "names the setting that keeps the journal out of it" true
        (contains ~needle:"Storage=" message)

(* Setup restarts a box's journald only on an answer it got. A probe that did
   not run says nothing about the journal, so it plans nothing and stops the
   run, carrying the reason it was not answered. *)
let test_an_unread_storage_plans_nothing_and_is_an_error () =
  (match
     Journal_storage.plan (Journal_storage.Undetermined "ssh: timed out")
   with
  | Ok _ -> fail "an unread journal was planned against"
  | Error message ->
      check bool "names the path" true
        (contains ~needle:"/var/log/journal" message);
      check bool "carries why it was not read" true
        (contains ~needle:"ssh: timed out" message));
  match
    Journal_storage.recheck (Journal_storage.Undetermined "ssh: timed out")
  with
  | Ok () -> fail "an unread journal was accepted after provisioning"
  | Error message ->
      check bool "carries why it was not read" true
        (contains ~needle:"ssh: timed out" message)

let reading_name = function
  | Journal_storage.Present -> "present"
  | Journal_storage.Absent -> "absent"
  | Journal_storage.Undetermined _ -> "undetermined"

(* An answer is read by the marker it carries and by nothing else. A box that
   said nothing has not said its journal is there, nor that it is missing, and
   reading the second would restart its journald on a question nobody
   answered. The first two cases are the affirmative arms: each marker is read
   as what it says. *)
let test_the_probe_is_read_by_its_markers () =
  let read outcome = reading_name (Journal_storage.reading_of_probe outcome) in
  check string "present marker" "present" (read (Ok "BONDI_JOURNAL_PRESENT\n"));
  check string "absent marker" "absent" (read (Ok "BONDI_JOURNAL_ABSENT\n"));
  check string "an empty answer" "undetermined" (read (Ok ""));
  check string "an answer naming neither" "undetermined"
    (read (Ok "sudo: a terminal is required to read the password\n"));
  check string "no machine id" "undetermined"
    (read (Ok "BONDI_JOURNAL_NO_MACHINE_ID\n"));
  check string "both markers" "undetermined"
    (read (Ok "BONDI_JOURNAL_PRESENT\nBONDI_JOURNAL_ABSENT\n"));
  check string "a call that failed" "undetermined"
    (read (Error "BONDI_JOURNAL_PRESENT"))

let () =
  run "Journal_storage"
    [
      ( "plan",
        [
          test_case "present plans nothing" `Quick test_present_plans_nothing;
          test_case "absent plans provision then recheck" `Quick
            test_absent_plans_provision_then_recheck;
          test_case "still absent after provision is an error naming the path"
            `Quick test_still_absent_after_provision_is_an_error_naming_the_path;
          test_case "an unread storage plans nothing and is an error" `Quick
            test_an_unread_storage_plans_nothing_and_is_an_error;
        ] );
      ( "reading_of_probe",
        [
          test_case "the probe is read by its markers" `Quick
            test_the_probe_is_read_by_its_markers;
        ] );
    ]
