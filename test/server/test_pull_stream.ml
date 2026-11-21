module Pull_stream = Bondi_server__Docker__Pull_stream

(* Both fixtures are bodies a real Docker Engine returned for
   [POST /images/create], saved byte for byte with their [\r\n] line ends; their
   provenance is in [fixtures/README.md]. The path is resolved from the test
   executable rather than the working directory, so the read holds under
   [dune exec] as well as [dune runtest]. *)
let fixture name =
  let path =
    Filename.concat
      (Filename.dirname Sys.executable_name)
      (Filename.concat "fixtures" name)
  in
  In_channel.with_open_bin path In_channel.input_all

(* The message the engine wrote into the capture's [errorDetail], copied from
   the fixture's last line. *)
let missing_layer_message =
  "failed to copy: httpReadSeeker: failed open: could not fetch content \
   descriptor \
   sha256:4197fd833fcc164dbb84ee458cb70ec985dc8284c844053c8c46e5e2ecaeaeed \
   (application/vnd.oci.image.layer.v1.tar+gzip) from remote: not found"

let contains ~needle haystack =
  Bondi_common.String_utils.contains ~needle haystack

let expect_failure_carrying ~needle body =
  match Pull_stream.verdict body with
  | Ok () -> Alcotest.fail "expected the pull to fail, and it passed"
  | Error message ->
      Alcotest.(check bool)
        (Printf.sprintf "the failure %S carries %S" message needle)
        true (contains ~needle message)

(* The engine answered this pull with HTTP 200; the failure is only in the
   body. *)
let test_pull_stream_error_detail () =
  expect_failure_carrying ~needle:missing_layer_message
    (fixture "pull_stream_missing_layer.ndjson")

let test_pull_stream_success () =
  Alcotest.(check (result unit string))
    "a captured successful pull passes" (Ok ())
    (Pull_stream.verdict (fixture "pull_stream_success.ndjson"))

(* [error] is deprecated in the Engine API in favour of [errorDetail], so an
   object carrying the detail alone is a failure just the same. *)
let test_pull_stream_error_detail_alone () =
  expect_failure_carrying ~needle:"manifest unknown"
    "{\"status\":\"Pulling from app\"}\r\n\
     {\"errorDetail\":{\"message\":\"manifest unknown\"}}\r\n"

(* A stream cut off mid-line, as a dropped connection leaves it, cannot be read
   as a success: the line that does not decode fails the pull, and the failure
   shows it. *)
let test_pull_stream_undecodable_line () =
  expect_failure_carrying ~needle:"{\"status\":\"Pull comp"
    "{\"status\":\"Pulling from app\"}\r\n{\"status\":\"Pull comp"

(* A body that ends without the engine's terminal [Status:] line was cut off or
   never written; it is not a success. *)
let expect_failure body =
  match Pull_stream.verdict body with
  | Ok () -> Alcotest.fail "expected the pull to fail, and it passed"
  | Error _ -> ()

let test_pull_stream_empty_body () = expect_failure ""

let test_pull_stream_truncated_success () =
  let body = fixture "pull_stream_success.ndjson" in
  let last_line_start =
    String.rindex_from body (String.length body - 3) '\n' + 1
  in
  expect_failure (String.sub body 0 last_line_start)

let test_pull_stream_up_to_date () =
  Alcotest.(check (result unit string))
    "an image already present passes" (Ok ())
    (Pull_stream.verdict (fixture "pull_stream_up_to_date.ndjson"))

let test_pull_stream_error_alone () =
  expect_failure_carrying ~needle:"toomanyrequests"
    "{\"status\":\"Pulling from app\"}\r\n{\"error\":\"toomanyrequests\"}\r\n"

let test_pull_stream_no_message () =
  expect_failure_carrying ~needle:"gave no message"
    "{\"errorDetail\":{\"code\":404}}\r\n"

let test_pull_stream_non_object_line () =
  expect_failure_carrying ~needle:"not a JSON object" "[1]\r\n"

let test_pull_stream_long_line_bounded () =
  let line = String.make 2000 'x' in
  match Pull_stream.verdict line with
  | Ok () -> Alcotest.fail "expected failure"
  | Error message ->
      Alcotest.(check bool)
        "the line is cut and marked" true
        (contains ~needle:"(truncated, 2000 bytes in all)" message
        && String.length message < 700)

(* Cutting at a byte count must not split a character: the failure stays valid
   UTF-8. *)
let test_pull_stream_multibyte_bounded () =
  let line = String.concat "" (List.init 400 (fun _ -> "\xe2\x82\xac")) in
  match Pull_stream.verdict line with
  | Ok () -> Alcotest.fail "expected failure"
  | Error message ->
      Alcotest.(check bool)
        "the failure is valid UTF-8" true
        (String.is_valid_utf_8 message)

let () =
  Alcotest.run "Docker.Pull_stream"
    [
      ( "verdict",
        [
          Alcotest.test_case "a captured failed pull fails with its message"
            `Quick test_pull_stream_error_detail;
          Alcotest.test_case "a captured successful pull passes" `Quick
            test_pull_stream_success;
          Alcotest.test_case "errorDetail alone fails" `Quick
            test_pull_stream_error_detail_alone;
          Alcotest.test_case "an undecodable line fails closed" `Quick
            test_pull_stream_undecodable_line;
          Alcotest.test_case "an empty body fails" `Quick
            test_pull_stream_empty_body;
          Alcotest.test_case "a truncated success fails" `Quick
            test_pull_stream_truncated_success;
          Alcotest.test_case "an up-to-date pull passes" `Quick
            test_pull_stream_up_to_date;
          Alcotest.test_case "error alone fails" `Quick
            test_pull_stream_error_alone;
          Alcotest.test_case "an error with no message falls back" `Quick
            test_pull_stream_no_message;
          Alcotest.test_case "a non-object line fails" `Quick
            test_pull_stream_non_object_line;
          Alcotest.test_case "a long line is bounded" `Quick
            test_pull_stream_long_line_bounded;
          Alcotest.test_case "a multi-byte line is cut on a character" `Quick
            test_pull_stream_multibyte_bounded;
        ] );
    ]
