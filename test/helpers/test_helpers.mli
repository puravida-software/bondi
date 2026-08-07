(** Assertion helpers shared by every test executable.

    Each of these was written privately in a test file first and then written
    again in the next one; a substring check is small enough that copying it
    reads as cheaper than sharing it, and eight copies later the cost is that a
    weak assertion cannot be strengthened in one place. *)

val contains : needle:string -> string -> bool
(** [contains ~needle hay] is whether [needle] occurs anywhere in [hay].

    A raw substring test. Prefer {!contains_word} for any needle that is a
    prefix of another word the same code can render. *)

val contains_word : word:string -> string -> bool
(** [contains_word ~word hay] is whether [word] occurs in [hay] delimited by
    whitespace or by either end of the value.

    The check {!contains} cannot make. Rendered output is full of words that
    contain other words — ["healthy"] inside ["unhealthy"], ["read"] inside
    ["unreadable"] — so an undelimited assertion on the shorter one passes
    against output rendering the longer, which is exactly the inversion the
    assertion was written to catch. *)
