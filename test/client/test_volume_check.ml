open Alcotest
module Volume_check = Bondi_client.Volume_check
module Remote_exec = Bondi_client.Remote_exec
module Bind_mount = Bondi_common.Bind_mount

let contains = Test_helpers.contains

(* --- Fixtures ---

   The box is this machine. Each check below runs the command the module builds
   through a real [sh -c], the way the box's shell receives it over ssh, so what
   is asserted is what the command does with the paths it names and not what a
   hand-written output says it would have done. The verdict is then read from
   that run's outcome.

   [sudo] is shadowed by a shell function for every run: a test has no business
   asking this machine's sudo anything, and what the function answers is the
   fixture. By default it grants [sudo -n] and sees no path the login user does
   not, which is a box where root and the login user agree. [refusing_sudo] is
   a box that will not grant [sudo -n] at all.
*)

let refusing_sudo = "sudo() { return 1; }"
let root_sees_nothing_more = "sudo() { [ \"$*\" = \"-n true\" ]; }"

let run_on_this_machine ?(sudo = root_sees_nothing_more) ~cwd command =
  Client_fixtures.run_on_this_machine ~sudo ~cwd command

let mount host =
  Test_helpers.bind_mount ~host ~container:"/data" ~read_only:false

let with_dir f = Test_helpers.with_temp_dir "bondi-volume-check" f
let make_file path = Out_channel.with_open_bin path (fun _ -> ())

let describe = function
  | Volume_check.All_present -> "All_present"
  | Volume_check.Missing paths ->
      "Missing ["
      ^ String.concat "; " (List.map (Printf.sprintf "%S") paths)
      ^ "]"
  | Volume_check.Unreadable reason -> Printf.sprintf "Unreadable %S" reason

let check_verdict message expected actual =
  check string message (describe expected) (describe actual)

let is_unreadable = function
  | Volume_check.Unreadable _ -> true
  | Volume_check.All_present
  | Volume_check.Missing _ ->
      false

let check_of_mounts ?sudo ~cwd hosts =
  Volume_check.verdict
    (run_on_this_machine ?sudo ~cwd
       (Volume_check.command (List.map mount hosts)))

(* --- Present and missing ---

   One directory, one run per arm, differing only in which of the declared
   paths exist. The arm where every path is there is what shows the missing arm
   is read from the paths and not from a command that reports everything
   missing. *)

let test_verdict_all_present () =
  with_dir @@ fun dir ->
  let data = Filename.concat dir "data" in
  let file = Filename.concat dir "config.toml" in
  Sys.mkdir data 0o755;
  make_file file;
  let verdict = check_of_mounts ~cwd:dir [ data; file ] in
  check_verdict "a directory and a file are both valid host paths"
    Volume_check.All_present verdict;
  check (result unit string) "and nothing is refused" (Ok ())
    (Volume_check.refusal verdict)

let test_verdict_lists_every_missing_path () =
  with_dir @@ fun dir ->
  let data = Filename.concat dir "data" in
  let invoices = Filename.concat dir "invoices" in
  let logs = Filename.concat dir "logs" in
  Sys.mkdir data 0o755;
  let verdict = check_of_mounts ~cwd:dir [ invoices; data; logs ] in
  check_verdict "every missing path, in the declared order, and no present one"
    (Volume_check.Missing [ invoices; logs ])
    verdict;
  match Volume_check.refusal verdict with
  | Ok () -> fail "expected missing paths to refuse the deploy"
  | Error message ->
      check bool
        ("the refusal names the first: " ^ message)
        true
        (contains ~needle:invoices message);
      check bool
        ("the refusal names the second: " ^ message)
        true
        (contains ~needle:logs message);
      check bool
        ("and not the one that is there: " ^ message)
        false
        (contains ~needle:(Printf.sprintf "%S" data) message)

(* The daemon that mounts the path asks as root. A path below a directory the
   login user cannot traverse is there for the daemon, so it is not missing
   here either: the sudo stand-in sees exactly one path this machine does not
   have, and that path is the only one the run does not report. *)
