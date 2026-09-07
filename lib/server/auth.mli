(** Bearer-token authorisation for the orchestrator API.

    The API can start a container with the host Docker socket mounted, which
    makes reaching it equivalent to root on the box. [Server_config] defaults
    the bind interface to loopback and refuses to start on a public interface
    without a token; this module is what makes that token mean something.

    [GET /api/v1/health] stays unauthenticated on purpose: [bondi setup] probes
    it from inside the orchestrator container with busybox wget, which has no
    way to carry a header, and the response is an empty 204 that discloses
    nothing. Every other route -- including [/status], which lists image names
    and tags -- requires the token.

    The policy is a pure function ({!authorize}) with a thin Dream middleware
    over it ({!middleware}), so what the API allows is testable without a
    server. *)

(** What the policy decided about one request. *)
type decision =
  | Allow  (** The request may reach the handler. *)
  | Deny of string
      (** The request is refused, with the reason for the operator's log. The
          reason is never returned to the caller: telling one which of "no
          header", "wrong scheme" and "wrong token" applied is free
          reconnaissance. *)

val constant_time_equal : string -> string -> bool
(** Compare two strings without an early exit, so the time taken does not reveal
    how many leading bytes of a guess were correct. Lengths are compared first
    and that difference is observable, which is accepted: tokens are
    fixed-length and the length of a secret is not the secret. *)

val authorize :
  token:string option ->
  target:string ->
  authorization:string option ->
  decision
(** Decide one request from the configured token, the request target and the
    [Authorization] header. Pure and total, so the policy is tested without a
    server.

    The health target is allowed whatever the header says. [token] is [None]
    when none is configured, which [Server_config] permits only on a loopback
    bind -- reaching the socket then already requires being on the box -- and
    everything is allowed. Otherwise the header must be present, must carry the
    [Bearer] scheme, and must present the configured token compared by
    {!constant_time_equal}; each of those three failures denies with its own
    reason. *)

val middleware : token:string option -> Dream.middleware
(** Apply {!authorize} to every request in the scope it wraps. An allowed
    request reaches the inner handler unchanged; a denied one is answered 401
    with an empty body, and the reason {!authorize} gave is written to
    diagnostics rather than returned.

    This is a middleware and not a route, so the 401 it chooses is the one
    status in the server that does not come from [Handler_error]: there is no
    endpoint body here to hand a failure value back to. *)
