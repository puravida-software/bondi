open Alcotest
module Retired_fields = Bondi_client.Retired_fields

(* Every fixture is written as JSON rather than as a record, because the scan's
   subject is the untyped document: it runs before the strict decode and the
   keys it names are exactly the ones no record can hold any more. *)
let refusal ~expectation json =
  match Retired_fields.check (Yojson.Safe.from_string json) with
  | Ok () -> fail expectation
  | Error message -> message

let names ~what ~needle message =
  check bool
    (Printf.sprintf "the refusal names %s, got: %s" what message)
    true
    (Bondi_common.String_utils.contains ~needle message)

let says_nothing_about ~what ~needle message =
  check bool
    (Printf.sprintf "the refusal says nothing about %s, got: %s" what message)
    false
    (Bondi_common.String_utils.contains ~needle message)

let test_retired_bind_address_is_named () =
  let message =
    refusal ~expectation:"expected a declared bind_address to be refused"
      {|{"bondi_server": {"version": "0.1.0", "bind_address": "0.0.0.0"}}|}
  in
  names ~what:"the key" ~needle:"bondi_server.bind_address" message;
  (* The second assertion is what stops a message that lists every retired key
     regardless of what the document declares from passing the first. *)
  says_nothing_about ~what:"a key this document does not declare"
    ~needle:"api_token" message

(* The rotation advice is the only thing this feature carries forward from the
   deprecation warning it replaces: a credential that sat in a configuration
   file is compromised whether or not anything still reads it. The value itself
   is not echoed -- a terminal, a CI log and a scrollback are all poorer places
   for a secret than the file it came from. *)
let test_retired_api_token_says_rotate () =
  let message =
    refusal ~expectation:"expected a declared api_token to be refused"
      {|{"bondi_server": {"version": "0.1.0", "api_token": "not-a-real-token"}}|}
  in
  names ~what:"the key" ~needle:"bondi_server.api_token" message;
  names ~what:"what to do about the value" ~needle:"rotate" message;
  says_nothing_about ~what:"the token's value" ~needle:"not-a-real-token"
    message

(* A key counts as declared whatever it is set to, including written with no
   value at all: it is the member that stops the manifest parsing, not the
   value. A half-edited manifest -- a line emptied after reading the refusal
   rather than removed -- is exactly where that shape turns up. *)
let test_a_retired_key_with_no_value_is_named () =
  let message =
    refusal
      ~expectation:"expected a bind_address written with no value to be refused"
      {|{"bondi_server": {"version": "0.1.0", "bind_address": null}}|}
  in
  names ~what:"the key" ~needle:"bondi_server.bind_address" message

(* The second server carries the port, so the path in the message can only be
   right if the scan walked the list and counted it. A scan that reported the
   first entry, or the list itself, fails here. *)
let test_retired_server_port_is_named () =
  let message =
    refusal ~expectation:"expected a port under a server entry to be refused"
      {|{"service": {"name": "web", "port": 8080,
                     "servers": [{"ip_address": "10.0.0.1"},
                                 {"ip_address": "10.0.0.2", "port": 9}]}}|}
  in
  names ~what:"the server entry that declares it"
    ~needle:"service.servers[1].port" message

(* The operator edits the file once, so one message answers for every retired
   key the document declares -- including the one under a cron job's server,
   which is the same record as a service's and stops parsing for the same
   reason. *)
let test_every_retired_key_is_named_at_once () =
  let message =
    refusal
      ~expectation:
        "expected a document declaring four retired keys to be refused"
      {|{"bondi_server": {"version": "0.1.0",
                          "bind_address": "127.0.0.1",
                          "api_token": "not-a-real-token"},
         "service": {"name": "web", "port": 8080,
                     "servers": [{"ip_address": "10.0.0.1", "port": 9}]},
         "cron_jobs": [{"name": "nightly", "image": "acme/report",
                        "schedule": "0 3 * * *",
                        "server": {"ip_address": "10.0.0.2", "port": 9}}]}|}
  in
  names ~what:"the binding address" ~needle:"bondi_server.bind_address" message;
  names ~what:"the token" ~needle:"bondi_server.api_token" message;
  names ~what:"the service's server port" ~needle:"service.servers[0].port"
    message;
  names ~what:"the cron job's server port" ~needle:"cron_jobs[0].server.port"
    message

(* [service.port] is the port the operator's own container listens on and is
   read on every deploy. It is one word from the field being retired, which is
   the confusion this case exists to catch: a scan matching the bare word would
   refuse every manifest in the estate.

   Both arms run against the same fixture. Without the second, an [Ok ()] here
   is satisfied by a scan that finds nothing anywhere -- including one that
   never reaches inside [service] at all. *)
let test_service_port_is_not_retired () =
  let clean =
    {|{"bondi_server": {"version": "0.1.0"},
       "service": {"name": "web", "port": 8080,
                   "servers": [{"ip_address": "10.0.0.1"}]}}|}
  in
  (match Retired_fields.check (Yojson.Safe.from_string clean) with
  | Ok () -> ()
  | Error message ->
      fail (Printf.sprintf "expected service.port to be read, got: %s" message));
  let with_server_port =
    {|{"bondi_server": {"version": "0.1.0"},
       "service": {"name": "web", "port": 8080,
                   "servers": [{"ip_address": "10.0.0.1", "port": 9}]}}|}
  in
  let message =
    refusal
      ~expectation:
        "expected the same fixture to be refused once its server declares a \
         port"
      with_server_port
  in
  names ~what:"the server's port and not the service's"
    ~needle:"service.servers[0].port" message

let () =
  run "retired fields"
    [
      ( "a retired key is refused by name",
        [
          test_case "a declared bind_address is named" `Quick
            test_retired_bind_address_is_named;
          test_case "a declared api_token says to rotate it" `Quick
            test_retired_api_token_says_rotate;
          test_case "a retired key written with no value is named" `Quick
            test_a_retired_key_with_no_value_is_named;
          test_case "a port under a server entry is named" `Quick
            test_retired_server_port_is_named;
          test_case "every retired key is named at once" `Quick
            test_every_retired_key_is_named_at_once;
          test_case "service.port is not retired" `Quick
            test_service_port_is_not_retired;
        ] );
    ]
