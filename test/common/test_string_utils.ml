open Alcotest
module S = Bondi_common.String_utils

let test_contains_empty_needle () =
  check bool "empty needle matches anything" true
    (S.contains ~needle:"" "hello")

let test_contains_match_at_start () =
  check bool "match at start" true (S.contains ~needle:"hel" "hello")

let test_contains_match_at_middle () =
  check bool "match in middle" true (S.contains ~needle:"ell" "hello")

let test_contains_match_at_end () =
  check bool "match at end" true (S.contains ~needle:"llo" "hello")

let test_contains_no_match () =
  check bool "no match" false (S.contains ~needle:"xyz" "hello")

let test_contains_empty_haystack () =
  check bool "empty haystack" false (S.contains ~needle:"a" "")

let test_contains_exact_match () =
  check bool "exact match" true (S.contains ~needle:"hello" "hello")

let test_starts_with_exact_match () =
  check bool "exact match" true (S.starts_with ~prefix:"hello" "hello")

let test_starts_with_prefix_match () =
  check bool "prefix match" true (S.starts_with ~prefix:"hel" "hello")

let test_starts_with_no_match () =
  check bool "no match" false (S.starts_with ~prefix:"xyz" "hello")

let test_starts_with_empty_prefix () =
  check bool "empty prefix" true (S.starts_with ~prefix:"" "hello")

let test_starts_with_empty_value () =
  check bool "empty value with non-empty prefix" false
    (S.starts_with ~prefix:"a" "")

let test_starts_with_prefix_longer_than_value () =
  check bool "prefix longer than value" false
    (S.starts_with ~prefix:"hello world" "hello")

(* A message that arrives from a host or a transport is free text and may carry
   newlines; a table cell holding one stops being a cell, and the tail reads as a
   row of its own. *)
let test_single_line_flattens_a_multi_line_message () =
  check string "a newline inside a message becomes a space"
    "Eio.Io Net Connection_failure Refused, connecting to tcp:127.0.0.1:9"
    (S.single_line
       "Eio.Io Net Connection_failure Refused,\n  connecting to tcp:127.0.0.1:9")

let test_single_line_leaves_a_single_line_alone () =
  check string "a message already on one line is unchanged"
    "Permission denied (publickey)."
    (S.single_line "Permission denied (publickey).")

let test_single_line_collapses_runs_and_trims () =
  check string "runs of whitespace collapse and the ends are trimmed"
    "connection refused"
    (S.single_line "\n  connection\t\t refused  \r\n")

let test_single_line_of_nothing_is_nothing () =
  check string "a message of only whitespace flattens to nothing" ""
    (S.single_line " \n\t ")

let test_index_of_finds_the_first_occurrence () =
  check (option int) "the first of two occurrences" (Some 2)
    (S.index_of ~needle:"ll" "hellollo")

let test_index_of_at_start () =
  check (option int) "a needle the haystack starts with" (Some 0)
    (S.index_of ~needle:"hel" "hello")

let test_index_of_absent_needle () =
  check (option int) "a needle that is not there" None
    (S.index_of ~needle:"xyz" "hello")

(* A needle longer than the haystack must not read past its end. *)
let test_index_of_needle_longer_than_haystack () =
  check (option int) "a needle longer than the haystack" None
    (S.index_of ~needle:"hello world" "hello")

let test_index_of_empty_needle () =
  check (option int) "an empty needle is at the start" (Some 0)
    (S.index_of ~needle:"" "hello")

let test_last_index_of_char_finds_the_last_occurrence () =
  check (option int) "the last of two occurrences" (Some 3)
    (S.last_index_of_char "a/b/c" '/')

let test_last_index_of_char_absent () =
  check (option int) "a character that is not there" None
    (S.last_index_of_char "abc" '/')

let test_last_index_of_char_in_empty_value () =
  check (option int) "an empty value holds no character" None
    (S.last_index_of_char "" '/')

let () =
  run "String_util"
    [
      ( "contains",
        [
          test_case "empty needle" `Quick test_contains_empty_needle;
          test_case "match at start" `Quick test_contains_match_at_start;
          test_case "match in middle" `Quick test_contains_match_at_middle;
          test_case "match at end" `Quick test_contains_match_at_end;
          test_case "no match" `Quick test_contains_no_match;
          test_case "empty haystack" `Quick test_contains_empty_haystack;
          test_case "exact match" `Quick test_contains_exact_match;
        ] );
      ( "starts_with",
        [
          test_case "exact match" `Quick test_starts_with_exact_match;
          test_case "prefix match" `Quick test_starts_with_prefix_match;
          test_case "no match" `Quick test_starts_with_no_match;
          test_case "empty prefix" `Quick test_starts_with_empty_prefix;
          test_case "empty value" `Quick test_starts_with_empty_value;
          test_case "prefix longer than value" `Quick
            test_starts_with_prefix_longer_than_value;
        ] );
      ( "single_line",
        [
          test_case "a multi-line message" `Quick
            test_single_line_flattens_a_multi_line_message;
          test_case "a message already on one line" `Quick
            test_single_line_leaves_a_single_line_alone;
          test_case "runs of whitespace" `Quick
            test_single_line_collapses_runs_and_trims;
          test_case "nothing but whitespace" `Quick
            test_single_line_of_nothing_is_nothing;
        ] );
      ( "index_of",
        [
          test_case "the first occurrence" `Quick
            test_index_of_finds_the_first_occurrence;
          test_case "at the start" `Quick test_index_of_at_start;
          test_case "an absent needle" `Quick test_index_of_absent_needle;
          test_case "a needle longer than the haystack" `Quick
            test_index_of_needle_longer_than_haystack;
          test_case "an empty needle" `Quick test_index_of_empty_needle;
        ] );
      ( "last_index_of_char",
        [
          test_case "the last occurrence" `Quick
            test_last_index_of_char_finds_the_last_occurrence;
          test_case "an absent character" `Quick test_last_index_of_char_absent;
          test_case "an empty value" `Quick
            test_last_index_of_char_in_empty_value;
        ] );
    ]
