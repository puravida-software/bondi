open Alcotest
open Bondi_client

let contains ~needle haystack =
  Bondi_common.String_utils.contains ~needle haystack

(* A host writes on however many lines it likes: a sudo warning of its own ahead
   of the reading is the ordinary case, and the tail of a two-line answer
   interpolated raw lands in the middle of whatever sentence a caller built
   around it. Flattened here, at the boundary, so that no caller has to remember
   to. *)
let test_a_multi_line_answer_arrives_on_one_line () =
  let carried =
    Host_answer.to_string
      (Host_answer.of_host_output "sudo: unable to resolve host box\n0644\n")
  in
  check bool "leaves no newline in the answer" false
    (String.contains carried '\n');
  check string "keeps every word the host said, on one line"
    "sudo: unable to resolve host box 0644" carried

(* The bound is log hygiene and not redaction. What the host said is the only
   thing in a report line that says what the box reported, so an over-long answer
   is cut and counted rather than dropped or replaced. Its reading comes first in
   the fixture, so what survives the cut is checkable rather than a run of
   filler. *)
let test_an_over_long_answer_is_cut_and_counted () =
  let long = "0644 " ^ String.make 900 'x' in
  let carried = Host_answer.to_string (Host_answer.of_host_output long) in
  check bool "still carries what the host reported" true
    (contains ~needle:"0644 xxxxxxxxxx" carried);
  check bool "says the answer was cut" true
    (contains ~needle:"truncated" carried);
  check bool "says how much there was" true
    (contains ~needle:(Printf.sprintf "%d bytes" (String.length long)) carried);
  check bool "does not carry all of it" false (contains ~needle:long carried);
  check bool "is shorter than what the host sent" true
    (String.length carried < String.length long)

(* The affirmative arm the bound needs: an answer that fits is carried whole and
   unannotated. Without it the cut above passes against a constructor that
   truncates everything, or one that annotates every answer it is given. *)
let test_a_short_answer_is_carried_whole () =
  let carried = Host_answer.to_string (Host_answer.of_host_output "0644\n") in
  check string "carries the host's own word for it" "0644" carried;
  check bool "says nothing about a cut that did not happen" false
    (contains ~needle:"truncated" carried)

let () =
  run "host answer"
    [
      ( "carrying what a host said",
        [
          test_case "a multi-line answer arrives on one line" `Quick
            test_a_multi_line_answer_arrives_on_one_line;
          test_case "an over-long answer is cut and counted" `Quick
            test_an_over_long_answer_is_cut_and_counted;
          test_case "a short answer is carried whole" `Quick
            test_a_short_answer_is_carried_whole;
        ] );
    ]
