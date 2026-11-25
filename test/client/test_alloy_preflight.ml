open Alcotest
module Alloy_preflight = Bondi_client.Alloy_preflight
module Host_answer = Bondi_client.Host_answer

let contains = Test_helpers.contains

(* --- Fixtures ---

   [observed -- 2026-11-24, Fedora, ss from iproute2, curl 8.x, Docker CLI
   present and no bondi-alloy container:] the two probe commands, taken from
   [Alloy_preflight] and run with sh, printed exactly
   - curl present: "BONDI_ALLOY_CURL_PRESENT\n";
   - port 12345 with nothing listening: "BONDI_ALLOY_PORT_FREE\n";
   - port 12345 held by a listener of the test's own, no bondi-alloy container:
     "BONDI_ALLOY_PORT_HELD\n";
   - the port probe with a PATH that held no [ss]: "BONDI_ALLOY_PORT_UNREADABLE\n".
   The held-by-Alloy answer was not produced on a host: no host-networked
   bondi-alloy container was available, so the marker is the probe's, assumed
   from its [docker inspect] test, not observed. *)

let answer output = Host_answer.of_host_output output

let curl_name = function
  | Alloy_preflight.Curl_present -> "present"
  | Alloy_preflight.Curl_missing -> "missing"
  | Alloy_preflight.Curl_unreadable _ -> "unreadable"

let port_name = function
  | Alloy_preflight.Port_free -> "free"
  | Alloy_preflight.Port_held_by_alloy -> "held by alloy"
  | Alloy_preflight.Port_held { port } -> Printf.sprintf "held %d" port
  | Alloy_preflight.Port_unreadable { port; _ } ->
      Printf.sprintf "unreadable %d" port

let test_curl_verdicts () =
  List.iter
    (fun (output, expected) ->
      check string output expected
        (curl_name (Alloy_preflight.curl_verdict_of_probe (answer output))))
    [
      ("BONDI_ALLOY_CURL_PRESENT\n", "present");
      ("BONDI_ALLOY_CURL_MISSING\n", "missing");
      ("", "unreadable");
      ("curl 8.0\n", "unreadable");
    ]

let test_curl_refusals_name_the_port () =
  List.iter
    (fun (label, verdict) ->
      match Alloy_preflight.require_curl ~port:12345 verdict with
      | Ok () -> fail (label ^ ": must refuse")
      | Error message ->
          check bool
            (label ^ ": names the port: " ^ message)
            true
            (contains ~needle:"12345" message);
          check bool
            (label ^ ": says nothing was stopped")
            true
            (contains ~needle:"Nothing was stopped" message))
    [
      ("missing", Alloy_preflight.Curl_missing);
      ("unreadable", Alloy_preflight.Curl_unreadable (answer ""));
    ];
  check bool "present passes" true
    (Alloy_preflight.require_curl ~port:12345 Alloy_preflight.Curl_present
    = Ok ())

let verdict_of output =
  Alloy_preflight.port_verdict_of_probe ~port:12345 (answer output)

(* PORT_HELD is a prefix of PORT_HELD_BY_ALLOY: each is compared whole, or a
   port held by Alloy would read as held by a stranger and the other way
   round. *)
let test_port_verdicts () =
  List.iter
    (fun (output, expected) ->
      check string output expected (port_name (verdict_of output)))
    [
      ("BONDI_ALLOY_PORT_FREE\n", "free");
      ("BONDI_ALLOY_PORT_HELD_BY_ALLOY\n", "held by alloy");
      ("BONDI_ALLOY_PORT_HELD\n", "held 12345");
      ("BONDI_ALLOY_PORT_UNREADABLE\n", "unreadable 12345");
      ("", "unreadable 12345");
      ("BONDI_ALLOY_PORT_FREE BONDI_ALLOY_PORT_HELD\n", "unreadable 12345");
    ]

let test_port_refusals () =
  List.iter
    (fun (label, output) ->
      match Alloy_preflight.require_port_available (verdict_of output) with
      | Ok () -> fail (label ^ ": must refuse")
      | Error message ->
          check bool
            (label ^ ": names the port: " ^ message)
            true
            (contains ~needle:"port 12345" message);
          check bool
            (label ^ ": says nothing was stopped")
            true
            (contains ~needle:"Nothing was stopped" message))
    [
      ("held", "BONDI_ALLOY_PORT_HELD\n");
      ("unreadable", "BONDI_ALLOY_PORT_UNREADABLE\n");
      ("empty", "");
    ];
  List.iter
    (fun (label, output) ->
      check bool (label ^ " passes") true
        (Alloy_preflight.require_port_available (verdict_of output) = Ok ()))
    [
      ("free", "BONDI_ALLOY_PORT_FREE\n");
      ("held by alloy", "BONDI_ALLOY_PORT_HELD_BY_ALLOY\n");
    ]

(* The probe asks for the port it was given, and the listing is the one the
   operator would run by hand. *)
let test_port_probe_names_the_port () =
  let command = Alloy_preflight.port_probe_command ~port:23456 in
  check bool "asks ss for the port" true
    (contains ~needle:"ss -Hltn 'sport = :23456'" command);
  check bool "asks for the bondi-alloy container" true
    (contains ~needle:"bondi-alloy" command)

let () =
  run "Alloy_preflight"
    [
      ( "curl",
        [
          test_case "verdicts" `Quick test_curl_verdicts;
          test_case "refusals name the port" `Quick
            test_curl_refusals_name_the_port;
        ] );
      ( "port",
        [
          test_case "verdicts" `Quick test_port_verdicts;
          test_case "refusals" `Quick test_port_refusals;
          test_case "the probe names the port" `Quick
            test_port_probe_names_the_port;
        ] );
    ]
