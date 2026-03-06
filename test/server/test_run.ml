module Run = Bondi_server__Run

let test_run_response_with_warning_json () =
  let response : Run.run_response =
    { exit_code = 1; warning = Some "failed to remove old container" }
  in
  let json = Run.yojson_of_run_response response in
  let expected =
    `Assoc
      [
        ("exit_code", `Int 1);
        ("warning", `String "failed to remove old container");
      ]
  in
  Alcotest.check Alcotest.string "run_response with warning"
    (Yojson.Safe.to_string expected)
    (Yojson.Safe.to_string json)

let test_run_response_without_warning_json () =
  let response : Run.run_response = { exit_code = 0; warning = None } in
  let json = Run.yojson_of_run_response response in
  let expected = `Assoc [ ("exit_code", `Int 0); ("warning", `Null) ] in
  Alcotest.check Alcotest.string "run_response without warning"
    (Yojson.Safe.to_string expected)
    (Yojson.Safe.to_string json)

let test_combine_warnings_none_none () =
  Alcotest.check
    (Alcotest.option Alcotest.string)
    "both None" None
    (Run.combine_warnings None None)

let test_combine_warnings_some_none () =
  Alcotest.check
    (Alcotest.option Alcotest.string)
    "first Some" (Some "a")
    (Run.combine_warnings (Some "a") None)

let test_combine_warnings_none_some () =
  Alcotest.check
    (Alcotest.option Alcotest.string)
    "second Some" (Some "b")
    (Run.combine_warnings None (Some "b"))

let test_combine_warnings_some_some () =
  Alcotest.check
    (Alcotest.option Alcotest.string)
    "both Some" (Some "a; b")
    (Run.combine_warnings (Some "a") (Some "b"))

let () =
  Alcotest.run "Run"
    [
      ( "run_response JSON",
        [
          Alcotest.test_case "with warning" `Quick
            test_run_response_with_warning_json;
          Alcotest.test_case "without warning" `Quick
            test_run_response_without_warning_json;
        ] );
      ( "combine_warnings",
        [
          Alcotest.test_case "None + None" `Quick
            test_combine_warnings_none_none;
          Alcotest.test_case "Some + None" `Quick
            test_combine_warnings_some_none;
          Alcotest.test_case "None + Some" `Quick
            test_combine_warnings_none_some;
          Alcotest.test_case "Some + Some" `Quick
            test_combine_warnings_some_some;
        ] );
    ]
