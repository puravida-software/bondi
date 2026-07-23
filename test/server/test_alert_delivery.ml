module Alert_delivery = Bondi_server__Alert_delivery
module Alert = Bondi_common.Alert

(* Build a validated sink, failing the test if the URL is rejected. *)
let sink url =
  match Alert.sink_of_string url with
  | Ok s -> s
  | Error e ->
      Alcotest.failf "expected a valid sink url: %s"
        (Alert.sink_error_to_string e)

(* A [payload] is abstract and produced only by [Alert.plan]; build one through
   a real dispatch so the delivery tests carry a genuine alert body. *)
let some_payload () =
  let sinks : Alert.sinks =
    { critical = []; failure = [ sink "https://payload.example.com/hook" ] }
  in
  match
    Alert.plan Alert.default_severity_map (Alert.Exited 1) sinks ~job:"nightly"
      ~timestamp:1.0
  with
  | Some dispatch -> dispatch.payload
  | None -> Alcotest.fail "expected a dispatch from which to build a payload"

(* Resolve the startup TLS handler for the delivery tests, failing loudly if the
   trust store did not load. *)
let https_or_fail () =
  match Alert_delivery.make_https () with
  | Ok https -> https
  | Error (Alert_delivery.Tls_setup msg) ->
      Alcotest.failf "make_https failed to build a TLS handler: %s" msg

let tcp_addr = `Tcp (Eio.Net.Ipaddr.V4.loopback, 443)

let test_is_success_status () =
  let check_code label expected code =
    Alcotest.(check bool) label expected (Alert_delivery.is_success_status code)
  in
  check_code "200 is a delivered alert" true 200;
  check_code "204 is a delivered alert" true 204;
  check_code "299 is a delivered alert" true 299;
  check_code "199 is a delivery failure" false 199;
  check_code "300 is a delivery failure" false 300;
  check_code "404 is a delivery failure" false 404;
  check_code "500 is a delivery failure" false 500

let test_make_https_ok () =
  match Alert_delivery.make_https () with
  | Ok _ -> ()
  | Error (Alert_delivery.Tls_setup msg) ->
      Alcotest.failf
        "make_https should load the system trust store and return Ok, got \
         error: %s"
        msg

let test_deliver_posts_to_each_target () =
  Eio_mock.Backend.run @@ fun () ->
  let clock = Eio_mock.Clock.make () in
  let net = Eio_mock.Net.make "net" in
  let attempts = ref 0 in
  (* One getaddrinfo + one connect per target. The mock flow's default read
     raises End_of_file, so the TLS handshake fails fast rather than blocking
     the mock backend; what we observe is the per-target connection attempt. *)
  Eio_mock.Net.on_getaddrinfo net [ `Return [ tcp_addr ]; `Return [ tcp_addr ] ];
  Eio_mock.Net.on_connect net
    [
      `Run
        (fun () ->
          incr attempts;
          (Eio_mock.Flow.make "sink-a" :> _ Eio.Net.stream_socket));
      `Run
        (fun () ->
          incr attempts;
          (Eio_mock.Flow.make "sink-b" :> _ Eio.Net.stream_socket));
    ];
  Alert_delivery.deliver ~https:(https_or_fail ()) ~net ~clock
    ~targets:
      [
        sink "https://sink-a.example.com/x"; sink "https://sink-b.example.com/y";
      ]
    ~payload:(some_payload ());
  Alcotest.(check int) "one connection attempt per target" 2 !attempts

let test_deliver_ignores_sink_error () =
  Eio_mock.Backend.run @@ fun () ->
  let clock = Eio_mock.Clock.make () in
  let net = Eio_mock.Net.make "net" in
  let attempted = ref false in
  Eio_mock.Net.on_getaddrinfo net [ `Return [ tcp_addr ] ];
  Eio_mock.Net.on_connect net
    [
      `Run
        (fun () ->
          attempted := true;
          let flow = Eio_mock.Flow.make "sink" in
          Eio_mock.Flow.on_read flow
            [ `Raise (Failure "simulated sink outage") ];
          (flow :> _ Eio.Net.stream_socket));
    ];
  Alert_delivery.deliver ~https:(https_or_fail ()) ~net ~clock
    ~targets:[ sink "https://sink.example.com/hook" ]
    ~payload:(some_payload ());
  (* Reaching this line proves deliver swallowed the sink error; the flag proves
     it genuinely attempted delivery rather than short-circuiting. *)
  Alcotest.(check bool)
    "attempted delivery then swallowed the sink error" true !attempted

let () =
  Alcotest.run "Alert_delivery"
    [
      ( "status",
        [
          Alcotest.test_case "2xx is success, anything else is failure" `Quick
            test_is_success_status;
        ] );
      ( "make_https",
        [ Alcotest.test_case "loads trust store" `Quick test_make_https_ok ] );
      ( "deliver",
        [
          Alcotest.test_case "posts to each target" `Quick
            test_deliver_posts_to_each_target;
          Alcotest.test_case "ignores sink error" `Quick
            test_deliver_ignores_sink_error;
        ] );
    ]
