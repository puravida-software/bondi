open Alcotest
module Alloy_health = Bondi_client.Alloy_health
module Host_answer = Bondi_client.Host_answer

let contains = Test_helpers.contains

(* --- Fixtures ---

   Each answer below is what [Alloy_health.probe_command] printed when it was
   run on a host, so a verdict is only ever asked of a string the real probe
   can print. The probe always exits 0 and carries its answer as one line on
   standard output; a probe that could not be run at all fails over SSH and
   never reaches the verdict.

   [observed -- 2026-11-24, Docker Engine 29.10.0, host curl 8.22.0: the
   command setup sends, port 12345 and a 30 s bound, taken from a setup run's
   own argv and run with sh on the host:]
   - with grafana/alloy:v1.8.0 running under --network host and
     --server.http.listen-addr=127.0.0.1:12345, it printed exactly
     "BONDI_ALLOY_HEALTHY\n" after about 1 s;
     [observed -- 2026-11-24, Docker Engine 29.10.0: the generated config
     (emit_config, all mode) under the shipped run arguments answered 200 about
     0.3 s after docker run returned;]
   - with nothing listening on the port, it printed exactly
     "BONDI_ALLOY_NEVER_HEALTHY\n" once its 30 s had passed;
   - with a PATH holding only sh, date and sleep, it printed exactly
     "BONDI_ALLOY_CURL_MISSING\n" at once.
   The 500 answer is read from Alloy v1.8.0's source, internal/service/http/
   http.go lines 189-211 [https://raw.githubusercontent.com/grafana/alloy/
   v1.8.0/internal/service/http/http.go]: /-/healthy answers 500 with
   "unhealthy components: " and the names, or 200. It was not captured from a
   running Alloy.
   [observed -- same day and engine, the same loop on port 12397 with an 8 s
   bound:] with the port held by another process that accepted and never
   answered, the Alloy started there exited 1 ("failed to listen on
   127.0.0.1:12397 ... address already in use"), and the probe printed
   "BONDI_ALLOY_NEVER_HEALTHY" after its bound. That is the answer the
   failure below is worded for. *)

let healthy_answer = "BONDI_ALLOY_HEALTHY\n"
let never_healthy_answer = "BONDI_ALLOY_NEVER_HEALTHY\n"
let curl_missing_answer = "BONDI_ALLOY_CURL_MISSING\n"

let unhealthy_answer =
  "BONDI_ALLOY_UNHEALTHY\nunhealthy components: loki.write.grafana_cloud\n"

let verdict_of output =
  Alloy_health.verdict_of_probe ~port:12345 (Host_answer.of_host_output output)

let verdict_name = function
  | Alloy_health.Healthy -> "Healthy"
  | Alloy_health.Never_healthy { port } ->
      Printf.sprintf "Never_healthy %d" port
  | Alloy_health.Unhealthy { body } -> "Unhealthy " ^ body
  | Alloy_health.Curl_missing -> "Curl_missing"
  | Alloy_health.Unreadable answer ->
      "Unreadable " ^ Host_answer.to_string answer

(* --- Tests --- *)

(* The affirmative arm every rejection below is measured against: the answer a
   running Alloy produced is a pass, and setup goes on. *)
let test_verdict_healthy () =
  check string "the answer a running Alloy produced" "Healthy"
    (verdict_name (verdict_of healthy_answer));
  check (result unit string) "a healthy Alloy lets setup go on" (Ok ())
    (Alloy_health.require_healthy (verdict_of healthy_answer))

(* An Alloy that cannot bind exits while [docker run -d] still succeeds, so this
   is the answer that turns that exit into a failure. The port is the one the
   probe was asked about, and the sentence says what an operator checks first. *)
let test_verdict_never_healthy_names_port () =
  check string "the answer a port with nothing on it produced"
    "Never_healthy 12345"
    (verdict_name (verdict_of never_healthy_answer));
  match Alloy_health.require_healthy (verdict_of never_healthy_answer) with
  | Ok () -> fail "an Alloy that never answered healthy must fail setup"
  | Error message ->
      check bool
        ("names the port: " ^ message)
        true
        (contains ~needle:"12345" message);
      check bool
        ("says another process may hold it: " ^ message)
        true
        (contains ~needle:"another process" message)

(* A box without curl never asked Alloy anything, so its failure must say that
   and must not send the operator to the port. *)
let test_verdict_curl_missing () =
  check string "the answer a box without curl produced" "Curl_missing"
    (verdict_name (verdict_of curl_missing_answer));
  match Alloy_health.require_healthy (verdict_of curl_missing_answer) with
  | Ok () -> fail "a probe that could not ask must fail setup"
  | Error message ->
      check bool ("names curl: " ^ message) true
        (contains ~needle:"curl" message);
      check bool
        ("does not blame the port: " ^ message)
        false
        (contains ~needle:"another process" message
        || contains ~needle:"12345" message)

(* Alloy up and reporting a failing component is not a held port: the sentence
   carries Alloy's own words and sends nobody to the port. *)
let test_verdict_unhealthy_carries_body () =
  check string "the answer an Alloy with a failing component produced"
    "Unhealthy unhealthy components: loki.write.grafana_cloud"
    (verdict_name (verdict_of unhealthy_answer));
  match Alloy_health.require_healthy (verdict_of unhealthy_answer) with
  | Ok () -> fail "an unhealthy Alloy must fail setup"
  | Error message ->
      check bool
        ("quotes Alloy's body: " ^ message)
        true
        (contains ~needle:"loki.write.grafana_cloud" message);
      check bool
        ("does not blame the port: " ^ message)
        false
        (contains ~needle:"another process" message
        || contains ~needle:"12345" message)

(* An answer carrying no marker is no verdict, never a pass. An empty answer is
   what a host gives when its shell printed nothing, and it is the answer a
   stub gives for a command it does not know: read as healthy, it is exactly
   the silent success this wait exists to prevent. *)
let test_verdict_unmarked_answer_is_unreadable () =
  List.iter
    (fun answer ->
      check string
        (Printf.sprintf "the answer %S" answer)
        ("Unreadable " ^ answer)
        (verdict_name (verdict_of answer));
      match Alloy_health.require_healthy (verdict_of answer) with
      | Ok () -> fail "an answer without a marker must fail setup"
      | Error message ->
          check bool
            ("does not blame the port: " ^ message)
            false
            (contains ~needle:"another process" message))
    [ ""; "curl: (7) Failed to connect"; "BONDI_ALLOY_HEALTHY_X" ]

let () =
  run "Alloy_health"
    [
      ( "verdict_of_probe",
        [
          test_case "a running Alloy is healthy" `Quick test_verdict_healthy;
          test_case "never healthy names the port" `Quick
            test_verdict_never_healthy_names_port;
          test_case "an unhealthy Alloy carries its body" `Quick
            test_verdict_unhealthy_carries_body;
          test_case "a missing curl is its own verdict" `Quick
            test_verdict_curl_missing;
          test_case "an answer with no marker is no pass" `Quick
            test_verdict_unmarked_answer_is_unreadable;
        ] );
    ]
