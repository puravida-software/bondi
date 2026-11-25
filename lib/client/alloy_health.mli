(** Whether an Alloy that setup has just started answers healthy on the box's
    loopback.

    [docker run -d] succeeds as soon as the container exists, so it says nothing
    about whether Alloy came up. An Alloy whose HTTP server cannot bind its port
    exits at start, and a setup that only ran the container would report that
    exit as a started sidecar. Asking Alloy's own [/-/healthy] is what turns it
    into a failure.

    The question is asked with the host's [curl], from the host, because the
    address Alloy listens on is the host's loopback and nothing else reaches it.

    This module performs no I/O. The caller runs {!probe_command} on the server
    over SSH and brings the answer here. *)

(** What the host said about Alloy's health. *)
type verdict =
  | Healthy  (** Alloy answered its [/-/healthy] with success. *)
  | Never_healthy of { port : int }
      (** Nothing answered healthy at [127.0.0.1:port] before the probe's bound
          passed. *)
  | Unhealthy of { body : string }
      (** Alloy answered HTTP 500 and never answered 200 before the bound
          passed. [body] is what Alloy said, which names the failing component.
          Alloy is up, so this blames no port. *)
  | Curl_missing
      (** The host has no [curl] on its [PATH], so nothing was asked. This is
          never a timeout: the port was not tried. *)
  | Unreadable of Host_answer.t
      (** The probe ran and printed no verdict. Nothing about Alloy was
          established, so this is no pass and names no cause. *)

val wait_seconds : int
(** [wait_seconds] is how long setup gives a started Alloy to answer healthy. It
    is a ceiling for a loaded box, not a prediction of the wait. Alloy v1.8.0
    with a config of one block answered within about 1 s of [docker run]
    [observed -- 2026-11-24, Docker Engine 29.10.0]. The generated config was
    never timed on its own: a slower start is assumed, not measured. *)

val probe_command : port:int -> timeout_s:int -> string
(** [probe_command ~port ~timeout_s] is one remote shell command. It polls
    [http://127.0.0.1:port/-/healthy] with the host's [curl] until Alloy answers
    with success or [timeout_s] seconds have passed on the host's clock, and
    prints which happened as one marker line. When the last answer seen was HTTP
    500, the marker line is followed by the body Alloy gave. It checks for
    [curl] first and prints a marker of its own when there is none.

    It always makes the first attempt, and caps each attempt at 2 s, so a
    listener that accepts and never answers (another process holding the port)
    cannot hold one attempt for the whole bound. The bound can be overrun by at
    most one capped attempt.

    It always exits 0, so a non-zero exit means the command could not be run,
    which is a failure of the SSH call and never a verdict. *)

val verdict_of_probe : port:int -> Host_answer.t -> verdict
(** [verdict_of_probe ~port answer] reads {!probe_command}'s answer. [port] is
    the port the probe asked, carried into {!Never_healthy}. The trimmed answer
    is compared with each marker exactly. An answer that is none of them,
    including an empty one, is {!Unreadable}. *)

val require_healthy : verdict -> (unit, string) result
(** [require_healthy verdict] is [Ok ()] for {!Healthy}. Every other verdict is
    the sentence setup fails with. {!Unhealthy}'s quotes Alloy's body and names
    no port. {!Never_healthy}'s names the port and says another process may hold
    it. {!Curl_missing}'s says curl is missing and names no port.
    {!Unreadable}'s quotes what the host said. *)
