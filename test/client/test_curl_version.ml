module Curl_version = Bondi_client.Curl_version

let accepted output =
  match Curl_version.supports_fail_with_body output with
  | Ok () -> ()
  | Error msg -> Alcotest.fail ("expected acceptance, got: " ^ msg)

let rejection output =
  match Curl_version.supports_fail_with_body output with
  | Ok () -> Alcotest.fail ("expected a rejection for: " ^ String.escaped output)
  | Error msg -> msg

(* The real first line, as `curl --version` prints it. *)
let test_accepts_a_supported_version () =
  accepted
    "curl 8.5.0 (x86_64-pc-linux-gnu) libcurl/8.5.0 OpenSSL/3.0.13 zlib/1.3\n\
     Release-Date: 2023-12-06"

(* 7.76.0 is the release that introduced --fail-with-body, so it is accepted and
   the release before it is not. Asserting both sides pins the boundary rather
   than the direction. *)
let test_accepts_the_minimum_version () =
  accepted "curl 7.76.0 (x86_64-pc-linux-gnu) libcurl/7.76.0"

let test_rejects_the_release_below_the_minimum () =
  let msg = rejection "curl 7.75.0 (x86_64-pc-linux-gnu) libcurl/7.75.0" in
  List.iter
    (fun needle ->
      Alcotest.(check bool)
        (Printf.sprintf "the rejection names %s: %s" needle msg)
        true
        (Bondi_common.String_utils.contains ~needle msg))
    [ "7.75.0"; "7.76" ]

(* Debian 11 and Ubuntu 20.04 are the hosts this guard exists for: both ship a
   curl that would reject --fail-with-body as an unknown option, breaking every
   cron job at once rather than at setup. *)
let test_rejects_the_versions_this_guard_exists_for () =
  ignore (rejection "curl 7.74.0 (x86_64-pc-linux-gnu) libcurl/7.74.0");
  ignore (rejection "curl 7.68.0 (x86_64-pc-linux-gnu) libcurl/7.68.0")

let test_accepts_a_major_above_the_minimum () =
  accepted "curl 8.0.1 (x86_64-pc-linux-gnu) libcurl/8.0.1"

(* A host with no curl at all answers on stderr, not with a version line. The
   guard must say so rather than read the absence as a pass. *)
let test_rejects_unparseable_output () =
  let msg = rejection "bash: curl: command not found" in
  Alcotest.(check bool)
    ("the rejection quotes what the host answered: " ^ msg)
    true
    (Bondi_common.String_utils.contains ~needle:"command not found" msg)

let test_rejects_empty_output () = ignore (rejection "")

let () =
  Alcotest.run "Curl_version"
    [
      ( "supports_fail_with_body",
        [
          Alcotest.test_case "a supported version" `Quick
            test_accepts_a_supported_version;
          Alcotest.test_case "the minimum version" `Quick
            test_accepts_the_minimum_version;
          Alcotest.test_case "the release below the minimum" `Quick
            test_rejects_the_release_below_the_minimum;
          Alcotest.test_case "the versions this guard exists for" `Quick
            test_rejects_the_versions_this_guard_exists_for;
          Alcotest.test_case "a major above the minimum" `Quick
            test_accepts_a_major_above_the_minimum;
          Alcotest.test_case "unparseable output" `Quick
            test_rejects_unparseable_output;
          Alcotest.test_case "empty output" `Quick test_rejects_empty_output;
        ] );
    ]
