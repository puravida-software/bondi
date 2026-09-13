(** The command surface of the server binary.

    The binary is a group of subcommands rather than a single program, so that
    every decision the server makes is reachable over the one transport a caller
    actually has: a [docker exec] into the container the binary runs in, reached
    from a client over SSH or from the host's own crontab. This module builds
    that group and evaluates it; it owns no decision of its own beyond which
    exit code a failure leaves behind, and that it takes from {!Handler_error}.
*)

val eval : unit -> int
(** Evaluate the command group against this process's arguments and return the
    exit code the process should leave behind.

    {b An empty argument list idles.} This is a contract, not a convenience: the
    image's [ENTRYPOINT] is the bare binary and the command that starts an
    orchestrator passes no arguments at all, so a group that printed help and
    exited non-zero on empty argv would stop every orchestrator already deployed
    from starting. What the empty list reaches has changed -- it evaluated
    [serve] while there was an HTTP surface to serve -- and the contract has
    not: the bare binary stays up and leaves this process to be stopped from
    outside. The behaviour is a single labelled argument inside this module and
    reads as identical to a group that omits it, so it is pinned by a test
    rather than by care.

    {b Stopped from outside means SIGTERM or SIGINT, and the idle this binds
       answers either by exiting 0.} Staying up is a refusal to fall through,
    not a refusal to stop: the idle installs a disposition of its own for both,
    because a process that is the init of a PID namespace has the kernel discard
    any signal still at its default action. Without them [docker stop] on the
    orchestrator waits out the daemon's entire stop timeout and ends in a
    SIGKILL, and a Ctrl-C forwarded to PID 1 by [docker run]'s [--sig-proxy]
    does nothing at all. The dispositions belong to this idle rather than to
    {!eval_argv}, which sets SIGPIPE and backtrace recording for the whole
    process: a subcommand runs for as long as its work takes and should die of a
    stop like any other program, while the idle is the only term with nothing to
    interrupt. A caller of {!eval_argv} supplying its own idle gets no such
    disposition and is not meant to.

    The subcommands are [deploy], [run], [status] and [check], and there is no
    [serve] among them. [deploy], [run] and [status] each write the answer of a
    transport-free body living in a module of its own, encoded by that module's
    own encoder, so no decision of theirs is taken here. [check] writes the
    observations it took, encoded by [Readiness.observations_to_yojson], and
    writes them whether or not the box was ready: the failing document is the
    one that names every probe that failed, and is the one a caller acts on, so
    withholding it would leave that report reachable from nothing. The reasons
    go to standard error beside it, where the operator reads them. All four exit
    with {!Handler_error.exit_code} applied to the class the body returned --
    one table, so no failure path exits 0 and no second mapping exists to
    disagree with the first. [deploy] and [run] read their payload from standard
    input and never from the command line, because a payload carries registry
    credentials and environment variables and argv is readable by every process
    on the box; [status] takes a service selector and [check] takes whether the
    deployment configures cron, neither of which is a credential.

    The code is returned rather than exited with, because the process must exit
    exactly once, at top level, outside any Eio switch: [Stdlib.exit] terminates
    where it stands and skips every [Eio.Switch.on_release] the switch holds.

    [--help] documents every code in {!Handler_error.exit_documentation} beside
    the command-line library's own, so the statuses an operator reads there are
    the statuses this binary leaves behind rather than only the three it never
    does. [--version] answers the [VERSION] the image was built with, read from
    the environment the Dockerfile's runtime stage publishes it in, and
    ["unknown"] where no release built the binary. *)

val eval_argv :
  idle:(unit -> unit) ->
  observe:(cron_configured:bool -> Readiness.observation list) ->
  argv:string array ->
  int
