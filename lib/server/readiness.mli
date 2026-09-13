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
  | Cron_divergence
      (** Whether the host's Bondi crontab section and the cron payload
          directory describe the same set of jobs. Probed only when the
          deployment says cron is configured, for the reason {!Crontab_spool}
          is. This is the earliest place the disagreement can be detected: it is
          found on a box the operator has run nothing against yet. *)

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
  crontab_path:string ->
  payload_dir:string ->
  observation list
(** The gather. Takes each probe's reading and records it; it draws no
    conclusion, which is {!plan}'s job and nowhere else's.

    The observations come back in the order the probes were taken: the Docker
    socket, then the crontab spool and the cron divergence when
    [cron_configured], then the diagnostic sink. [cron_configured] is the
    deployment's answer rather than the container's: whether scheduled jobs are
    expected to be installable, and whether this host is meant to have any, is a
    property of the deployment the caller built the container from, and a
    container asked to infer it from its own filesystem would report a spool it
    was never meant to have as a fault.

    Every path is a required argument, with no default anywhere below this
    signature. The caller that runs against this container binds
    {!Docker.Client.default_socket_path}, {!Crontab.crontab_spool_dir}, PID 1's
    stderr, {!Crontab.crontab_path} and the directory the cron payload writer
    makes a job's files under; a test binds paths it made and removed. That is
    what puts both arms of all four probes within reach of a test holding no
    root and no container -- a probe anchored to the machine's own socket
    asserts about the machine that happened to run the suite.

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
    - [crontab_path] and [payload_dir] are read and compared. The names the
      Bondi section of the crontab fires are read through
      {!Crontab.section_job_names}, the names the payload directory holds a
      job's files under are read from the directory, and the two are put to
      {!Bondi_common.Cron_divergence}, which is where the rule lives so that a
      reader on either side of a connection can reach it. It answers the two
      directions this probe is about: a name the section fires whose job holds
      no payload file at all, and a job whose files no line fires. The client
      has not been moved onto it and still runs its own wider comparison over
      the same two sources read as commands, reporting one thing this probe does
      not -- a job holding one of its two files rather than neither -- so
      agreement here is agreement about these two directions and not about
      everything either end can say of a host. A source that could not be read
      yields no disagreement in either direction and the probe passes, which is
      the whole of what it then claims: it found none, on a host it could not
      fully read. A failure carries every disagreement found, each with the
      sentence that closes it, and one direction's sentence names no command
      because there is none -- the file to edit is named instead.

    Total: a probe that cannot be taken is an [Error] carrying the path and the
    system's reason for it, never an exception.

    What a reported divergence costs the caller is deliberate, and is larger
    than a report. A disagreement here is an [Error] like any other, so the
    verdict is [Not_ready], so [check] leaves the not-ready exit code behind, so
    a client reading that status back over the transport stops the run that
    started the container. On the setup path that means the host is refused at
    the orchestrator step, before anything downstream of it converges. And one
    of the two directions -- a crontab line whose job holds no payload file at
    all -- is the one [Bondi_common.Cron_divergence.remedy] says no command
    clears: no deploy writes those files, because nothing in the configuration
    names that job any more. So the refusal is not transient. It stands on every
    invocation until an operator opens the crontab this probe named and removes
    the entry by hand, and the run does not get further while it does.

    That is the intended reading and not an accident of the exit code: a host
    whose crontab fires jobs whose files are gone is misconverged, and failing
    loudly on it is better than converging more of the deployment on top of it.
    A caller that wants the divergence reported without being blocked by it
    wants a severity distinction this interface does not carry: {!verdict} is
    two constructors and {!error_of_verdict} collapses one of them to a single
    exit code, so a third class would change what every probe here means and not
    only this one.

    Which hosts pay it is [cron_configured]'s answer, and that answer is wider
    than the deployment's own cron declaration. The client answers it from what
    the configuration declares {e together with} the crontab listing the same
    run has already read and already acted on, so a host already holding a Bondi
    section is probed even when the configuration declares no job -- that host
    got the payload mounts a moment ago and is the likeliest of all to be
    holding a stale line. A deployment that declares a job implies the flag, so
    nothing that was probed under the narrower question is unprobed under this
    one.

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
    caller wiring this into a loop owes that a look first.

    The divergence probe is not one of the two and is the cheapest of the four.
    It opens [crontab_path], lists [payload_dir], and writes nothing to either:
    no line into the log stream, no file into the spool, and so no cron reload.
    Its cost per invocation is one file read and one directory listing, both
    small -- the crontab is a file an operator maintains by hand and the payload
    directory holds one entry per scheduled job. That is said here rather than
    left to be inferred because the paragraph above is what a caller deciding
    whether to poll [check] reads, and a cost list that named three probes and
    omitted the fourth would be read as the whole of the cost. It does not make
    polling free: the two probes above still charge their line and their reload
    per tick, and this changes none of that. *)

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
