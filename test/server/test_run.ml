module Run = Bondi_server__Run
module Docker = Bondi_server__Docker__Client

let show_networking_conf = function
  | None -> "None"
  | Some conf ->
      Docker.networking_config_to_yojson conf |> Yojson.Safe.to_string

let check_networking_conf msg ~expected ~actual =
  Alcotest.check Alcotest.string msg
    (show_networking_conf expected)
    (show_networking_conf actual)

let endpoint_on network : Docker.networking_config =
  let endpoint : Docker.endpoint_config =
    { aliases = None; ipv4_address = None }
  in
  { endpoints_config = Some [ (network, endpoint) ] }

let mk_payload ?network () : Run.run_payload =
  { job = "nightly"; image = "myapp:v1"; network; env_vars = None }

let test_networking_conf_from_network () =
  check_networking_conf "network produces one endpoint entry"
    ~expected:(Some (endpoint_on "bondi-network"))
    ~actual:(Run.networking_conf_of_network (Some "bondi-network"))

let test_run_opts_carries_network () =
  let opts : Docker.run_image_options =
    Run.run_opts ~container_name:"nightly-1" ~full_image:"myapp:v1"
      (mk_payload ~network:"bondi-network" ())
  in
  check_networking_conf "payload network reaches the run options"
    ~expected:(Some (endpoint_on "bondi-network"))
    ~actual:opts.networking_conf

let test_run_opts_absent_network () =
  let opts : Docker.run_image_options =
    Run.run_opts ~container_name:"nightly-1" ~full_image:"myapp:v1"
      (mk_payload ())
  in
  check_networking_conf "absent payload network reaches the run options"
    ~expected:None ~actual:opts.networking_conf

let test_networking_conf_none_when_network_absent () =
  check_networking_conf "absent network produces no networking config"
    ~expected:None
    ~actual:(Run.networking_conf_of_network None)

let test_run_response_with_warning_json () =
  let response : Run.run_response =
    { exit_code = 1; warning = Some "failed to remove old container" }
  in
  let json = Run.run_response_to_yojson response in
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
  let json = Run.run_response_to_yojson response in
  let expected = `Assoc [ ("exit_code", `Int 0) ] in
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
      ( "networking_conf_of_network",
        [
          Alcotest.test_case "from network" `Quick
            test_networking_conf_from_network;
          Alcotest.test_case "none when network absent" `Quick
            test_networking_conf_none_when_network_absent;
        ] );
      ( "run_opts",
        [
          Alcotest.test_case "carries network" `Quick
            test_run_opts_carries_network;
          Alcotest.test_case "absent network" `Quick
            test_run_opts_absent_network;
        ] );
    ]
