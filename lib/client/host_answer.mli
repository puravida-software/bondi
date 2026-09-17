(** What a host said about its own state, on its way into a report this client
    prints.

    A type of its own rather than a [string], because the rule the setup account
    is held to is a rule about provenance: a value the host reported about
    itself may be printed, a value this client read out of a [bondi.yaml] or
    carries as a credential may not. A [string] parameter cannot tell those two
    apart — every value in this client is one — so the places that put a host's
    words into the account name this type instead, and the one constructor below
    is the only way to obtain one.

    What that buys, said exactly: handing a declared value to a [string]
    parameter type-checks and reads like every other call; handing one to
    {!of_host_output} has to be written out in full, at a call site named after
    the boundary it is claiming to be. The guarantee is that the claim is
    nominal and conspicuous, not that it cannot be made — {!of_host_output}
    checks nothing about where its argument came from, because there is nothing
    in a string to check. What is genuinely impossible is elsewhere: the
    account's subjects are derived from the site rather than passed in, so no
    caller supplies one at all. *)

type t
(** A host's own answer, flattened and bounded, ready to be read into a line of
    a report. Abstract: what it holds is whatever {!of_host_output} was given,
    reshaped, and there is no other way to make one. *)

val of_host_output : string -> t
(** What a host wrote on standard output, taken as its answer about itself.

    This is the boundary: the one place a plain string becomes a host's answer,
    and so the one place to look when asking where a printed value came from.

    The answer is flattened onto one line and bounded here, as it enters, rather
    than at each place that renders it — a host writes on however many lines it
    likes, and it chose the length. An over-long answer is carried cut, with how
    many bytes there were, rather than replaced: this is log hygiene and not
    redaction, and the answer is the only thing in a line that says what the box
    actually reported. *)

val to_string : t -> string
(** The carried answer, as a line of a report reads it: one line, within the
    bound {!of_host_output} applied. *)
