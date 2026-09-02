open Alcotest
module Server_config = Bondi_server.Server_config

let clear () =
  (* putenv "" rather than unsetenv: Unix.unsetenv is not on every OCaml/Unix
     version this builds against, and load () treats empty as absent anyway. *)
  Unix.putenv "BONDI_SERVER_PORT" "";
  Unix.putenv "BONDI_BIND_INTERFACE" "";
  Unix.putenv "BONDI_API_TOKEN" ""

(* 0.0.0.0 is correct here and is NOT the exposure it resembles. The server runs
   in a container; the socket is confined to that network namespace until Docker
   publishes it, and the publish address is chosen by `bondi setup` from
   bondi.yaml (default 127.0.0.1). Binding loopback here would break the
   container instead of hardening it -- docker-proxy forwards to the bridge
   address and would find nothing listening. The policy lives in
   Cmd.Setup.orchestrator_run_command; see test_orchestrator_bind.ml. *)
let test_default_interface () =
  clear ();
  match Server_config.load () with
  | Ok c ->
      check string "interface" "0.0.0.0" c.interface;
      check int "port" 3030 c.port;
      check bool "no token by default" true (c.api_token = None)
  | Error _ -> fail "expected Ok"

let test_interface_override () =
  clear ();
  Unix.putenv "BONDI_BIND_INTERFACE" "127.0.0.1";
  match Server_config.load () with
  | Ok c -> check string "interface" "127.0.0.1" c.interface
  | Error _ -> fail "expected Ok"

let test_token_read () =
  clear ();
  Unix.putenv "BONDI_API_TOKEN" "a-real-token";
  match Server_config.load () with
  | Ok c -> check bool "token carried" true (c.api_token = Some "a-real-token")
  | Error _ -> fail "expected Ok"

(* A declared-but-empty var is what `BONDI_API_TOKEN=` in a compose file or an
   unsubstituted template produces. It means "not configured". Without this an
   empty port aborts startup and an empty interface asks Dream to bind nothing. *)
let test_empty_is_absent () =
  clear ();
  Unix.putenv "BONDI_SERVER_PORT" "";
  Unix.putenv "BONDI_API_TOKEN" "";
  match Server_config.load () with
  | Ok c ->
      check int "port falls back" 3030 c.port;
      check bool "empty token is None" true (c.api_token = None)
  | Error _ -> fail "empty must mean absent, not invalid"

let test_invalid_port () =
  clear ();
  Unix.putenv "BONDI_SERVER_PORT" "not-a-port";
  match Server_config.load () with
  | Error (Server_config.Invalid_port p) -> check string "port" "not-a-port" p
  | _ -> fail "expected Invalid_port"

let () =
  run "server_config"
    [
      ( "load",
        [
          test_case "default interface" `Quick test_default_interface;
          test_case "interface override" `Quick test_interface_override;
          test_case "token read" `Quick test_token_read;
          test_case "empty is absent" `Quick test_empty_is_absent;
          test_case "invalid port" `Quick test_invalid_port;
        ] );
    ]
