(** Diagnostic lines from the orchestrator, written where the container log
    stream can see them.

    The observation this module is designed against, recorded here because this
    is the only place it ships:

    Diagnostics and the container log stream. [observed — 2026-09-04]

    Docker and Podman capture only PID 1's stdout and stderr into a container's
    log stream. A process entered into a running container with "docker exec"
    writes to its own stdout and stderr, which reach whoever invoked the exec
    and never appear in the container log. To land a line in that log, such a
    process must write to PID 1's file descriptors directly, through
    /proc/1/fd/1 or /proc/1/fd/2.

    Observed on 2026-09-04 against Podman 5.8.4, rootless, with conmon 2.2.1,
    crun 1.28, the journald log driver and kernel 7.2.1, using alpine 3.24.1
    with "sleep" as PID 1. No Docker Engine was reachable from the machine that
    ran it, so Docker Engine and the json-file log driver are outside what this
    observation covers.

    What was seen:

    - With the exec running as the same uid as PID 1, a write to /proc/1/fd/2
      appears in the container log while the exec's own stdout and stderr do
      not. Both routes were exercised in one run, so the absence is evidence
      rather than silence.
    - With the exec running as a different uid from PID 1, in either direction,
      the open is refused. The gate is the kernel's ptrace_may_access check on
      /proc/PID/fd, which passes on a uid match or on CAP_SYS_PTRACE; neither
      engine grants CAP_SYS_PTRACE by default, so a uid-0 exec against an
      unprivileged PID 1 is refused exactly as an unprivileged exec against a
      uid-0 PID 1 is. Matching uids is the condition, not privilege.
    - That refusal is reported on the failing process's own stderr every time,
      and is therefore always detectable there. It is not reliably visible in
      the exec's exit status, which reflects whatever the process went on to do
      after the failed write.
    - When the writer is itself PID 1 the write succeeds and the line appears
      twice, once from the process's own stderr and once by way of /proc/1/fd/2.
      That is why the duplication is conditional on the writer not being PID 1.

    This server's image runs PID 1 as uid 1000 and an exec that does not
    override the user inherits it, so the matching case is the one that arises
    in practice.

    Also outside this observation: a PID 1 whose stderr is a buffered channel
    written concurrently with an exec's unbuffered writes; uids other than 0 and
    PID 1's; log volume, rotation and backpressure; and the path a log shipper
    takes out of the engine, which is not the same reader as "docker logs".

    The commands that produced it, each one causing the exec it reports rather
    than waiting for a naturally occurring event.

    They are spelled "docker" below because that is how they were typed, and the
    binary they reached is the Podman Engine named above, not a Docker Engine:
    the client was Docker CLI 29.7.2 (API 1.44) with
    DOCKER_HOST=unix:///run/user/1000/podman/podman.sock, and there was no
    dockerd on the machine. Re-running the block against a real Docker Engine
    exercises an implementation this observation did not cover; re-running it
    against Podman is what it records, and "podman" may be substituted for
    "docker" throughout to do that without the client in the middle.

    Arm A is PID 1 uid 0 with the exec at uid 0:

    {[
      $ docker run -d --name bondi-spike-a docker.io/library/alpine:3.24.1 sleep 3600
      $ docker exec bondi-spike-a sh -c 'echo A_EXEC_OWN_STDOUT; echo A_EXEC_OWN_STDERR >&2;
          echo A_EXEC_VIA_PROC1FD2 > /proc/1/fd/2; echo A_EXEC_VIA_PROC1FD1 > /proc/1/fd/1'
      exec stdout: A_EXEC_OWN_STDOUT
      exec stderr: A_EXEC_OWN_STDERR
      exec exit:   0
      $ docker logs bondi-spike-a
      A_EXEC_VIA_PROC1FD1
      A_EXEC_VIA_PROC1FD2
    ]}

    Arm B is PID 1 uid 1000 with the exec at uid 0. Arm C is the same shape in
    the opposite direction, PID 1 uid 0 with the exec at uid 1000, and reports
    the same refusal:

    {[
      $ docker run -d --name bondi-spike-b --user 1000:1000 docker.io/library/alpine:3.24.1 sleep 3600
      $ docker exec --user 0:0 bondi-spike-b sh -c 'echo B_EXEC_OWN_STDOUT;
          echo B_EXEC_VIA_PROC1FD2 > /proc/1/fd/2; echo "WRITE_RC=$?"'
      exec stdout: B_EXEC_OWN_STDOUT
                   WRITE_RC=1
      exec stderr: sh: can't create /proc/1/fd/2: Permission denied
      exec exit:   0
      $ docker logs bondi-spike-b
      (empty)
    ]}

    Arm E is the production shape, PID 1 uid 1000 with the exec at uid 1000.
    Unprivileged on both sides works:

    {[
      $ docker exec --user 1000:1000 bondi-spike-b sh -c 'echo E_EXEC_VIA_PROC1FD2 > /proc/1/fd/2; echo "WRITE_RC=$?"'
      WRITE_RC=0    (no stderr)
      $ docker logs bondi-spike-b
      E_EXEC_VIA_PROC1FD2
    ]}

    Arm D is the doubling that {!should_duplicate} exists to prevent, with the
    writer itself PID 1:

    {[
      $ docker run -d --name bondi-spike-d docker.io/library/alpine:3.24.1 \
          sh -c 'echo D_SAME_LINE >&2; echo D_SAME_LINE > /proc/1/fd/2; echo "D_WRITE_RC=$?" >&2; sleep 3600'
      $ docker logs bondi-spike-d
      D_SAME_LINE
      D_SAME_LINE
      D_WRITE_RC=0
    ]}

    Docker Engine with the json-file driver is expected to behave as Podman did
    here, because the cause of the refusals is a kernel check and Docker's
    default capability set also omits CAP_SYS_PTRACE. Expected, not observed. *)

