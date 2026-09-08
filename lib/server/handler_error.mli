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
  | Not_ready of string
      (** The box is not in a state to serve: something the orchestrator needs
          before it can act on anything -- the Docker socket, the crontab spool,
          the diagnostic sink -- is not usable. Distinct from
          {!Orchestrator_failure}, which is a fault while carrying out a request
          on a box that was otherwise able to serve, because the operator's next
          step differs: one is a machine to repair, the other a request to retry
          or a log to read. *)

val message : t -> string
(** The human-readable half of a failure, without its classification. Never
    contains a value taken from the rejected payload: payloads carry environment
    variables and sink URLs that may embed credentials, and this text is
    returned over HTTP, mailed by cron, and shipped off the box with the
    diagnostics stream. *)

val http_status : t -> Dream.status
(** The HTTP status for a failure class: 400 for {!Invalid_request}, 500 for
    {!Orchestrator_failure}, 503 for {!Not_ready}. Kept beside the variant so
    that the handler is left with no decision of its own.

    {!Not_ready} is given a status even though no route returns it today. That
    is the point of choosing both answers from one variant: the class exists, so
    its status is picked deliberately now rather than defaulted inside whichever
    handler first returns it. *)

val exit_code : t -> int
(** The process exit code for a failure class, chosen from the same variant as
    {!http_status} and kept beside it, so that adding a class forces both
    answers to be picked rather than one of them defaulted inside a handler.

    Never 0, never 255, never 128 or above, and never 123 to 125. The client
    reads 255 as ssh's own failure and 128 plus n as a signal, so a verdict from
    the server landing on either is reported to the operator as a different kind
    of event than it is; 123 to 125 are cmdliner's own codes for an argument
    error, which would report a machine fault as a mistyped command; and 0 would
    report a failure as a success.

    Distinct per class, so that the code alone answers which class occurred. *)

val exit_documentation : (int * string) list
(** Every code {!exit_code} can leave behind, each paired with the sentence an
    operator reads beside it.

    It exists because [--help] is the only place an operator meets this table,
    and a command-line library documents its own exit statuses and no others
    unless it is handed these. Derived from {!exit_code} applied to every class
    rather than written out a second time, so the numbers in the manual cannot
    drift from the numbers the process leaves behind; the sentences are chosen
    per class by an exhaustive match, so a class added later is asked for one.

    Never contains 123 to 125 or 0, for the reason {!exit_code} gives: those are
    the command-line library's own and are documented by it, beside these. *)
