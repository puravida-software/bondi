(** How a mustache library error is turned into the sentence an operator reads.

    [bondi.yaml] is a mustache template filled in from the environment before it
    is parsed, and the library refuses it with an error value of its own
    carrying the position and the name of what went wrong. That description is
    the whole of what has to be said; all this module does is print it.

    It prints it through a formatter with the margin opened up, because the
    library's printers write inside a box: at the default margin the sentence
    breaks at a point that moves with the length of the variable's name, and
    where a refusal wraps is the terminal's business rather than a library's.

    Pure: it reads nothing, prints nothing to any channel and performs no I/O.
*)

val message : pp:(Format.formatter -> 'a -> unit) -> 'a -> string
(** [message ~pp error] is [error] rendered by [pp] on one line.

    [pp] is one of the library's own printers -- [Mustache.pp_render_error] for
    a placeholder no exported variable answers,
    [Mustache.pp_template_parse_error] for a template whose syntax is malformed.
    Both have this shape, and neither flushes the formatter it is given, so this
    function flushes it. *)
