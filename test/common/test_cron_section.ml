open Alcotest
module Cron_section = Bondi_common.Cron_section

(* The markers come from the module under test rather than from string literals
   here. Spelled out by hand they would be a fixture that goes on passing after
   the writer's markers change, while every section on every box reads as
   absent. *)
let begin_marker = Cron_section.begin_marker
let end_marker = Cron_section.end_marker
let hand_added = "*/5 * * * * /usr/local/bin/operator-cleanup"
let bondi_entry = "5 21 * * 1-5 docker exec bondi-orchestrator sh -c 'run'"

let second_bondi_entry =
  "0 3 * * * docker exec bondi-orchestrator sh -c 'run-nightly'"

let trailing = "0 4 * * 0 /usr/local/bin/rotate-logs"

let malformation_testable =
  of_pp (fun formatter malformation ->
      match malformation with
      | Cron_section.End_without_begin ->
          Format.fprintf formatter "End_without_begin"
      | Cron_section.Begin_without_end ->
          Format.fprintf formatter "Begin_without_end"
      | Cron_section.Nested_begin -> Format.fprintf formatter "Nested_begin")

let split_testable =
  of_pp (fun formatter (split : Cron_section.split) ->
      let lines label values =
        Format.fprintf formatter "%s=[%s] " label (String.concat "; " values)
      in
      lines "before" split.before;
      (match split.section with
      | None -> Format.fprintf formatter "section=none "
      | Some section -> lines "section" section);
      lines "after" split.after)

let split_result = result split_testable malformation_testable

(* The absence arm and its affirmative twin are asserted together, on fixtures
   that differ only in the two marker lines. A crontab that never carried a
   section and one whose section carries nothing are two different facts about a
   host, and an implementation that reported either as the other would pass
   whichever of these was written alone. *)
let test_a_crontab_with_no_markers_has_no_section () =
  check split_result "a file that was never written has no section"
    (Ok { Cron_section.before = [ hand_added ]; section = None; after = [] })
    (Cron_section.split_lines [ hand_added ]);
  check split_result "a section present and holding nothing is still a section"
    (Ok { Cron_section.before = [ hand_added ]; section = Some []; after = [] })
    (Cron_section.split_lines [ hand_added; begin_marker; end_marker ])

let test_lines_before_and_after_the_markers_are_kept_apart_from_it () =
  check split_result "only what lies between the markers is the section"
    (Ok
       {
         Cron_section.before = [ hand_added ];
         section = Some [ bondi_entry ];
         after = [ trailing; "" ];
       })
    (Cron_section.split_lines
       [ hand_added; begin_marker; bondi_entry; end_marker; trailing; "" ])

(* Both arms matter: a join that always emitted the markers would rebuild the
   bracketed file and fabricate a section in the file that never had one. *)
let test_join_rebuilds_the_crontab_it_split () =
  let round_trip label lines =
    match Cron_section.split_lines lines with
    | Ok split -> check (list string) label lines (Cron_section.join split)
    | Error _ -> failf "%s: this fixture's markers balance" label
  in
  round_trip "a bracketed crontab comes back byte for byte"
    [ hand_added; begin_marker; bondi_entry; end_marker; trailing; "" ];
  round_trip "a crontab with no markers gains none" [ hand_added; trailing; "" ]

(* A crontab already holding two balanced sections. This is not hypothetical
   and it is not a malformation: a reader that matched markers untrimmed
   answered a marker carrying a carriage return as no section, and the next
   write appended a second section below the first. Both balance, so the cut
   must surface both -- a second section kept verbatim among the lines after
   the first is read by nothing, and the writer that rebuilds the file leaves
   it standing and its job firing. *)
let doubled = [ hand_added; begin_marker; bondi_entry; end_marker; trailing ]

let test_a_second_balanced_section_is_part_of_the_section () =
  check split_result "every section's lines are the section"
    (Ok
       {
         Cron_section.before = [ hand_added ];
         section = Some [ bondi_entry; second_bondi_entry ];
         after = [ trailing ];
       })
    (Cron_section.split_lines
       (doubled @ [ begin_marker; second_bondi_entry; end_marker ]));
  (* The healing arm: what comes back out is one section, so a box in this
     state converges on its next write rather than keeping two forever. *)
  check split_result "and the same file with only the first section"
    (Ok
       {
         Cron_section.before = [ hand_added ];
         section = Some [ bondi_entry ];
         after = [ trailing ];
       })
    (Cron_section.split_lines doubled)

let test_join_writes_one_section_for_the_two_it_read () =
  match
    Cron_section.split_lines
      (doubled @ [ begin_marker; second_bondi_entry; end_marker ])
  with
  | Error _ -> fail "this fixture's markers balance"
  | Ok split ->
      check (list string) "the two sections come back as one"
        [
          hand_added;
          begin_marker;
          bondi_entry;
          second_bondi_entry;
          end_marker;
          trailing;
        ]
        (Cron_section.join split)

(* Both libraries drop a blank line inside the section: the reader gives it no
   position and the writer does not write it back. One of them changing its
   mind alone is how the position a report names stops being the position the
   next rewrite addresses. *)
let test_a_blank_line_inside_the_section_is_not_an_entry () =
  check bool "an empty line is not an entry" false
    (Cron_section.is_entry_line "");
  check bool "a line of nothing but whitespace is not an entry" false
    (Cron_section.is_entry_line " \t ");
  check bool "a job's line is an entry" true
    (Cron_section.is_entry_line bondi_entry)

let test_a_section_that_closes_without_opening_is_malformed () =
  check split_result "a close with nothing open names that defect"
    (Error Cron_section.End_without_begin)
    (Cron_section.split_lines [ hand_added; end_marker; "" ])

let test_a_section_that_opens_and_never_closes_is_malformed () =
  check split_result "a file ending inside the section names that defect"
    (Error Cron_section.Begin_without_end)
    (Cron_section.split_lines [ begin_marker; bondi_entry; "" ])

let test_a_second_begin_inside_an_open_section_is_malformed () =
  check split_result "an open inside one already open names that defect"
    (Error Cron_section.Nested_begin)
    (Cron_section.split_lines
       [ begin_marker; bondi_entry; begin_marker; trailing; end_marker ])

let () =
  run "Cron_section"
    [
      ( "split_lines",
        [
          test_case "a crontab with no markers has no section" `Quick
            test_a_crontab_with_no_markers_has_no_section;
          test_case "lines before and after the markers are kept apart from it"
            `Quick
            test_lines_before_and_after_the_markers_are_kept_apart_from_it;
          test_case "a section that closes without opening is malformed" `Quick
            test_a_section_that_closes_without_opening_is_malformed;
          test_case "a section that opens and never closes is malformed" `Quick
            test_a_section_that_opens_and_never_closes_is_malformed;
          test_case "a second begin inside an open section is malformed" `Quick
            test_a_second_begin_inside_an_open_section_is_malformed;
          test_case "a second balanced section is part of the section" `Quick
            test_a_second_balanced_section_is_part_of_the_section;
        ] );
      ( "is_entry_line",
        [
          test_case "a blank line inside the section is not an entry" `Quick
            test_a_blank_line_inside_the_section_is_not_an_entry;
        ] );
      ( "join",
        [
          test_case "join rebuilds the crontab it split" `Quick
            test_join_rebuilds_the_crontab_it_split;
          test_case "join writes one section for the two it read" `Quick
            test_join_writes_one_section_for_the_two_it_read;
        ] );
    ]
