(** Whether the orchestrator a [bondi setup] just started is actually serving.

    [docker run -d] answers with a container id as soon as the container has
    been created. It says nothing about whether the process inside survived, so
    a server that aborts on startup — a missing shared library stops the musl
    loader before [main] and exits 127 — was reported as a successful setup
    while the host was left with no orchestrator at all. Every scheduled job on
    the box then fired into nothing and said nothing about it.

    This module turns "did it start" into "is it answering". It performs no I/O:
    the caller runs the commands declared here on the server over SSH and brings
    each outcome back to the decision function that reads it, in the same shape
    as {!Curl_version}. *)

val running_attempts : int
(** How many one-second attempts {!running_command} makes before it gives up on
    a container that has not reached a running state.

    It is a bound on how long a healthy but slow host is given, not a wait to
    expect: a container that is going to start does so within a second or two,
    and the rest of the count exists for the host that is paging, pulling or
    otherwise busy. A caller that wants a different bound passes one. *)

val log_lines : int
(** How much of a container's log stream is read back: by {!diagnostics_command}
    when a reading was refused, and by the caller establishing that the line the
    check writes to its diagnostic sink reached the stream.

    One number, and one spelling of it. The diagnostics read announces the bound
    in a banner above the lines it then asks docker for, and a banner saying
    fifty above twenty-five lines misreports what an operator is looking at on
    the one run where any of this is read.

    Bounded, because the line a caller looks for was written moments ago and an
    unbounded read pulls a busy orchestrator's whole history across the
    connection to find it. Not bounded to one or two lines either: an
    orchestrator that is serving writes lines of its own between the check
    answering and the read being taken, and a bound tight enough for them to
    push the marker out would report a healthy container as one whose
    diagnostics never arrive. *)

val running_command : container_name:string -> attempts:int -> string
(** The shell command that waits on the host for [container_name] to reach a
    running state, for at most [attempts] one-second attempts.

    The bound is a required argument rather than a value this function reaches
    for, so a caller waiting for a different length of time has to say so; the
    container name is required for the same reason, because nothing below this
    signature knows which container the caller started.

    It exits 0 as soon as the container reads as running and non-zero otherwise,
    with a sentence on standard error saying which of the two happened. The
    status is the answer because the transport preserves it, and because the
    alternative -- a marker on standard output beside a status that always says
    0 -- gives a reader two things that can disagree and no rule for which to
    believe when they do.

    The name is quoted for the host's shell wherever it stands, the two
    sentences included, because it is a caller's string reaching a shell: one
    holding a quote would break the command and one holding [$] or a backtick
    would be evaluated on the host.

    It stops early when the container is not present at all: one that has been
    removed will not come back, and an operator should not wait out the bound to
    be told so. A container that is present but not yet running keeps the loop,
    because a container being restarted under a restart policy passes through
    exactly that state on its way up. *)

val check_command : container_name:string -> cron_configured:bool -> string
(** The shell command that asks the server inside [container_name] whether the
    box it is on is in a state to serve.

    It runs the server's own check subcommand inside the container that was just
    started, rather than fetching a health endpoint over a published port. The
    endpoint answers 204 and says nothing, so a rejection obtained that way
    names no fault, where the subcommand names every probe that failed. It also
    needs no fetch tool inside the container and no port published outside it.

    {b The reading is taken once, after the wait, and never by looping this
       command until it passes.} The check acts on the box on every invocation:
    it writes a line to the container's log stream, and where cron is configured
    it touches the spool the host's cron daemon watches. Those costs are paid
    once by a single reading and once per tick by a loop, and the wait is what
    makes one reading enough.

    [cron_configured] says whether cron is converged on the host this container
    runs on -- which is what decides whether the crontab spool must be writable,
    and whether the lines in it are worth comparing against the deployment, for
    the box to be ready. The container cannot soundly infer any of that about
    itself, so it is told.

    It is the caller's answer and not only its configuration's: a host declaring
    no job while its crontab still holds a Bondi section keeps that section's
    spool and payload all the same, and is the likeliest of any box to be
    holding a line for a job nothing declares any more. A caller that asked only
    what the configuration declares would leave exactly that box unprobed.

    The command leaves the container's error stream where it is. The subcommand
    writes its observations to standard output and its reasons to standard
    error, and the transport already merges the two on a non-zero status, which
    is the only outcome the reasons are wanted for. Merging them in the command
    would put prose into the document on the path where the document is read. *)

