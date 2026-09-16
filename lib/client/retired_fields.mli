(** What a manifest is refused for when it declares a key Bondi has retired.

    A retired key is one Bondi once read and has since removed from its
    configuration record. Parsing is strict, so a manifest that still declares
    one stops parsing altogether -- and the decoder cannot say which key did it:
    it discards the unrecognised member before building its error and reports
    the name of the type it was decoding. An operator upgrading into that
    refusal is told a type name and left to guess the line they wrote.

    This scan runs on the untyped document, before and instead of asking the
    decoder, which is the only place the key is still visible.

    The module answers rather than prints, so the placement of the refusal is a
    property of the call site and can be tested there. *)

val check : Yojson.Safe.t -> (unit, string) result
(** [check json] is [Error message] when [json] declares a key Bondi once read
    and has since removed, and [Ok ()] otherwise.

    The message names every retired key the document declares -- not only the
    first -- so the operator edits the file once, and says for each what to do
    about it. A retired token's message says to rotate as well as to remove: a
    credential that sat in a configuration file is compromised whether or not
    anything still reads it.

    An unknown key Bondi never had is not this module's subject. It still
    reaches the decoder, which answers with the name of the type it was decoding
    rather than the name of the key.

    Pure: it reads nothing, prints nothing and performs no I/O. *)
