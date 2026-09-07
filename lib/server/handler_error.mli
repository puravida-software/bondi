(** Why an endpoint did not produce a result.

    The classification is what both the HTTP status and the process exit code
    are chosen from, so it is a variant rather than a string: the caller's
    mistake and Bondi's own fault are not the same event and must not be
    reported as though they were. *)
type t =
  | Invalid_request of string
      (** The request could not be acted on as written -- a body that does not
          decode, or an image with no tag. *)
  | Orchestrator_failure of string
      (** Bondi could not carry out a well-formed request. *)

val message : t -> string
(** The human-readable half of a failure, without its classification. Never
    contains a value taken from the rejected payload: payloads carry environment
    variables and sink URLs that may embed credentials, and this text is
    returned over HTTP, mailed by cron, and shipped off the box with the
    diagnostics stream. *)

val http_status : t -> Dream.status
(** The HTTP status for a failure class: 400 for {!Invalid_request}, 500 for
    {!Orchestrator_failure}. Kept beside the variant so that the handler is left
    with no decision of its own. *)

val exit_code : t -> int
(** The process exit code for a failure class, chosen from the same variant as
    {!http_status} and kept beside it, so that adding a class forces both
    answers to be picked rather than one of them defaulted inside a handler.

    Never 0, never 255, and never 128 or above. The client reads 255 as ssh's
    own failure and 128 plus n as a signal, so a verdict from the server landing
    on either is reported to the operator as a different kind of event than it
    is, and 0 would report a failure as a success. *)
