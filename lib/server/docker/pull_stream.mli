(** Whether an image pull succeeded, read from the body the Docker Engine
    streams back for [POST /images/create].

    The engine answers a pull with HTTP 200 before it has fetched anything, so
    the status says nothing about the outcome. A layer the registry cannot serve
    surfaces only in the body. The body is newline-delimited JSON, one
    [CreateImageInfo] object per line (Engine API v1.47), and a failure is an
    object carrying [error] (deprecated) and [errorDetail], whose [message] says
    what went wrong. *)

val verdict : string -> (unit, string) result
(** Read a pull's whole body, in order. The first object carrying [error] or
    [errorDetail] fails the pull, and the message carries the engine's
    [errorDetail.message], or [error] when the detail has none.

    A line that is not a JSON object fails the pull too, carrying the line,
    bounded. A pull whose outcome cannot be read is not reported as a success: a
    body with no error line must still end with the engine's terminal
    [Status: ...] line, so an empty or cut-off body fails. *)