let test_a_path_only_root_can_see_is_present () =
  with_dir @@ fun dir ->
  let hidden = Filename.concat dir "hidden" in
  let absent = Filename.concat dir "absent" in
  let sudo =
    Printf.sprintf "sudo() { [ \"$*\" = \"-n true\" ] || [ \"$*\" = %s ]; }"
      (Filename.quote ("-n test -e " ^ hidden))
  in
  check_verdict "the path root sees is present; the other is still missing"
    (Volume_check.Missing [ absent ])
    (check_of_mounts ~sudo ~cwd:dir [ hidden; absent ])

(* Root was never asked when [sudo -n] is refused, so a path the login user
   cannot see is unchecked, whether or not it exists. *)
let test_refused_sudo_leaves_a_hidden_path_unreadable () =
  with_dir @@ fun dir ->
  check bool "a path that may be hidden is not read as missing" true
    (is_unreadable
       (check_of_mounts ~sudo:refusing_sudo ~cwd:dir
          [ Filename.concat dir "hidden-or-absent" ]))

let test_refused_sudo_leaves_an_absent_path_unreadable () =
  with_dir @@ fun dir ->
  let verdict =
    check_of_mounts ~sudo:refusing_sudo ~cwd:dir
      [ Filename.concat dir "absent" ]
  in
  check bool "unreadable, not missing" true (is_unreadable verdict);
  match verdict with
  | Volume_check.Unreadable reason ->
      check bool "and it says root was not asked" true
        (contains ~needle:"sudo -n refused" reason)
  | Volume_check.All_present
  | Volume_check.Missing _ ->
      fail "expected Unreadable"

(* --- Not a verdict about the paths ---

   A call that failed has not said whether any path is there, even when its
   output carries a missing path's line: the check may have been cut after the
   first test. Each failure below carries the output of a real run that did
   report a missing path, so reading it as [Missing] would be possible and
   wrong. *)

let test_verdict_transport_failure_is_unreadable_not_missing () =
  with_dir @@ fun dir ->
  let absent = Filename.concat dir "absent" in
  let output =
    match
      run_on_this_machine ~cwd:dir (Volume_check.command [ mount absent ])
    with
    | Ok output -> output
    | Error failure -> fail (Remote_exec.message failure)
  in
  let as_answered = Volume_check.verdict (Ok output) in
  check_verdict "the fixture's own output does report the path missing"
    (Volume_check.Missing [ absent ]) as_answered;
  (* The wording a missing path is refused in, read off the same output, so
     its absence below is the failure's wording and not a pattern that never
     matches. The transport's own text may name the path; that is its account
     of what it saw, not a claim that the path is missing. *)
  let missing_wording = "do not exist" in
  (match Volume_check.refusal as_answered with
  | Ok () -> fail "expected missing paths to refuse the deploy"
  | Error message ->
      check bool
        ("a missing path is refused in its own words: " ^ message)
        true
        (contains ~needle:missing_wording message));
  List.iter
    (fun failure ->
      let verdict = Volume_check.verdict (Error failure) in
      check bool
        ("a failed call is unreadable, not missing: " ^ describe verdict)
        true (is_unreadable verdict);
      match Volume_check.refusal verdict with
      | Ok () -> fail "expected a failed check to refuse the deploy"
      | Error message ->
          check bool
            ("it is not worded as a missing path: " ^ message)
            false
            (contains ~needle:missing_wording message))
    [
      Remote_exec.Ssh_failed { code = 255; output };
      Remote_exec.Command_failed { code = 1; output };
      Remote_exec.Timed_out { seconds = 60; output };
    ]

(* The command always exits 0 and ends with its marker. An answer without the
   marker, or with a line before it the command never prints, is not the
   command's answer -- the empty one most of all, which is what a box whose
   shell ran nothing returns, and which is not every path being present. *)
