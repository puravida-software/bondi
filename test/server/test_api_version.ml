module Api_version = Bondi_server__Docker__Api_version

let unwrap = function
  | Ok v -> v
  | Error msg -> Alcotest.fail ("unexpected error: " ^ msg)

let version str = Api_version.of_string str |> unwrap

let window_of ~minimum ~maximum =
  Api_version.window ~minimum:(version minimum) ~maximum:(version maximum)
  |> unwrap

let test_reads_a_bare_version () =
  Alcotest.check Alcotest.string "round trips" "1.44"
    (Api_version.to_string (version "1.44"))

let test_reads_a_v_prefixed_version () =
  Alcotest.check Alcotest.string "the prefix is not part of the value" "1.44"
    (Api_version.to_string (version "v1.44"))

let test_path_segment_carries_the_prefix () =
  Alcotest.check Alcotest.string "a request path wants the v" "v1.44"
    (Api_version.to_path_segment (version "1.44"))

let rejects str () =
  match Api_version.of_string str with
  | Ok _ -> Alcotest.fail (Printf.sprintf "%S was accepted" str)
  | Error _ -> ()

(* The whole reason this is not a string: the daemon's floor was 1.44 and the
   pinned value was 1.41, and "1.41" > "1.44" is false while "1.9" > "1.44" is
   true. A string comparison orders 1.9 above 1.41, which is backwards. *)
let test_orders_by_number_not_by_text () =
  Alcotest.check Alcotest.bool "1.9 precedes 1.41" true
    (Api_version.compare (version "1.9") (version "1.41") < 0);
  Alcotest.check Alcotest.bool "1.41 precedes 1.44" true
    (Api_version.compare (version "1.41") (version "1.44") < 0);
  Alcotest.check Alcotest.int "equal versions compare equal" 0
    (Api_version.compare (version "1.44") (version "1.44"))

let test_a_window_cannot_be_inverted () =
  match
    Api_version.window ~minimum:(version "1.53") ~maximum:(version "1.44")
  with
  | Ok _ -> Alcotest.fail "an inverted window was accepted"
  | Error _ -> ()

let test_a_single_version_window_is_allowed () =
  let w = window_of ~minimum:"1.44" ~maximum:"1.44" in
  Alcotest.check Alcotest.string "the only version it can be" "1.44"
    (Api_version.to_string (Api_version.choose ~preferred:(version "1.41") w))

let test_a_preferred_version_inside_the_window_is_kept () =
  let w = window_of ~minimum:"1.24" ~maximum:"1.48" in
  Alcotest.check Alcotest.string "nothing to clamp" "1.41"
    (Api_version.to_string (Api_version.choose ~preferred:(version "1.41") w))

(* [observed 2026-09-15] 178.156.181.234 answers Api=1.53 Min=1.44, and the
   orchestrator's pinned v1.41 fell below the floor: every Engine call returned
   "client version 1.41 is too old. Minimum supported API version is 1.44". *)
let test_a_preferred_version_below_the_floor_is_raised () =
  let w = window_of ~minimum:"1.44" ~maximum:"1.53" in
  Alcotest.check Alcotest.string "raised to the daemon's floor" "1.44"
    (Api_version.to_string (Api_version.choose ~preferred:(version "1.41") w))

(* The other direction, which is what the revert to 1.41 was fixing: a GitHub
   runner's Engine 28.0.4 caps at 1.48, and a pin of 1.53 failed there with
   "client version 1.53 is too new". *)
let test_a_preferred_version_above_the_ceiling_is_lowered () =
  let w = window_of ~minimum:"1.24" ~maximum:"1.48" in
  Alcotest.check Alcotest.string "lowered to the daemon's ceiling" "1.48"
    (Api_version.to_string (Api_version.choose ~preferred:(version "1.53") w))

let () =
  Alcotest.run "api_version"
    [
      ( "reading",
        [
          Alcotest.test_case "a bare version" `Quick test_reads_a_bare_version;
          Alcotest.test_case "a v-prefixed version" `Quick
            test_reads_a_v_prefixed_version;
          Alcotest.test_case "a path segment" `Quick
            test_path_segment_carries_the_prefix;
          Alcotest.test_case "empty" `Quick (rejects "");
          Alcotest.test_case "no minor" `Quick (rejects "1");
          Alcotest.test_case "not a number" `Quick (rejects "1.x");
          Alcotest.test_case "three components" `Quick (rejects "1.44.2");
          Alcotest.test_case "a bare v" `Quick (rejects "v");
        ] );
      ( "ordering",
        [
          Alcotest.test_case "by number, not by text" `Quick
            test_orders_by_number_not_by_text;
        ] );
      ( "choosing",
        [
          Alcotest.test_case "an inverted window is refused" `Quick
            test_a_window_cannot_be_inverted;
          Alcotest.test_case "a one-version window" `Quick
            test_a_single_version_window_is_allowed;
          Alcotest.test_case "inside the window" `Quick
            test_a_preferred_version_inside_the_window_is_kept;
          Alcotest.test_case "below the floor" `Quick
            test_a_preferred_version_below_the_floor_is_raised;
          Alcotest.test_case "above the ceiling" `Quick
            test_a_preferred_version_above_the_ceiling_is_lowered;
        ] );
    ]
