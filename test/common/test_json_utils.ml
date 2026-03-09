open Alcotest
module Json_utils = Bondi_common.Json_utils

let unwrap = function
  | Ok v -> v
  | Error msg -> Alcotest.fail ("unexpected error: " ^ msg)

let test_string_map_roundtrip_non_empty () =
  let input =
    [ ("key1", "value1"); ("key2", "value2"); ("env", "production") ]
  in
  let json = Json_utils.string_map_to_yojson input in
  let result = Json_utils.string_map_of_yojson json |> unwrap in
  check (list (pair string string)) "roundtrip preserves entries" input result

let test_string_map_roundtrip_empty () =
  let input = [] in
  let json = Json_utils.string_map_to_yojson input in
  let result = Json_utils.string_map_of_yojson json |> unwrap in
  check
    (list (pair string string))
    "roundtrip preserves empty list" input result

let test_string_map_roundtrip_single_entry () =
  let input = [ ("single_key", "single_value") ] in
  let json = Json_utils.string_map_to_yojson input in
  let result = Json_utils.string_map_of_yojson json |> unwrap in
  check
    (list (pair string string))
    "roundtrip preserves single entry" input result

let test_decode_assoc () =
  let json = `Assoc [ ("a", `String "1"); ("b", `String "2") ] in
  let result = Json_utils.string_map_of_yojson json |> unwrap in
  check
    (list (pair string string))
    "decodes assoc correctly"
    [ ("a", "1"); ("b", "2") ]
    result

let test_decode_null () =
  let json = `Null in
  let result = Json_utils.string_map_of_yojson json |> unwrap in
  check (list (pair string string)) "decodes null as empty list" [] result

let test_decode_non_string_value_returns_error () =
  let json = `Assoc [ ("key", `Int 42) ] in
  match Json_utils.string_map_of_yojson json with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "expected error for non-string value"

let test_decode_non_assoc_returns_error () =
  let json = `List [ `String "a" ] in
  match Json_utils.string_map_of_yojson json with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "expected error for non-object"

let test_encode_decodes_via_string () =
  let input = [ ("foo", "bar"); ("baz", "qux") ] in
  let json = Json_utils.string_map_to_yojson input in
  let json_str = Yojson.Safe.to_string json in
  let parsed = Yojson.Safe.from_string json_str in
  let result = Json_utils.string_map_of_yojson parsed |> unwrap in
  check
    (list (pair string string))
    "encode produces parseable JSON" input result

let () =
  run "Json_helpers"
    [
      ( "string_map roundtrip",
        [
          test_case "non-empty map" `Quick test_string_map_roundtrip_non_empty;
          test_case "empty map" `Quick test_string_map_roundtrip_empty;
          test_case "single entry" `Quick test_string_map_roundtrip_single_entry;
        ] );
      ( "decode",
        [
          test_case "assoc object" `Quick test_decode_assoc;
          test_case "null as empty" `Quick test_decode_null;
          test_case "non-string value returns error" `Quick
            test_decode_non_string_value_returns_error;
          test_case "non-object returns error" `Quick
            test_decode_non_assoc_returns_error;
        ] );
      ( "encode",
        [
          test_case "produces parseable JSON" `Quick
            test_encode_decodes_via_string;
        ] );
    ]
