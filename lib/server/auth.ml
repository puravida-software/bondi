(* Bearer-token authorisation for the orchestrator API.

   The API can start a container with the host Docker socket mounted, which
   makes it equivalent to root on the box. It was previously served on
   0.0.0.0 with empty middleware lists, so anyone who found the port could
   deploy. Server_config now defaults the bind interface to loopback and
   refuses to start on a public interface without a token; this module is what
   makes that token mean something.

   [health_path] stays unauthenticated on purpose. [bondi setup] probes it from
   inside the orchestrator container with busybox wget, which has no way to
   carry a header, and the response is an empty 204 that discloses nothing.
   Every other route -- including /status, which lists image names and tags --
   requires the token. *)

let health_path = "/api/v1/health"

type decision = Allow | Deny of string

(* Compare without an early exit, so the time taken does not reveal how many
   leading bytes of a guess were correct. Lengths are compared first and that
   difference is observable, which is acceptable: tokens are fixed-length and
   the length of a secret is not the secret. *)
let constant_time_equal a b =
  if String.length a <> String.length b then false
  else begin
    let acc = ref 0 in
    String.iteri
      (fun i ca -> acc := !acc lor (Char.code ca lxor Char.code b.[i]))
      a;
    !acc = 0
  end

let bearer_of_header header =
  let prefix = "Bearer " in
  let n = String.length prefix in
  if String.length header > n && String.sub header 0 n = prefix then
    Some (String.sub header n (String.length header - n))
  else None

(* Pure and total, so the policy can be tested without a server. [token] is
   [None] when no token is configured, which Server_config only permits on a
   loopback bind -- reaching the socket then already requires being on the box. *)
let authorize ~(token : string option) ~(target : string)
    ~(authorization : string option) : decision =
  if target = health_path then Allow
  else
    match token with
    | None -> Allow
    | Some expected -> (
        match authorization with
        | None -> Deny "missing Authorization header"
        | Some header -> (
            match bearer_of_header header with
            | None -> Deny "Authorization header is not a Bearer token"
            | Some presented ->
                if constant_time_equal presented expected then Allow
                else Deny "invalid token"))

(* The reason is logged, never returned: telling a caller which of "no header",
   "wrong scheme" and "wrong token" applied is free reconnaissance. *)
let middleware ~(token : string option) inner req =
  match
    authorize ~token ~target:(Dream.target req)
      ~authorization:(Dream.header req "Authorization")
  with
  | Allow -> inner req
  | Deny reason ->
      Dream.log "auth: rejected %s: %s" (Dream.target req) reason;
      Dream.respond ~status:`Unauthorized ""
