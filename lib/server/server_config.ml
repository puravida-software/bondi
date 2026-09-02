type t = { port : int; interface : string; api_token : string option }
type error = Invalid_port of string

(* 0.0.0.0, deliberately, and this is not the exposure it looks like.
   Bondi ships as a container. A socket bound to 0.0.0.0 inside a container's
   network namespace is reachable only from that namespace until Docker
   publishes it, so the bind address is not what decides whether the API faces
   the internet -- the publish address on the host is, and that is chosen by
   [bondi setup] from bondi.yaml's `bind_address` (default 127.0.0.1).

   Binding loopback here would not harden anything; it would break the
   container, because docker-proxy forwards to the container's bridge address
   and would find nothing listening. That was tried on 2026-08-29 and is the
   reason this comment exists.

   BONDI_BIND_INTERFACE remains an escape hatch for running the server directly
   on a host, where loopback is the right choice and the operator is the one
   who knows it. *)
let default_interface = "0.0.0.0"

(* An env var that is declared but empty -- which is what a docker-compose
   `BONDI_API_TOKEN=` or an unsubstituted template produces -- means "not
   configured", not "configure me to the empty string". Without this, an empty
   BONDI_SERVER_PORT aborts startup with Invalid_port "". *)
let read_or_default var default =
  match Env.read_string_with_default var "" with
  | "" -> default
  | v -> v

let read_token () =
  match read_or_default "BONDI_API_TOKEN" "" with
  | "" -> None
  | t -> Some t

let load () : (t, error) result =
  let port = read_or_default "BONDI_SERVER_PORT" "3030" in
  let interface = read_or_default "BONDI_BIND_INTERFACE" default_interface in
  let api_token = read_token () in
  match int_of_string_opt port with
  | None -> Error (Invalid_port port)
  | Some port -> Ok { port; interface; api_token }
