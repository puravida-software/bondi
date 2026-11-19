open Alcotest
module Readiness_document = Bondi_common.Readiness_document
module String_utils = Bondi_common.String_utils

(* The documents here are written out as literal text rather than produced by
   the server's encoder: a decoder judged only against the encoder it is paired
   with proves the two agree, not that either reads the shape the wire carries.
   The server's own suite decodes the encoder's output, which is the other half. *)

let decoded_ready text =
  match Readiness_document.of_string text with
  | Ok document -> Readiness_document.ready document
  | Error reason -> fail ("the document should decode, but: " ^ reason)

(* A refusal is asserted to quote the text it refused, because that text is the
   only evidence of what the box answered, and to name the part of it that was
   wrong, because the text alone does not say which rule it broke. *)
let check_refused ~names text =
  match Readiness_document.of_string text with
  | Ok document ->
      fail
        (Printf.sprintf "%S should be refused, but decoded with ready = %b" text
           (Readiness_document.ready document))
  | Error reason ->
      check bool
        (Printf.sprintf "the reason %S quotes the rejected text" reason)
        true
        (String_utils.contains ~needle:text reason);
      check bool
        (Printf.sprintf "the reason %S names %S" reason names)
        true
        (String_utils.contains ~needle:names reason)

let test_ready_with_probes_decodes_as_ready () =
  check bool "ready is true" true
    (decoded_ready
       {|{"ready":true,"probes":[{"name":"docker_socket","ok":true}]}|})

let test_not_ready_with_probes_decodes_as_not_ready () =
  check bool "ready is false" false
    (decoded_ready
       {|{"ready":false,"probes":[{"name":"docker_socket","ok":false,"reason":"the docker socket cannot be opened"}]}|})

(* JSON does not order an object's keys, so a document whose keys arrive the
   other way round is the same document. *)
let test_key_order_does_not_matter () =
  check bool "ready is true with probes first" true
    (decoded_ready {|{"probes":[],"ready":true}|})

(* The shape an earlier fake answered in: a client that accepted it would call a
   box ready on the strength of a document the server never writes. *)
let test_observations_shape_is_refused_and_quoted () =
  check_refused ~names:"observations" {|{"ready":true,"observations":[]}|}

let test_missing_ready_is_refused () =
  check_refused ~names:"ready" {|{"probes":[]}|}

let test_ready_as_a_string_is_refused () =
  check_refused ~names:"ready" {|{"ready":"true","probes":[]}|}

let test_probes_not_a_list_is_refused () =
  check_refused ~names:"probes" {|{"ready":true,"probes":{}}|}

(* A key repeated is not a document the server writes, and decoding it would
   mean choosing which of two contradictory flags to believe. *)
let test_a_repeated_key_is_refused () =
  check_refused ~names:"ready" {|{"ready":false,"ready":true,"probes":[]}|}

let test_text_that_is_not_json_is_refused () =
  check_refused ~names:"JSON" "docker: command not found"

let test_a_value_that_is_not_an_object_is_refused () =
  check_refused ~names:"object" "true"

(* The quoted text is bounded, because an answer is free text whose length the
   box chose and the reason is printed to a terminal. *)
let test_a_long_answer_is_bounded_in_the_reason () =
  let text = String.make 100_000 'x' in
  match Readiness_document.of_string text with
  | Ok _ -> fail "a long non-JSON answer should be refused"
  | Error reason ->
      check bool "the reason is far shorter than the answer" true
        (String.length reason < 10_000);
      check bool "the reason says the answer was cut" true
        (String_utils.contains ~needle:"truncated" reason)

(* Empty stdout is what a box answers when the check wrote nothing at all. *)
let test_empty_text_is_refused () =
  match Readiness_document.of_string "" with
  | Ok _ -> fail "empty text should be refused"
  | Error reason ->
      check bool "the reason names JSON" true
        (String_utils.contains ~needle:"JSON" reason)

(* The parser's own message rides in the reason beside the quoted text, so it is
   bounded here, not left to the parser's behaviour. Text that is not JSON and
   whose first token is a very long run is the shape that makes a parser
   message long. *)
let test_the_parser_detail_is_bounded () =
  let text = "{\"" ^ String.make 100_000 'x' in
  match Readiness_document.of_string text with
  | Ok _ -> fail "an unterminated object should be refused"
  | Error reason ->
      check bool "the reason is far shorter than the answer" true
        (String.length reason < 4_000)

let test_quote_flattens_and_bounds () =
  let quoted = Readiness_document.quote ("a\nb" ^ String.make 100_000 'x') in
  check bool "one line" false (String.contains quoted '\n');
  check bool "bounded" true (String.length quoted < 4_000);
  check string "short text is kept" "a b" (Readiness_document.quote "a\nb")

let () =
  run "Readiness document"
    [
      ( "decodes",
        [
          test_case "ready with probes decodes as ready" `Quick
            test_ready_with_probes_decodes_as_ready;
          test_case "not ready with probes decodes as not ready" `Quick
            test_not_ready_with_probes_decodes_as_not_ready;
          test_case "key order does not matter" `Quick
            test_key_order_does_not_matter;
        ] );
      ( "refuses",
        [
          test_case "observations shape is refused and quoted" `Quick
            test_observations_shape_is_refused_and_quoted;
          test_case "missing ready is refused" `Quick
            test_missing_ready_is_refused;
          test_case "ready as a string is refused" `Quick
            test_ready_as_a_string_is_refused;
          test_case "probes not a list is refused" `Quick
            test_probes_not_a_list_is_refused;
          test_case "a repeated key is refused" `Quick
            test_a_repeated_key_is_refused;
          test_case "text that is not JSON is refused" `Quick
            test_text_that_is_not_json_is_refused;
          test_case "a value that is not an object is refused" `Quick
            test_a_value_that_is_not_an_object_is_refused;
          test_case "a long answer is bounded in the reason" `Quick
            test_a_long_answer_is_bounded_in_the_reason;
          test_case "empty text is refused" `Quick test_empty_text_is_refused;
          test_case "the parser detail is bounded" `Quick
            test_the_parser_detail_is_bounded;
          test_case "quote flattens and bounds" `Quick
            test_quote_flattens_and_bounds;
        ] );
    ]
