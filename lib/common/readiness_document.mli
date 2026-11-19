(** The document the server's [check] subcommand writes on stdout, read back.

    The server writes it and the client decides from it whether a box is ready
    to deploy to. Neither end can see the other drift: a writer that renamed a
    key still writes successfully, and a reader that accepted any answer would
    report a box ready on the strength of output it never understood. So the
    reading is strict, and a test on the server's side decodes the server's own
    output with this decoder, which is where a drift between the two would
    surface.

    It lives in the shared library rather than beside its writer because the
    client library may not depend on the server's. *)

type t
(** A readiness document as the server writes it: [ready] and [probes] are both
    present, and nothing else is. *)

val of_string : string -> (t, string) result
(** [of_string text] decodes [text] as a readiness document.

    It refuses text that is not JSON, a value that is not an object, an object
    whose keys are not exactly [ready] and [probes], a [ready] that is not a
    boolean, and a [probes] that is not a list. A key added to the document is
    therefore a breaking change: every older client refuses it. That is safe
    only because setup pins the server image to the client's version. The
    entries of [probes] are not read: they say why a box is not ready, and
    [ready] is the verdict.

    The error names what was wrong and carries the rejected text, flattened to
    one line and bounded, because the text is the only evidence of what the box
    actually answered. *)

val quote : string -> string
(** [quote text] is [text] as it is carried in a reason: flattened to one line,
    because a reason is printed on one line of a terminal, and bounded, because
    an answer is free text whose length its writer chose. The bound is a
    judgement rather than a measurement: a document the server writes names a
    handful of probes, each with a short reason, and fits well inside it. The
    decoder's refusals and the client's report of a document that said no both
    quote through this, so the two cannot drift. *)

val ready : t -> bool
(** [ready document] is the document's [ready] flag. *)