(** [eval_argv ~idle ~observe ~argv] is {!eval} with each of its inputs supplied
    instead of taken from the process, and with the same result: the exit code.

    It exists because the contracts above cannot otherwise be observed. [eval]
    reads [Sys.argv], which a test cannot set; the idle action it binds never
    returns; and the readiness gather it binds probes the Docker socket and PID
    1 of whatever machine the process is on, so a caller that could not replace
    it would be asserting about the machine that happened to run it. The group,
    the terms and the exit-code mapping are the same values in both.

    [idle] answers [unit] rather than a result because an idle has no failure to
    classify -- there is no configuration it reads and nothing it can be wrong
    about. An [idle] that returns exits 0, which is the code the empty argument
    list has always left behind; {!eval}'s own never returns, so the code is one
    only a caller that supplied its own idle ever sees. An exception that
    escapes it is classified like any other term's, by {!classified_status}.

    [observe] is what [check] gathers with, and it takes whether the deployment
    configures cron because the container cannot soundly infer that about
    itself. {!eval} binds [Readiness.observe] against this container's own paths
    -- the Docker client's socket, the crontab module's spool and PID 1's stderr
    -- and nothing below this signature carries a default for any of them.

    {b It sets SIGPIPE to [Signal_ignore] for the rest of the process, before
       any term is evaluated.} That is a side effect on the process rather than
    a property of the returned code, and it is stated here because it is the
    behaviour a caller gets and a test observes. A client that goes away closes
    the stream its subcommand was writing to; at the default disposition the
    next write kills the process where it stands, so the work stops halfway, no
    failure class is chosen, and nothing is left for [bondi status] to recover.

    It is set at this one point rather than left to [Eio_main.run] -- which sets
    the same disposition and never restores it, in both eio 1.3 backends, read
    on 2026-09-11 -- because that covers only a path that reaches an
    environment. [check] builds none, the idle builds none, [deploy]'s
    undecodable-payload arm answers before one is built, and cmdliner writes
    [--help], [--version] and its own usage errors before any term runs.

    Ignoring the signal is what makes a vanished reader classifiable; it is not
    what makes a write harmless, and the distinction is the contract. A write
    issued {e while work is in flight} is a diagnostic, and [Diagnostics.write]
    drops it: [observed -- 2026-09-11] against this tree, a [Diagnostics.write]
    into a pipe whose read end had already been closed returns normally under an
    ignored SIGPIPE and kills the process with shell status 141 without it. A
    write issued once there is {e nothing left to report} still fails the
    subcommand -- see {!classified_status}, where that arm is documented and
    unchanged.

    {b It also switches backtrace recording on for the rest of the process, at
       the same point and before any term is evaluated.} That is the same kind
    of side effect on the process, stated here for the same reason: it is what a
    caller gets and what a test observes. {!classified_result} takes the raw
    backtrace as its handler's first statement, which is the earliest a handler
    can take one, and with recording off it takes an empty one -- so the
    diagnostic is the exception's message with nothing under it saying where.
    Recording used to be switched on for this binary as a side effect of
    serving, by a logger no subcommand ever ran; the decision lives here now. *)

val production_observe :
  observe:
    (cron_configured:bool ->
    docker_socket:string ->
    spool_dir:string ->
    diagnostic_sink:string ->
    crontab_path:string ->
    payload_dir:string ->
    Readiness.observation list) ->
  cron_configured:bool ->
  Readiness.observation list
(** The readiness gather bound to this container's own paths. *)

val classified_result :
  (unit -> ('a, Handler_error.t) result) -> ('a, Handler_error.t) result
(** [classified_result body] is [body ()], with an exception that escaped it
    answered as {!Handler_error.Orchestrator_failure} carrying the exception's
    text, and its raw backtrace written to [Diagnostics.write].

    It is what stands between an escaping exception and cmdliner's
    [Exit.internal_error], which is 125 -- a code {!Handler_error.exit_code}
    forbids a failure class from taking, because it reports a machine fault as a
    mistyped command. [Cmd.eval'] intercepts uncaught exceptions by default, so
    without this every subcommand has that code reachable by ordinary means: a
    trust store that will not load, an Eio backend that will not start, a
    standard output the caller has closed.

    [Eio.Cancel.Cancelled] and [Stdlib.Exit] propagate unchanged and are not
    classified. A cancelled fiber that returned a value would break structured
    concurrency, and an exit taken deliberately is not an orchestrator fault.

    It takes its body as a function, and is public, because that is what makes
    all three arms reachable from plain data: the two propagations would
    otherwise be assertions made only by comment, and neither can be produced
    through a real Docker socket or a real Eio cancellation from a test. *)

val classified_status : (unit -> int) -> int
(** [classified_status action] is [action ()], with an exception that escaped it
    classified by {!classified_result} and then written and coded by
    [Cmd_io.status_of] -- the message on standard error, and
    {!Handler_error.exit_code} of its class as the result.

    Where {!classified_result} covers a body that answers a result, this covers
    everything a term evaluates: the environment built before the body runs --
    [Eio_main.run], the Docker client, the outbound trust store -- and the write
    that follows it, whose [print_string] and [flush] raise on a stdout the
    caller has closed. Neither sits inside any body, so classifying bodies alone
    would leave 125 reachable on every subcommand.

    That write is the response, and it is the one write here that a caller going
    away is still allowed to fail. [observed -- 2026-09-11] against this tree,
    with file descriptors 1 and 2 pointed at a pipe whose read end had already
    been closed, [print_string "{}"; flush stdout] and
    [prerr_string "boom"; prerr_newline (); flush stderr] each raise
    [Sys_error "Broken pipe"] under the disposition {!eval_argv} sets, and each
    kill the process with shell status 141 without it. Both that and the closed
    descriptor arrive here as a [Sys_error] and leave as
    {!Handler_error.Orchestrator_failure}, which is the classification this
    module has always given the final write and the one that does not move: by
    the time it runs there is nothing left to report, so a report that could not
    be made is a failure of the subcommand. The opposite arm -- a write issued
    while the work is still running -- is not this write and is not classified
    here at all; {!eval_argv} says where it goes.

    Propagation is {!classified_result}'s, unchanged: a cancellation and a
    deliberate exit are not exit codes to be chosen here. *)
