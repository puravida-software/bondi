open Alcotest
module Auth = Bondi_server.Auth

let decision =
  testable
    (fun ppf -> function
      | Auth.Allow -> Format.fprintf ppf "Allow"
      | Auth.Deny r -> Format.fprintf ppf "Deny %S" r)
    (fun a b ->
      match (a, b) with
      | Auth.Allow, Auth.Allow -> true
      | Auth.Deny _, Auth.Deny _ -> true
      | _ -> false)

let allow = Auth.Allow
let deny = Auth.Deny ""

(* /health must stay open: bondi setup probes it from inside the container with
   busybox wget, which cannot send a header. If this test fails, setup hangs on
   readiness and reports the orchestrator unreachable. *)
let test_health_is_open () =
  check decision "health needs no token" allow
    (Auth.authorize ~token:(Some "secret") ~target:"/api/v1/health"
       ~authorization:None)

(* /status lists image names and tags, so it is not in the same category as
   /health and must be behind the token. *)
let test_status_is_closed () =
  check decision "status requires a token" deny
    (Auth.authorize ~token:(Some "secret") ~target:"/api/v1/status"
       ~authorization:None)

let test_no_token_configured_allows () =
  check decision "loopback deployments run without a token" allow
    (Auth.authorize ~token:None ~target:"/api/v1/deploy" ~authorization:None)

let test_correct_bearer_allows () =
  check decision "correct token" allow
    (Auth.authorize ~token:(Some "s3cret") ~target:"/api/v1/deploy"
       ~authorization:(Some "Bearer s3cret"))

let test_wrong_bearer_denies () =
  check decision "wrong token" deny
    (Auth.authorize ~token:(Some "s3cret") ~target:"/api/v1/deploy"
       ~authorization:(Some "Bearer wrong"))

let test_missing_header_denies () =
  check decision "no header" deny
    (Auth.authorize ~token:(Some "s3cret") ~target:"/api/v1/deploy"
       ~authorization:None)

let test_wrong_scheme_denies () =
  check decision "basic auth is not accepted" deny
    (Auth.authorize ~token:(Some "s3cret") ~target:"/api/v1/deploy"
       ~authorization:(Some "Basic czNjcmV0"))

(* A prefix of the token must not be accepted; this is the case a naive
   String.starts_with comparison would let through. *)
let test_prefix_denies () =
  check decision "prefix of the token" deny
    (Auth.authorize ~token:(Some "s3cret") ~target:"/api/v1/deploy"
       ~authorization:(Some "Bearer s3c"))

let test_run_is_closed () =
  check decision "run requires a token" deny
    (Auth.authorize ~token:(Some "s3cret") ~target:"/api/v1/run"
       ~authorization:(Some "Bearer nope"))

let test_constant_time_equal () =
  check bool "equal" true (Auth.constant_time_equal "abc" "abc");
  check bool "differing last byte" false (Auth.constant_time_equal "abc" "abd");
  check bool "differing first byte" false (Auth.constant_time_equal "abc" "zbc");
  check bool "different length" false (Auth.constant_time_equal "abc" "abcd");
  check bool "empty" true (Auth.constant_time_equal "" "")

let () =
  run "auth"
    [
      ( "authorize",
        [
          test_case "health is open" `Quick test_health_is_open;
          test_case "status is closed" `Quick test_status_is_closed;
          test_case "run is closed" `Quick test_run_is_closed;
          test_case "no token configured" `Quick test_no_token_configured_allows;
          test_case "correct bearer" `Quick test_correct_bearer_allows;
          test_case "wrong bearer" `Quick test_wrong_bearer_denies;
          test_case "missing header" `Quick test_missing_header_denies;
          test_case "wrong scheme" `Quick test_wrong_scheme_denies;
          test_case "token prefix" `Quick test_prefix_denies;
        ] );
      ( "constant_time_equal",
        [ test_case "comparison" `Quick test_constant_time_equal ] );
    ]
