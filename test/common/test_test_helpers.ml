open Alcotest

(* The assertion helpers are themselves asserted on, because a weak one does not
   fail: it passes against output it was written to reject, and every test that
   reaches for it inherits the hole silently. *)

let test_contains_finds_a_substring () =
  check bool "a substring anywhere in the value" true
    (Test_helpers.contains ~needle:"ell" "hello")

let test_contains_rejects_an_absent_substring () =
  check bool "a substring that is not there" false
    (Test_helpers.contains ~needle:"xyz" "hello")

(* The reason this module exists. [contains] answers yes for every needle that
   is a fragment of a longer word the same renderer can print, and the pairs
   below are the ones this project actually renders. *)
let test_contains_is_fooled_by_a_longer_word () =
  check bool "contains cannot tell healthy from unhealthy" true
    (Test_helpers.contains ~needle:"healthy" "  gateway  docker  unhealthy: 3")

let test_contains_word_rejects_a_longer_word () =
  check bool "unhealthy does not contain the word healthy" false
    (Test_helpers.contains_word ~word:"healthy"
       "  gateway  docker  unhealthy: 3")

let test_contains_word_finds_the_word_itself () =
  check bool "the word delimited by spaces" true
    (Test_helpers.contains_word ~word:"healthy" "  gateway  docker  healthy")

let test_contains_word_finds_a_word_at_the_start () =
  check bool "the word at the very start of the value" true
    (Test_helpers.contains_word ~word:"healthy" "healthy at last")

let test_contains_word_spans_lines () =
  check bool "a word on the second of two lines" true
    (Test_helpers.contains_word ~word:"healthy" "gateway docker\nworker healthy")

let test_contains_word_rejects_a_trailing_fragment () =
  check bool "no healthcheck defined does not contain the word healthy" false
    (Test_helpers.contains_word ~word:"healthy"
       "  gateway  docker  no healthcheck defined")

let () =
  run "Test_helpers"
    [
      ( "contains",
        [
          test_case "a substring" `Quick test_contains_finds_a_substring;
          test_case "an absent substring" `Quick
            test_contains_rejects_an_absent_substring;
          test_case "a longer word containing it" `Quick
            test_contains_is_fooled_by_a_longer_word;
        ] );
      ( "contains_word",
        [
          test_case "a longer word containing it" `Quick
            test_contains_word_rejects_a_longer_word;
          test_case "the word itself" `Quick
            test_contains_word_finds_the_word_itself;
          test_case "the word at the start" `Quick
            test_contains_word_finds_a_word_at_the_start;
          test_case "a word on a later line" `Quick
            test_contains_word_spans_lines;
          test_case "a trailing fragment" `Quick
            test_contains_word_rejects_a_trailing_fragment;
        ] );
    ]
