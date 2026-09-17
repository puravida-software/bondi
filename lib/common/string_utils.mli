(** String primitives shared across the client and the server.

    Everything here is a search or a reshaping of a string and nothing here
    performs I/O. The module exists so that these do not get written a second
    time inside whichever module needed one first: a substring search
    reappearing privately in three modules is three places for the same
    off-by-one. *)

val index_of : needle:string -> string -> int option
(** [index_of ~needle hay] is the offset of the first occurrence of [needle] in
    [hay], or [None] when it does not occur.

    An empty needle occurs at the start, which is the same answer {!contains}
    gives it. *)

val contains : needle:string -> string -> bool
(** [contains ~needle hay] is whether [needle] occurs anywhere in [hay].

    This is {!index_of} with the offset discarded. Callers that go on to read
    what follows the match want the offset and should ask for it directly:
    searching twice for the same needle is how the two answers come to disagree.
*)

val last_index_of_char : string -> char -> int option
(** [last_index_of_char value char] is the offset of the last occurrence of
    [char] in [value], or [None] when it does not occur.

    Searching from the end rather than the start, because the callers that need
    it are splitting on a separator that legitimately appears earlier in the
    same string — an image reference's registry port before its tag, a path's
    directories before its final segment. *)

val single_line : string -> string
(** [single_line message] is [message] with every run of whitespace collapsed to
    one space and the ends trimmed.

    A message that came from a host or a transport is free text, and several of
    them arrive across more than one line. Anything rendering such a message in
    a fixed-width cell needs it on one line: the tail of a two-line message
    lands in whatever column follows and reads as a separate entry, which is
    worse than the message being long. *)

val starts_with : prefix:string -> string -> bool
(** [starts_with ~prefix value] is whether [value] begins with [prefix].

    An empty prefix is a prefix of everything, and a prefix longer than the
    value is a prefix of nothing. *)

val has_control_char : string -> bool
(** [has_control_char value] is whether [value] contains a C0 control character
    or [DEL].

    It is the rule the line-oriented formats Bondi writes are checked against: a
    [KEY=VALUE] environment file has no quoting syntax, so a control character
    in a value is not data but a second record. Callers reject rather than
    escape, and each phrases its own message, because the value under inspection
    is often a credential that must not appear in one. *)

val bounded : limit:int -> string -> string
(** [bounded ~limit value] is [value] when it is [limit] bytes or fewer, and
    otherwise as much of it as fits followed by
    [" ... (truncated, N bytes in all)"], where [N] is the whole length of
    [value].

    One rendering of a cut rather than one per module that needed a bound. The
    size is the only thing a caller chooses, and it chooses it for its own
    reasons — a payload carrying a failed [docker logs] and a payload carrying a
    file mode are not cut to the same length — but the notation an operator
    learns to read is then the same notation wherever this tool cut, which is
    what a copy of the [Printf] call at each site could only assert.

    The cut lands on a codepoint boundary, so a value that is not ASCII is
    carried short rather than carried broken: a byte offset can fall inside a
    multi-byte sequence, and the half left behind is a replacement character in
    whatever reads the line. The count stays in bytes, because bytes are what
    the bound is in. A value that is not valid UTF-8 has no boundaries to find
    and is cut at [limit]. *)
