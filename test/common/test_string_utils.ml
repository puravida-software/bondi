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
    ]
