(** Whether this box is in a state to serve, and what is wrong when it is not.

    The module is the gather/plan sandwich with the plan kept on its own: a
    probe reads the machine and records what it saw, and {!plan} turns those
    records into a verdict without reading anything. Both arms of every probe
    are therefore reachable from a test holding plain data, with no filesystem
    and no container.

    The verdict is a variant rather than a set of booleans: three booleans admit
    eight states, most of which are not reachable and none of which the compiler
    will check. *)

(** What a single observation is about.

    A probe is a question about the machine that can be asked without acting on
    it, so that a caller learns what is wrong before it starts work rather than
    part of the way through. *)
type probe =
  | Docker_socket  (** The Engine socket the orchestrator acts through. *)
  | Crontab_spool
      (** The directory scheduled jobs are written into. Probed only when the
          deployment says cron is configured: whether the spool is expected to
          be usable is a property of how the container was built, not something
          the container can soundly infer from its own filesystem. *)
  | Diagnostic_sink
      (** Where a diagnostic line is written so that the container log stream
          can carry it. This probe establishes that the sink is writable and
          nothing further. Whether a line written there arrives in the log
          stream cannot be observed from inside the container -- that needs the
          container runtime, which the process does not have -- and is not
          claimed here. *)

type observation = { probe : probe; outcome : (unit, string) result }
(** One probe and what it saw.

    The [Error] payload is the reason, phrased by whoever ran the probe. It
    reaches the operator's terminal, an HTTP response and the container log, so
    it names paths and conditions and never a value taken from a payload --
    payloads carry environment variables and sink URLs that may embed
    credentials. *)

(** The decision drawn from a set of observations.

    A variant rather than a set of booleans so that no caller can ask whether
    the box is ready of a value that must also say why it is not. *)
type verdict =
  | Ready  (** Every observation taken succeeded. *)
  | Not_ready of observation list
      (** The failing observations, and only those. A verdict that also carried
          the passing ones would put the caller back in the business of
          filtering, which is the decision this type exists to have already
          made. *)

val observe :
  cron_configured:bool ->
  docker_socket:string ->
  spool_dir:string ->
  diagnostic_sink:string ->
  observation list
(** The gather. Takes each probe's reading and records it; it draws no
    conclusion, which is {!plan}'s job and nowhere else's.

    The observations come back in the order the probes were taken: the Docker
    socket, then the crontab spool when [cron_configured], then the diagnostic
    sink. [cron_configured] is the deployment's answer rather than the
    container's: whether scheduled jobs are expected to be installable is a
    property of the deployment the caller built the container from, and a
    container asked to infer it from its own filesystem would report a spool it
    was never meant to have as a fault.

    Every path is a required argument, with no default anywhere below this
    signature. The caller that runs against this container binds
    {!Docker.Client.default_socket_path}, {!Crontab.crontab_spool_dir} and PID
    1's stderr; a test binds paths it made and removed. That is what puts both
    arms of all three probes within reach of a test holding no root and no
    container -- a probe anchored to the machine's own socket asserts about the
    machine that happened to run the suite.

    What each probe does, and what it therefore claims:

    - [docker_socket] is connected to as a Unix stream socket. A socket file
      left behind by an engine that has died refuses the connection and is
      reported, which an existence check would pass.
    - [spool_dir] has a file created in it under a unique dot-prefixed name and
      removed again, so the reading is of the directory a crontab is actually
      installed into rather than of its mode bits.
    - [diagnostic_sink] is opened for writing and a marker line is written to
      it. This establishes that the sink takes bytes and nothing more. A sink
      with no room for the line right now -- the deployed one is a pipe, and a
      pipe whose reader is behind refuses the write with [EAGAIN] rather than
      taking part of the line, which [test_readiness_probes.ml] induces against
      a filled fifo -- passes: that is the sink being unready for one line, not
      a sink that cannot be written, and [Diagnostics.write_all] reads it the
      same way. Whether a line written there arrives in the container's log
      stream cannot be seen from inside the container, is not claimed here, and
      needs an observer outside it.

    Total: a probe that cannot be taken is an [Error] carrying the path and the
    system's reason for it, never an exception.

    Two of the probes act on the box, and a caller that takes them on a schedule
    pays for both on every tick:

    - the sink probe appends its marker line to [diagnostic_sink] every time it
      is taken, so under the deployed wiring each invocation puts a line into
      the container's log stream;
    - the spool probe creates and removes a file in [spool_dir], and that bumps
      the directory's mtime. Directory mtime is the signal cron watches for a
      changed database -- [Crontab.touch_spool_dir] sets it deliberately, with
      [Unix.utimes], for exactly that purpose after a crontab is written -- so
      asking with [cron_configured:true] makes the host's cron reload its
      database as a side effect of the question.

    Both are unremarkable for a one-shot gate: an operator running [check], or a
    setup step taking the reading once. Neither is free from a [HEALTHCHECK] or
    a poll, where they become a log line and a cron reload per interval. A
    caller wiring this into a loop owes that a look first. *)

val plan : observation list -> verdict
(** [plan observations] is {!Ready} when no observation failed, and {!Not_ready}
    carrying every failing observation otherwise, in the order observed.

    Total and pure. Every failure is carried, never only the first: a box with
    two faults that reports one costs a second trip to a machine the operator
    had to reach.

    An observation list with no failures is {!Ready}, the empty list included. A
    probe that was not run is not a probe that failed, which is what lets a
    deployment without cron omit the spool probe rather than record it as a
    pass. *)

val error_of_verdict : verdict -> Handler_error.t option
(** [error_of_verdict verdict] is [None] for {!Ready}, and otherwise a
    {!Handler_error.Not_ready} whose message names every failing probe with the
    reason it gave.

    This is the only producer of that constructor, so a readiness failure cannot
    reach a caller having been classified anywhere else. *)

val observations_to_yojson : observation list -> Yojson.Safe.t
(** The observations as one JSON document: a [ready] flag drawn from {!plan},
    and every observation taken -- passing and failing alike -- under [probes],
    in the order they were observed.

    Each probe is named by a key of its own rather than by the sentence
    {!error_of_verdict} builds, because the two have different readers: that
    text is a message an operator finds on their terminal, and this is a
    document a program compares against. A failing probe carries its [reason]
    and a passing one carries no such field, so an absent reason is never
    confused with an empty one.

    [ready] is asked of {!plan} rather than decided again here, which is what
    keeps the document and the exit code from disagreeing about the same
    observations. A probe that was not taken is simply absent from [probes] -- a
    deployment without cron produces a document with no spool entry, not one
    reporting a spool that passed. *)