let test_verdict_unexpected_output_is_unreadable () =
  with_dir @@ fun dir ->
  let absent = Filename.concat dir "absent" in
  let answer paths =
    match run_on_this_machine ~cwd:dir (Volume_check.command paths) with
    | Ok output -> output
    | Error failure -> fail (Remote_exec.message failure)
  in
  let completed = answer [ mount dir ] in
  let missing_lines = answer [ mount absent ] in
  check_verdict "the completed answer is a verdict of its own"
    Volume_check.All_present
    (Volume_check.verdict (Ok completed));
  let cut_before_the_marker =
    match String.split_on_char '\n' missing_lines with
    | missing :: _marker :: _ -> missing ^ "\n"
    | [ _ ]
    | [] ->
        fail ("expected a missing line and a marker: " ^ missing_lines)
  in
  List.iter
    (fun (label, output) ->
      let verdict = Volume_check.verdict (Ok output) in
      check bool (label ^ ": " ^ describe verdict) true (is_unreadable verdict))
    [
      ("an empty answer", "");
      ("a line the command never prints", "Last login: today\n" ^ completed);
      ("an answer cut before its marker", cut_before_the_marker);
    ]

(* --- Quoting ---

   Each path is one word to the box's shell whatever it holds. A path carrying
   a quote, a space, a separator and a substitution is tested as that path:
   the present one is found, the missing one is reported exactly as declared,
   and the substitution never runs. *)

let test_command_quotes_every_host_path () =
  with_dir @@ fun dir ->
  let present = Filename.concat dir "it's here; $(touch pwned) `touch pwned`" in
  let absent = Filename.concat dir "gone 'too' $HOME && touch pwned" in
  make_file present;
  check_verdict "the present one is found and the absent one named verbatim"
    (Volume_check.Missing [ absent ])
    (check_of_mounts ~cwd:dir [ present; absent ]);
  check bool "no part of a path ran as a command" false
    (Sys.file_exists (Filename.concat dir "pwned"))

(* --- Whether there is a question ---

   A payload that mounts nothing is not asked about, so the box is not either:
   the checker given here fails the test if it is called. *)

let never_asked _command = fail "a payload that mounts nothing was checked"

let test_refusal_for_asks_nothing_of_a_payload_without_mounts () =
  check (result unit string) "no volumes" (Ok ())
    (Volume_check.refusal_for ~check:never_asked None);
  check (result unit string) "an empty list of volumes" (Ok ())
    (Volume_check.refusal_for ~check:never_asked (Some []))

let test_refusal_for_reads_the_answer_for_a_payload_with_mounts () =
  with_dir (fun dir ->
      let absent = Filename.concat dir "absent" in
      let mounts = Some [ mount absent ] in
      (* mutable: justified because the checker is a callback and the order it
         was called in is the observation *)
      let asked = ref [] in
      let check_on_machine command =
        asked := command :: !asked;
        run_on_this_machine ~cwd:dir command
      in
      (match Volume_check.refusal_for ~check:check_on_machine mounts with
      | Ok () -> fail "expected the missing path to refuse"
      | Error message ->
          check bool
            ("it names the path: " ^ message)
            true
            (contains ~needle:absent message));
      check int "the box was asked once" 1 (List.length !asked);
      check (result unit string) "and a present path passes" (Ok ())
        (Volume_check.refusal_for
           ~check:(run_on_this_machine ~cwd:dir)
           (Some [ mount dir ])))

let () =
  run "Volume_check"
    [
      ( "verdict",
        [
          test_case "verdict_all_present" `Quick test_verdict_all_present;
          test_case "verdict_lists_every_missing_path" `Quick
            test_verdict_lists_every_missing_path;
          test_case "a path only root can see is present" `Quick
            test_a_path_only_root_can_see_is_present;
          test_case "refused sudo leaves a hidden path unreadable" `Quick
            test_refused_sudo_leaves_a_hidden_path_unreadable;
          test_case "refused sudo leaves an absent path unreadable" `Quick
            test_refused_sudo_leaves_an_absent_path_unreadable;
          test_case "verdict_transport_failure_is_unreadable_not_missing" `Quick
            test_verdict_transport_failure_is_unreadable_not_missing;
          test_case "verdict_unexpected_output_is_unreadable" `Quick
            test_verdict_unexpected_output_is_unreadable;
        ] );
      ( "refusal_for",
        [
          test_case "asks nothing of a payload without mounts" `Quick
            test_refusal_for_asks_nothing_of_a_payload_without_mounts;
          test_case "reads the answer for a payload with mounts" `Quick
            test_refusal_for_reads_the_answer_for_a_payload_with_mounts;
        ] );
      ( "command",
        [
          test_case "command_quotes_every_host_path" `Quick
            test_command_quotes_every_host_path;
        ] );
    ]
