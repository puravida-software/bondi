(** Best-effort outbound delivery of planned alerts over validated TLS.

    This is the sole impure half of alerting: {!Bondi_common.Alert} decides
    {e whether} and {e where} to alert with plain data, and this module performs
    the actual HTTPS POST. Delivery is best-effort — a sink that is down, slow,
    erroring, or returning a non-2xx status is logged and dropped, never
    propagated — so a side channel can never change the outcome of the job it
    reports on. It runs after that outcome is recorded and each attempt is
    bounded by a fixed timeout, so a slow sink can at most delay the run's
    acknowledgement, never its result (FR-6).

    Outbound TLS is validated against the operating system's trust store rather
    than disabled; {!make_https} is the seam that keeps a silent TLS-off
    regression ([~https:None]) from compiling past this module (FR-5). *)

type https
(** A validated outbound TLS handler built from the system trust store.
    Abstract: constructed only by {!make_https}, so every sink request is
    wrapped in a real certificate-validating handler and a delivery client can
    never be built with TLS silently disabled. *)

(** Why {!make_https} failed: the system trust store could not be loaded or the
    TLS client configuration was rejected. Carries a diagnostic message. *)
type error = Tls_setup of string

val make_https : unit -> (https, error) result
(** Build the outbound TLS handler from the operating system's trust store via
    [ca-certs], without [Result.get_ok]. An [Ok] result proves the certificate
    bundle loaded and that every sink request will be wrapped in a validating
    TLS handler rather than [~https:None] (FR-5). Intended to be called once at
    server startup. *)

val is_success_status : int -> bool
(** Whether an HTTP status code counts as a delivered alert: only 2xx. Every
    other status is logged as a delivery failure, since Bondi ascribes no finer
    meaning to a sink's response (FR-3). *)

val deliver :
  https:https ->
  net:_ Eio.Net.t ->
  clock:_ Eio.Time.clock ->
  targets:Bondi_common.Alert.sink list ->
  payload:Bondi_common.Alert.payload ->
  unit
(** Best-effort delivery: POST [payload] as JSON to every target in [targets]
    concurrently, each attempt bounded by a fixed timeout. A target that is
    down, slow, times out, or returns a non-2xx status is logged by host only —
    the full sink URL, which may embed a credential, is never logged — and then
    ignored. Never raises, and returns no result a caller can act on, so a
    delivery outcome cannot reach the job path (FR-6). *)