val should_duplicate : pid:int -> bool
(** Whether a line written by the process with id [pid] must also be written to
    PID 1's stderr. False when [pid] is 1: that writer is already the process
    whose streams the engine captures, and duplicating there emits every line
    twice rather than failing. True otherwise, which is the only way a process
    entered into the container reaches the log at all. Pure, so both answers are
    tested without a container. *)

type sink
(** A place a diagnostic line is duplicated to, together with whether this
    process has given up on reaching it.

    Abstract because neither half is a caller's to set: the path is fixed when
    the sink is made, and the latch is written only by the code that discovers
    the refusal. The latch belongs to the sink rather than to the module so that
    a sink given up on does not silence a different one. *)

val sink_at : path:string -> sink
(** A sink at [path] with nothing yet given up.

    It exists so that the degradation path can be driven from a test. Every
    branch below the open -- a refused open, a write that moves no bytes, a sink
    that is not ready, and the once-only latch -- is reachable only through a
    sink that is not [/proc/1/fd/2], whose behaviour is a property of the
    machine the suite runs on rather than of anything a test can arrange. *)

(** What one write syscall to a duplicate sink did. *)
type attempt =
  | Wrote of int
      (** [Wrote n] moved [n] bytes, which may be fewer than were offered and
          may be none of them. *)
  | Interrupted  (** A signal arrived before any byte moved. *)
  | Not_ready  (** A non-blocking sink had no room for the bytes offered. *)

(** What the rest of the line is to do next. *)
type step =
  | Advance of { offset : int; remaining : int }
      (** Carry on at [offset], with [remaining] bytes still to send. *)
  | Abandon of string
      (** Give the line up, carrying the reason the notice will name. *)

val step_after : offset:int -> remaining:int -> attempt -> step
(** The decision a partial write forces, as a function of plain numbers.

    A single write is not obliged to move the whole string, so this is where the
    module's branching lives: a write that moved no bytes with bytes still to
    send cannot make progress and is the silent truncation this module exists to
    close, an interrupted one has not lost its place, and one that found no room
    has nowhere to put the rest. It is public because neither [Wrote 0] nor
    [Not_ready] can be produced by pointing a sink at a file, so a test reaches
    them here or nowhere. It is kept out of the loop that calls it so that the
    loop is a syscall and a recursion with no decision of its own. *)

