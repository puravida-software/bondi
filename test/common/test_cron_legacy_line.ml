open Alcotest
module Cron_legacy_line = Bondi_common.Cron_legacy_line

(* A legacy line: the [curl -d '<json>'] shape Bondi wrote before the payload
   moved to a file. Nothing generates this any more, so the line is assembled
   from a literal rather than from a generator -- a generated line would pin the
   shape written now, not the shape this reader has to keep reading. The flags
   are the hardened ones, because they sit ahead of the payload on every line in
   the estate and the scanner anchors on the first "-d '". *)
let legacy_line escaped_payload =
  "0 * * * * /usr/bin/curl -sS --fail-with-body -X POST \
   http://localhost:3030/api/v1/run -H \"Content-Type: application/json\" -d '"
  ^ escaped_payload ^ "'"

(* The writer that produced these lines escaped every single quote in the JSON
   as '\'' before it interpolated the payload into the line. A payload holding
   one is therefore the case that tells a reader that undoes the escaping from
   one that only strips the outer quotes: the second hands back four bytes where
   the job's own text had one, and what it hands back is not JSON. *)
let payload_with_a_quote =
  {|{"job":"backup","image":"img:v1","env_vars":{"GREETING":"it's here"}}|}

let escaped_payload_with_a_quote =
  {|{"job":"backup","image":"img:v1","env_vars":{"GREETING":"it'\''s here"}}|}

let test_a_legacy_line_yields_its_payload_text () =
  check (option string) "the payload is the bytes the job carried, unescaped"
    (Some payload_with_a_quote)
    (Cron_legacy_line.payload_of (legacy_line escaped_payload_with_a_quote))

let test_a_legacy_line_yields_its_job_name () =
  check (option string) "the job field of the recovered payload" (Some "backup")
    (Cron_legacy_line.job_name_of (legacy_line escaped_payload_with_a_quote))

let test_a_legacy_line_yields_its_image () =
  check (option string) "the image field of the recovered payload"
    (Some "img:v1")
    (Cron_legacy_line.image_of (legacy_line escaped_payload_with_a_quote))

(* The shape the orchestrator writes now carries no [-d '] argument at all, so
   this reader must decline it rather than find a payload somewhere in the
   command. The affirmative arm is the legacy line built by the same helper: a
   None that holds because nothing reaches the scanner would pass this case
   whatever the scanner did. *)
let test_an_exec_line_yields_no_payload () =
  let exec_line =
    "0 * * * * docker exec bondi-orchestrator sh -c '"
    ^ Bondi_common.Cron_exec_line.exec_marker
    ^ Bondi_common.Cron_exec_line.run_file_of "backup"
    ^ "'"
  in
  check (option string) "a line of the current shape carries no payload" None
    (Cron_legacy_line.payload_of exec_line);
  check bool "and the legacy shape still does" true
    (Option.is_some
       (Cron_legacy_line.payload_of (legacy_line escaped_payload_with_a_quote)))

(* A line whose closing quote is missing -- a truncated spool file, a hand edit
   -- has no payload rather than a payload running to the end of the line. Both
   arms are the same fixture, with and without its final quote. *)
let test_a_line_whose_quoting_does_not_close_yields_no_payload () =
  let closed = legacy_line escaped_payload_with_a_quote in
  let unclosed = String.sub closed 0 (String.length closed - 1) in
  check (option string) "an unterminated argument is not a payload" None
    (Cron_legacy_line.payload_of unclosed);
  check (option string) "the same line with its quote is"
    (Some payload_with_a_quote)
    (Cron_legacy_line.payload_of closed)

let () =
  run "Cron_legacy_line"
    [
      ( "payload_of",
        [
          test_case "a legacy line yields its payload text" `Quick
            test_a_legacy_line_yields_its_payload_text;
          test_case "an exec line yields no payload" `Quick
            test_an_exec_line_yields_no_payload;
          test_case "quoting that does not close yields no payload" `Quick
            test_a_line_whose_quoting_does_not_close_yields_no_payload;
        ] );
      ( "job_name_of",
        [
          test_case "a legacy line yields its job name" `Quick
            test_a_legacy_line_yields_its_job_name;
        ] );
      ( "image_of",
        [
          test_case "a legacy line yields its image" `Quick
            test_a_legacy_line_yields_its_image;
        ] );
    ]
