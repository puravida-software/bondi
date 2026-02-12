open Alcotest
module Json_helpers = Bondi_server__Json_helpers

let test_string_map_roundtrip_non_empty () =
  let input =
    [ ("key1", "value1"); ("key2", "value2"); ("env", "production") ]
  in
  let json = Json_helpers.yojson_of_string_map input in
  let result = Json_helpers.string_map_of_yojson json in
  check (list (pair string string)) "roundtrip preserves entries" input result

let test_string_map_roundtrip_empty () =
  let input = [] in
  let json = Json_helpers.yojson_of_string_map input in
  let result = Json_helpers.string_map_of_yojson json in
  check
    (list (pair string string))
    "roundtrip preserves empty list" input result

let test_string_map_roundtrip_single_entry () =
  let input = [ ("single_key", "single_value") ] in
  let json = Json_helpers.yojson_of_string_map input in
  let result = Json_helpers.string_map_of_yojson json in
  check
    (list (pair string string))
    "roundtrip preserves single entry" input result

let test_decode_assoc () =
  let json = `Assoc [ ("a", `String "1"); ("b", `String "2") ] in
  let result = Json_helpers.string_map_of_yojson json in
  check
    (list (pair string string))
    "decodes assoc correctly"
    [ ("a", "1"); ("b", "2") ]
    result

let test_decode_null () =
  let json = `Null in
  let result = Json_helpers.string_map_of_yojson json in
  check (list (pair string string)) "decodes null as empty list" [] result

let test_decode_non_string_value_raises () =
  let json = `Assoc [ ("key", `Int 42) ] in
  try
    ignore (Json_helpers.string_map_of_yojson json);
    Alcotest.fail "expected exception for non-string value"
  with
  | Ppx_yojson_conv_lib.Yojson_conv.Of_yojson_error _ -> ()

let test_decode_non_assoc_raises () =
  let json = `List [ `String "a" ] in
  try
    ignore (Json_helpers.string_map_of_yojson json);
    Alcotest.fail "expected exception for non-object"
  with
  | Ppx_yojson_conv_lib.Yojson_conv.Of_yojson_error _ -> ()

let test_encode_decodes_via_string () =
  let input = [ ("foo", "bar"); ("baz", "qux") ] in
  let json = Json_helpers.yojson_of_string_map input in
  let json_str = Yojson.Safe.to_string json in
  let parsed = Yojson.Safe.from_string json_str in
  let result = Json_helpers.string_map_of_yojson parsed in
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
          test_case "non-string value raises" `Quick
            test_decode_non_string_value_raises;
          test_case "non-object raises" `Quick test_decode_non_assoc_raises;
        ] );
      ( "encode",
        [
          test_case "produces parseable JSON" `Quick
            test_encode_decodes_via_string;
        ] );
    ]
