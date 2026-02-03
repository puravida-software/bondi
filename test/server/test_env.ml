open Alcotest
module Env = Bondi_server.Env

let test_read_string_success () =
  Unix.putenv "TEST_STRING_VAR" "test_value";
  match Env.read_string "TEST_STRING_VAR" with
  | Ok value -> check string "read_string success" "test_value" value
  | Error _ -> Alcotest.fail "Expected Ok but got Error"

let test_read_string_not_set () =
  match Env.read_string "TEST_STRING_NOT_SET_XYZ123" with
  | Ok _ -> Alcotest.fail "Expected Error but got Ok"
  | Error (Env.Env_not_set var_name) ->
      check string "env var name" "TEST_STRING_NOT_SET_XYZ123" var_name

let test_read_string_with_default_when_set () =
  Unix.putenv "TEST_DEFAULT_VAR" "configured";
  let value = Env.read_string_with_default "TEST_DEFAULT_VAR" "fallback" in
  check string "returns env value" "configured" value

let test_read_string_with_default_when_unset () =
  let rec find_unset_var attempt =
    if attempt > 20 then
      Alcotest.fail "could not find an unset environment variable name";
    let name =
      Printf.sprintf "TEST_DEFAULT_VAR_UNSET_%d_%d" (Unix.getpid ()) attempt
    in
    match Sys.getenv_opt name with
    | None -> name
    | Some _ -> find_unset_var (attempt + 1)
  in
  let name = find_unset_var 0 in
  let value = Env.read_string_with_default name "fallback" in
  check string "returns default value" "fallback" value

let () =
  run "Env"
    [
      ( "read_string",
        [
          test_case "reads existing env var" `Quick test_read_string_success;
          test_case "returns error when env var not set" `Quick
            test_read_string_not_set;
        ] );
      ( "read_string_with_default",
        [
          test_case "returns env value when set" `Quick
            test_read_string_with_default_when_set;
          test_case "returns default when unset" `Quick
            test_read_string_with_default_when_unset;
        ] );
    ]