val log_stream_command : container_name:string -> lines:int -> string
(** The shell command that reads the last [lines] of [container_name]'s log
    stream, both of its streams together.

    It is how a caller outside the container establishes what no probe inside it
    can: that a line the server wrote to its diagnostic sink actually reaches
    the stream an operator and a log shipper read. A sink can take bytes and
    report that it did while the stream downstream of it carries nothing.

    Both streams are collected because the diagnostics are written to standard
    error. The read is bounded because the line being looked for was written
    moments ago, and an unbounded read pulls a busy orchestrator's whole history
    across the connection to find it. *)

(** What the box said when it was asked whether it can serve.

    Three outcomes rather than a [(unit, string) result] with two, because a
    check that ran and said no and a check that produced no reading at all send
    an operator to different places: the first to the machine, the second to the
    key, the address or the container. A caller holding a [result] can only
    collapse them, and the sentence it would collapse them into is the one that
    has to differ. *)
type verdict =
  | Serving  (** The box was asked and answered that it can serve. *)
  | Not_ready of string
      (** It was asked, and it named faults. The payload is the box's own
          account of them, which is the half of the answer an operator acts on.
      *)
  | Unreachable of string
      (** No reading was obtained, and this is what happened instead. *)

val verdict_of_output : (string, Remote_exec.failure) result -> verdict
(** Decide, from the outcome of running {!check_command}, what the box said.

    The exit status is the verdict, which is a change from how this module used
    to read its answer and is worth saying why. The transport now preserves the
    remote status as a value rather than flattening it into a sentence, and the
    server binary maps its failure classes to codes in exactly one place -- so
    the status arrives intact and means one thing. A second classification built
    by parsing the document would be a second mapping of the same failure
    classes, and two mappings of one thing can disagree with no rule for which
    to believe.

    The document alone would not do, either. A process that dies before its
    entry point -- a missing shared library stops the loader before [main] --
    leaves a status and no document at all, and that is precisely the failure
    this module exists to catch. A reader that needed a document to reach a
    verdict would have none to read on the one case that matters most.

    So: the status the readiness class leaves behind is the box reporting its
    own faults, and the reason carries what came back, document and all. Any
    other non-zero status is a reading that was not taken -- the command ran and
    something other than the check answered, or nothing ran at all -- and each
    such reason names which happened. An answer that exited cleanly but wrote
    nothing is a rejection rather than a pass: the subcommand writes its
    document whichever way its verdict goes, so a silent success is not the
    check having answered, and reading it as one is the defect this module
    exists to prevent. *)

(** What the container's log stream had in it.

    Three outcomes, and the middle one is why: a stream that came back without
    the marker is a different fact from a stream that could not be read, and
    folding silence into unreadability would report a container whose
    diagnostics never arrive as a container nobody managed to ask. The first is
    a deployment that has lost its observability and must fail; the second is a
    reading to retry or a transport to fix. *)
type log_stream =
  | Carrying  (** The marker was in the lines that came back. *)
  | Silent
      (** The lines came back and the marker was not among them, the empty
          stream included. *)
  | Unreadable of string  (** The lines did not come back, and this is why. *)

val log_stream_of_output : (string, Remote_exec.failure) result -> log_stream
(** Decide, from the outcome of running {!log_stream_command}, whether the line
    the server wrote to its diagnostic sink reached the stream an operator and a
    log shipper read.

    The marker is the one the server writes on every check, taken from the
    shared library both ends spell it in, so what is asserted is the path the
    deployed orchestrator actually takes rather than a line written for the
    assertion's benefit. The read succeeding is not the question -- a container
    that logged nothing answers a successful read with an empty stream, which is
    {!Silent}. *)

val diagnostics_command : string
(** The shell command that collects what the operator needs to diagnose an
    orchestrator that did not come up: the container's final state and exit
    code, followed by its last {!log_lines} log lines, under a banner naming
    that same number. Run only after a rejected reading. *)

val failure_message :
  ip_address:string ->
  image:string ->
  reason:string ->
  diagnostics:string ->
  string
(** The operator-facing report for an orchestrator that did not come up.

    Names the server and the image that failed, why the reading rejected it, and
    quotes the server's own account of the failure — the container's exit code
    and logs, obtained with {!diagnostics_command} — so the cause is readable
    without logging into the host. *)