val pid_one_stderr : string
(** The path a line is duplicated to so that the container log stream carries
    it: PID 1's standard error, which is the only stream the engine captures.

    Exported because a readiness check must probe the same stream this module
    writes to, and a second literal of the path in the module that probes it
    would be two statements of one fact -- with the probe's copy the one an
    operator would be misled by if they drifted. *)

val write : string -> unit
(** Write one diagnostic line to this process's stderr, and -- when
    {!should_duplicate} says so of this process -- to PID 1's stderr as well.

    It is {!write_to} against a process-wide sink at [/proc/1/fd/2]; that path
    is the only part of it that {!write_to}'s tests do not cover.

    It returns nothing a caller can act on. A diagnostic that cannot be shipped
    must never become the outcome of the operation that emitted it, and a caller
    offered a result would sooner or later fail a deploy over a log line.

    Non-raising under an ignored SIGPIPE, and the condition is not decoration.
    PID 1's stderr is a pipe in the ordinary case, and a write to a pipe whose
    reader has gone delivers SIGPIPE, which at its default disposition
    terminates the process before anything here runs. [Eio_main.run] sets that
    disposition to ignore for the lifetime of the server -- read in eio 1.3's
    own sources, where both backends open with
    [Sys.(set_signal sigpipe Signal_ignore)], not measured here against a broken
    pipe -- so every caller today is covered; nothing in this module sets or
    restores it, so a caller outside that scheduler would not be. Setting it per
    write is not done here because the disposition is process-wide rather than
    per call -- the client's ssh runner takes that route and documents that it
    is therefore not re-entrant -- and diagnostics are written from more than
    one fiber. *)

val write_to : sink -> string -> unit
(** [write_to sink line] is {!write} against a caller-supplied [sink] rather
    than PID 1's stderr, and is what {!write} is defined as.

    The duplicate is opened non-blocking, and a write that would have blocked
    drops the line down the same degradation path a refused open takes. The
    hazard that answers is the pipe again: every caller of {!write} in this
    library is inside a Dream handler or inside [Lwt_eio.run_eio] on the one
    domain that serves every request -- read at the call sites, all eight of
    them -- so a blocking write to a sink whose reader (the engine's log driver,
    or the shipper behind it) has stalled would suspend not just the caller but
    the server. That last step is reasoned from the call sites and from the
    single-domain scheduler; no stalled reader was produced to watch it happen,
    which is why the resolution is the cheap one rather than a measured one.
    Draining from a domain of its own would keep the line and was not chosen:
    this module's contract is that a diagnostic is never the operation's
    outcome, and a write that can stop the server is that outcome under another
    name, so extending the degradation path already here costs less than a
    second concept. The line is not lost in any case -- it is on this process's
    own stderr before the duplicate is attempted.

    What no test pins is the flag itself. Producing a sink that would block
    means a fifo whose read end is held open and never drained, and a regression
    to a blocking open or write would then hang the suite rather than fail it,
    which is a worse signal than none. [Not_ready], the branch the flag exists
    to feed, is pinned through {!step_after} instead.

    A duplicate write that is refused degrades to own-stderr-only for the rest
    of the process and says so once, on this process's own stderr. Once, because
    a uid mismatch does not change while the process runs, so a notice per line
    would be the noise it is warning about. Not silently, because a diagnostics
    sink that is quietly unreachable is indistinguishable from one that is
    working. The kernel also reports a refused open on that same stream, so the
    notice names which stream was lost rather than being the only sign that one
    was.

    A stall is latched by the same one-shot, and unlike a uid mismatch it can
    clear: a sink given up on is not retried even if its reader recovers. That
    is deliberate -- retrying per line is the flood the notice warns about --
    and it is recorded here because it is the one condition where the latch
    outlives its cause. *)
