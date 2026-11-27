open Alcotest
module Cron_schedule = Bondi_common.Cron_schedule

(* What a refusal is, without its prose: the constructor, and for a field the
   field's name. *)
let kind = function
  | Cron_schedule.Empty -> "Empty"
  | Cron_schedule.Control_character -> "Control_character"
  | Cron_schedule.Field_count n -> Printf.sprintf "Field_count %d" n
  | Cron_schedule.Bad_field { field; reason = _ } ->
      Printf.sprintf "Bad_field %s" field

let check_accepted schedule =
  match Cron_schedule.of_string schedule with
  | Error e ->
      failf "%S was refused: %s" schedule (Cron_schedule.error_to_string e)
  | Ok parsed ->
      check string
        (Printf.sprintf "%S prints back unchanged" schedule)
        schedule
        (Cron_schedule.to_string parsed)

let check_refused (schedule, expected) =
  match Cron_schedule.of_string schedule with
  | Ok _ -> failf "%S was accepted" schedule
  | Error e ->
      check string
        (Printf.sprintf "why %S is refused" schedule)
        expected (kind e)

(* The examples of Debian bookworm's crontab(5) (cron 3.0pl1-162): its example
   line [30 4 1,15 * 5], a step after [*], a step after a range and a list of
   ranges. Both 0 and 7 are Sunday on both daemons' pages. Fields may be
   separated by tabs. The last five were each installed and run on Debian cron
   3.0pl1-162 and Fedora cronie 1.7.2: both read [*/59] as minutes 0 and 59,
   [1-5/10] as minute 1 alone (a step larger than its range), [007] and
   [*/007] as 7 (a leading zero is decimal, not octal), and [1-5/2,7] as 1, 3,
   5 and 7. *)
let test_accepts_documented_forms () =
  List.iter check_accepted
    [
      "30 4 1,15 * 5";
      "*/2 * * * *";
      "1-9/2 * * * *";
      "1-3,7-9 * * * *";
      "0 0 * * 7";
      "0 0 * * 0";
      "*\t*\t*\t*\t*";
      "*/59 * * * *";
      "1-5/10 * * * *";
      "007 * * * *";
      "*/007 * * * *";
      "1-5/2,7 * * * *";
    ]

(* Schedules of the shapes real manifests declare.
   Each must be accepted unchanged. *)
let test_accepts_common_schedules () =
  List.iter check_accepted [ "17 * * * *"; "* * * * *"; "30 3 * * *" ]

(* A schedule carrying a second crontab line after a newline, the shapes that
   are not five fields, and the forms only one of the two daemons reads:
   nicknames, names, a step after a bare number and a [~] range. *)
let test_refuses_probe_and_shapes () =
  List.iter check_refused
    [
      ("", "Empty");
      ("* * * *", "Field_count 4");
      ("* * * * * *", "Field_count 6");
      ("not a schedule\n* * * * * root reboot", "Control_character");
      ("@reboot", "Field_count 1");
      ("@hourly", "Field_count 1");
      ("* * * jan *", "Bad_field month");
      ("* * * * mon", "Bad_field day of week");
      ("0/35 * * * *", "Bad_field minute");
      ("6~15 * * * *", "Bad_field minute");
      ("1,,2 * * * *", "Bad_field minute");
      ("-1 * * * *", "Bad_field minute");
      (" * * * * *", "Bad_field minute");
      ("* * * * * ", "Bad_field day of week");
    ]

(* The refusal branches of a field's items: a second [/], a second [-], and a
   number too long for an int, which both daemons also refuse to install. Debian
   cron installs [*/2/3] and [1-2-3] and reads them as [*/2] and [1-2]; cronie
   refuses both, so Bondi does. *)
let test_refuses_malformed_items () =
  List.iter check_refused
    [
      ("*/2/3 * * * *", "Bad_field minute");
      ("1-2-3 * * * *", "Bad_field minute");
      ("1-2-3/4 * * * *", "Bad_field minute");
      ("1/2/3 * * * *", "Bad_field minute");
      ("99999999999999999999 * * * *", "Bad_field minute");
    ]

(* One case per bound: minute 0-59, hour 0-23, day of month 1-31, month 1-12,
   day of week 0-7; a descending range; a step of 0; a step above the field's
   maximum. *)
let test_refuses_out_of_range () =
  List.iter check_refused
    [
      ("60 * * * *", "Bad_field minute");
      ("* 24 * * *", "Bad_field hour");
      ("* * 0 * *", "Bad_field day of month");
      ("* * 32 * *", "Bad_field day of month");
      ("* * * 0 *", "Bad_field month");
      ("* * * 13 *", "Bad_field month");
      ("* * * * 8", "Bad_field day of week");
      ("5-1 * * * *", "Bad_field minute");
      ("*/0 * * * *", "Bad_field minute");
      ("*/60 * * * *", "Bad_field minute");
      ("* * * * 1-5/8", "Bad_field day of week");
    ]

(* A bad hour is refused as the hour, and the sentence the operator reads names
   that field. *)
let test_error_names_field () =
  match Cron_schedule.of_string "0 25 * * *" with
  | Ok _ -> fail "an hour of 25 was accepted"
  | Error (Bad_field { field; reason = _ } as e) ->
      check string "the field" "hour" field;
      let message = Cron_schedule.error_to_string e in
      check bool
        (Printf.sprintf "the message names the hour (got %S)" message)
        true
        (Bondi_common.String_utils.contains ~needle:"hour" message)
  | Error ((Empty | Control_character | Field_count _) as e) ->
      failf "refused as %s, not as the hour" (kind e)

(* A generator over the grammar: each field is a list of one to four items, an
   item is [*], a number, or an ascending range, and [*] or a range may carry a
   step from 1 to the field's maximum. Every number is inside its field's
   range. Fields are joined by runs of one to three spaces or tabs. *)
module Gen = QCheck2.Gen

let fields = [ (0, 59); (0, 23); (1, 31); (1, 12); (0, 7) ]

let item (low, high) =
  let open Gen in
  let number = int_range low high in
  let step =
    oneof [ return ""; map (fun s -> "/" ^ string_of_int s) (int_range 1 high) ]
  in
  oneof
    [
      map (fun s -> "*" ^ s) step;
      map string_of_int number;
      (let* a = number in
       let* b = int_range a high in
       let+ s = step in
       Printf.sprintf "%d-%d%s" a b s);
    ]

let field bounds =
  Gen.map (String.concat ",") (Gen.list_size (Gen.int_range 1 4) (item bounds))

let separator =
  Gen.string_size ~gen:(Gen.oneof_list [ ' '; '\t' ]) (Gen.int_range 1 3)

let schedule =
  let open Gen in
  let* parts = flatten_list (List.map field fields) in
  let+ separators = list_size (return (List.length parts - 1)) separator in
  let rec interleave parts separators =
    match (parts, separators) with
    | part :: parts, sep :: separators ->
        part ^ sep ^ interleave parts separators
    | [ part ], [] -> part
    | [], _
    | _ :: _, [] ->
        Alcotest.failf
          "generator: unreachable, there is one separator fewer than fields"
  in
  interleave parts separators

(* [to_string] returns the text the parser accepted, so this property cannot
   catch a parser that reads a field wrongly; the known answers above guard
   that. What it proves is that the whole grammar is accepted and printed back
   byte for byte, which is what keeps a crontab line unchanged. A refusal is
   the parser rejecting a schedule the grammar admits: a contract violation, so
   [false]. *)
let prop_printer_returns_input =
  QCheck_alcotest.to_alcotest ~speed_level:`Quick
    (QCheck2.Test.make ~count:2000 ~name:"a generated schedule prints back"
       ~print:Fun.id schedule (fun text ->
         match Cron_schedule.of_string text with
         | Ok parsed -> String.equal (Cron_schedule.to_string parsed) text
         | Error _ -> false))

(* Every control byte except tab, which is a field separator: a tab placed
   beside a separator leaves a valid schedule. *)
let control_character =
  Gen.oneof
    [
      Gen.map Char.chr (Gen.int_range 0x00 0x08);
      Gen.map Char.chr (Gen.int_range 0x0A 0x1F);
      Gen.return '\x7F';
    ]

let with_control_character =
  let open Gen in
  let* text = schedule in
  let* at = int_range 0 (String.length text) in
  let+ c = control_character in
  String.sub text 0 at
  ^ String.make 1 c
  ^ String.sub text at (String.length text - at)

let test_of_yojson () =
  (match Cron_schedule.of_yojson (`String "30 4 * * 5") with
  | Ok schedule ->
      check string "a string in the grammar is read as written" "30 4 * * 5"
        (Cron_schedule.to_string schedule)
  | Error _ -> fail "expected a schedule");
  (match Cron_schedule.of_yojson (`String "* * *") with
  | Error (`Invalid (Field_count 3)) -> ()
  | _ -> fail "expected the string refusal to carry the parse error");
  List.iter
    (fun json ->
      match Cron_schedule.of_yojson json with
      | Error `Not_a_string -> ()
      | _ -> fail "expected Not_a_string")
    [ `Int 5; `Null; `Bool true; `List [ `String "* * * * *" ]; `Assoc [] ];
  check string "a non-string is refused with the grammar and not the value"
    ("the schedule is not a string: " ^ Cron_schedule.grammar)
    (Cron_schedule.json_error_to_string `Not_a_string)

let prop_control_character_refused =
  QCheck_alcotest.to_alcotest ~speed_level:`Quick
    (QCheck2.Test.make ~count:2000
       ~name:"a schedule holding a control character is refused"
       ~print:String.escaped with_control_character (fun text ->
         match Cron_schedule.of_string text with
         | Ok _ -> false
         | Error Control_character -> true
         | Error (Empty | Field_count _ | Bad_field _) -> false))

let () =
  run "Cron_schedule"
    [
      ( "Cron_schedule",
        [
          test_case "accepts documented forms" `Quick
            test_accepts_documented_forms;
          test_case "accepts common schedules" `Quick
            test_accepts_common_schedules;
          test_case "refuses probe and shapes" `Quick
            test_refuses_probe_and_shapes;
          test_case "refuses malformed items" `Quick
            test_refuses_malformed_items;
          test_case "refuses out of range" `Quick test_refuses_out_of_range;
          test_case "error names field" `Quick test_error_names_field;
          test_case "reads a JSON schedule" `Quick test_of_yojson;
          prop_printer_returns_input;
          prop_control_character_refused;
        ] );
    ]
