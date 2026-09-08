(** The bytes a subcommand exchanges with its caller, and the code it leaves
    behind.

    Four subcommands carry the same shape: take the input the caller supplied --
    for [deploy] and [run] the payload on standard input, for [status] and
    [check] an argument -- hand it to the body behind the subcommand, then write
    that body's answer on standard output and its failure on standard error and
    report which happened through the process exit code. The shape is lifted
    here rather than written out four times because the fourth occurrence is
    what makes a lift correct and because the part most easily got wrong --
    which code a failure exits with -- must have exactly one answer for all
    four.

    Three of them answer a request and so write standard output on success
    alone: {!status_of}. [check] answers a diagnosis of the box, whose failing
    form is the one a program acts on, so it writes its document on both arms:
    {!diagnostic_of}. Both leave a failure through {!fail}, which is where the
    message, the stream it lands on and the code it returns are decided once --
    and is why [serve], which has no document of any kind, needs no copy of that
    write of its own.

    The streams are this process's own, not parameters. The caller is a shell
    reading file descriptors 1 and 2, so a signature taking streams would be a
    different contract than the one that ships; a test captures the descriptors
    instead. *)

val read_stdin : unit -> string
(** Every byte on standard input, up to end of file.

    Whole-stream rather than line-oriented: a deploy or run payload is JSON that
    contains newlines, and a read that stopped at the first one would truncate
    the payload into something that fails to decode with no sign of why.

    Payloads arrive here rather than in argv because they carry registry
    credentials, environment variables and sink URLs, and argv is readable by
    every process on both machines. *)

val emit : Yojson.Safe.t -> unit
(** Write one JSON value to standard output and flush it.

    Exactly the bytes [Yojson.Safe.to_string] produces, with nothing appended --
    no trailing newline. A subcommand's stdout is the same bytes the
    corresponding route puts in its response body, produced by the same encoder,
    because two callers of one decision that disagree on its representation are
    two decisions. *)

val fail : Handler_error.t -> int
(** [fail error] writes {!Handler_error.message} of [error] and a newline to
    standard error, flushes it, and returns {!Handler_error.exit_code} of the
    same value.

    It writes standard error and nothing else, which is what lets a caller with
    no JSON answer use it: serving successfully produces no document, and a
    failure path that went through {!status_of} would have to invent an encoder
    for a value that does not exist. Every failing subcommand -- and the serve
    action, which is not one -- leaves its message through this one function, so
    a prefix, a severity marker or a change of terminator is one change rather
    than a change per caller that one caller misses.

    No mapping of its own is introduced here: the code is
    {!Handler_error.exit_code} applied to the class that also chose the HTTP
    status. {!Handler_error.message}'s contract holds unchanged -- the text
    never echoes a value taken from the rejected payload -- and writing it to a
    local stream rather than an HTTP response does not relax that, since the
    stream is read by whoever ran the subcommand and, for a cron line, mailed.
*)

val status_of :
  ('a, Handler_error.t) result -> encode:('a -> Yojson.Safe.t) -> int
(** [status_of result ~encode] writes [result] where its caller reads it and
    returns the process exit code: {!emit} of [encode value] and 0 for an [Ok],
    or the failure's {!Handler_error.message} on standard error and
    {!Handler_error.exit_code} for an [Error].

    The code comes from {!Handler_error.exit_code} applied to the same variant
    that chose the HTTP status, and this function introduces no mapping of its
    own. That is the whole mechanism: a failure class added to the variant makes
    both answers get picked together instead of one of them being defaulted
    inside whichever caller returned it first.

    It returns the code rather than calling [exit], and the distinction is not
    stylistic: [Stdlib.exit] terminates the process where it stands, so an exit
    taken inside an [Eio.Switch.run] skips every [on_release] the switch holds.
    [observed -- 2026-09-06] Against eio 1.3 on OCaml 5.3, a program that
    registers
    [Eio.Switch.on_release sw (fun () -> print_endline "ON_RELEASE RAN")] and
    then calls [exit 7] inside the switch prints nothing and leaves status 7;
    the release handler does not run. So the process exits once, at top level,
    outside [Eio_main.run].

    What is {e not} the reason, because it was checked and is false: [exit] does
    not raise [Stdlib.Exit] and is therefore not swallowed by a [with exn ->]
    catch-all. [observed -- 2026-09-06]
    [try exit 7 with Stdlib.Exit -> ... | exn -> ...] under OCaml 5.3 runs
    neither handler and exits 7. It is recorded here because that belief is
    common enough to be worth refuting once.

    The two streams are never both written, so nothing here can interleave them.
    {!Handler_error.message}'s contract holds unchanged: the text never echoes a
    value taken from the rejected payload, and writing it to a local stream
    rather than an HTTP response does not relax that -- the stream is read by
    whoever ran the subcommand and, for a cron line, mailed. *)

val diagnostic_of :
  (unit, Handler_error.t) result -> document:Yojson.Safe.t -> int
(** [diagnostic_of verdict ~document] writes [document] to standard output
    whichever way [verdict] went, then returns 0 for an [Ok] or hands the
    failure to {!fail} for an [Error] -- its message on standard error, and
    {!Handler_error.exit_code} of its class as the result.

    This is {!status_of}'s shape for a subcommand whose answer is a diagnosis
    rather than the outcome of a request. [check] reports what it observed of
    this box, probe by probe; a not-ready box is precisely the state a caller
    acts on, so a write that put the document on standard output only when every
    probe passed would leave the machine-readable form of a failure -- every
    failing probe, named, in one document -- reachable from no caller. The prose
    on standard error is what an operator reads; it is not a substitute for a
    document a script can compare.

    The two streams carry different readers and are never mixed: [document] goes
    to standard output alone, the reasons to standard error alone, and {!emit}
    flushes before {!fail} writes. The exit code is {!fail}'s, so this
    introduces no second mapping -- a failure class added to the variant is
    picked up here by having been picked up there. *)
