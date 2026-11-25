open Alcotest
module Alloy_run_args = Bondi_client.Alloy_run_args

(* The expected arguments are written out here rather than built from the
   module's constants, so a constant that changes makes this fail instead of
   agreeing with itself. The host directory is deliberately not the shipped
   one, which is how a source that ignored its argument would show. *)
let test_journal_args_name_mounts_state_bind_and_storage_path () =
  let args = Alloy_run_args.journal ~host_state_dir:"/tmp/run-state" in
  check (list string) "docker options"
    [
      "--mount";
      "type=bind,source=/var/log/journal,target=/var/log/journal,readonly";
      "--mount";
      "type=bind,source=/tmp/run-state,target=/var/lib/bondi/alloy";
    ]
    args.docker_options;
  check (list string) "alloy options"
    [ "--storage.path=/var/lib/bondi/alloy" ]
    args.alloy_options;
  check string "shipped host state directory" "/var/lib/bondi/alloy"
    Alloy_run_args.state_dir

(* The port is deliberately not the shipped one, so an [http] that ignored its
   argument and spelled the default would fail here. The lists are compared
   whole, which is what keeps out a wildcard listen address and a published
   port: either would be an extra or a different element. *)
let test_http_host_network_and_loopback_listen () =
  let args = Alloy_run_args.http ~listen_port:12399 in
  check (list string) "docker options" [ "--network"; "host" ]
    args.docker_options;
  check (list string) "alloy options"
    [ "--server.http.listen-addr=127.0.0.1:12399" ]
    args.alloy_options

(* Written out rather than read from a second constant, so a changed port is a
   failing test and not a test that agrees with itself. It is Alloy's own
   default, and the port the operator's counters command names. *)
let test_http_listen_port_is_12345 () =
  check int "shipped listen port" 12345 Alloy_run_args.http_listen_port

let () =
  run "Alloy_run_args"
    [
      ( "journal",
        [
          test_case "journal args name the mounts, state bind and storage path"
            `Quick test_journal_args_name_mounts_state_bind_and_storage_path;
        ] );
      ( "http",
        [
          test_case "host networking and a loopback listen address" `Quick
            test_http_host_network_and_loopback_listen;
          test_case "the shipped listen port is 12345" `Quick
            test_http_listen_port_is_12345;
        ] );
    ]
