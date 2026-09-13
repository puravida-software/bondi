open Alcotest
module Check_marker = Bondi_common.Check_marker

(* The marker is written by one process and read back by another, which finds it
   by matching it against lines of a log stream. A value carrying a newline of
   its own is therefore not one value but two: the writer appends a terminator,
   and a reader matching a fragment that already ends in a newline is matching a
   doubled one that no line carries. Neither end can detect that on its own --
   the writer's write succeeds and the reader simply never matches -- so it is
   asserted here, where the value is defined. *)
let test_the_marker_is_a_single_line () =
  let marker = Check_marker.diagnostic_sink in
  check bool "the marker is not empty" true (String.length marker > 0);
  check bool "the marker carries no newline of its own" false
    (String.contains marker '\n');
  check bool "and so does not end in one" false
    (String.ends_with ~suffix:"\n" marker)

let () =
  run "Check marker"
    [
      ( "diagnostic sink",
        [
          test_case "the marker is a single line with no newline of its own"
            `Quick test_the_marker_is_a_single_line;
        ] );
    ]
