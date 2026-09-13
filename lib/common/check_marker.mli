(** The line the readiness check writes to its diagnostic sink.

    Three parties have to agree on this string and none of them can detect a
    disagreement on its own: the process that writes the line to the sink, the
    image gate that proves a line written there comes back out of the
    container's log stream, and a client that reads the log stream back to
    establish that the container it just started can be seen. A writer whose
    spelling has drifted still writes successfully, and a reader whose spelling
    has drifted simply never matches and reports the observability it was
    checking as absent.

    It lives in the shared library rather than beside its writer because the
    client library may not depend on the server's. *)

val diagnostic_sink : string
(** The line written to the diagnostic sink, carrying no terminator of its own.
    The writer appends one, and a reader matching a value that already ended in
    a newline would be matching a doubled newline that no line of the stream
    carries. *)
