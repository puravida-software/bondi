(** Whether the orchestrator a [bondi setup] just started is actually serving.

    [docker run -d] answers with a container id as soon as the container has
    been created. It says nothing about whether the process inside survived, so
    a server that aborts on startup — a missing shared library stops the musl
    loader before [main] and exits 127 — is reported as a successful setup while
    the host is left with nothing listening on its orchestrator port. Every
    crontab line then POSTs into a closed port and silently does nothing.

    This module turns "did it start" into "is it answering". It performs no I/O:
    the caller runs {!probe_command} on the server over SSH and brings the
    output here, in the same shape as {!Curl_version}. *)

val readiness_attempts : int
(** How many one-second attempts {!probe_command} makes before giving up. The
    orchestrator binds its port within a second of starting, so this is a bound
    on how long a healthy-but-slow host is given, not an expected wait. *)

val probe_command : port:int -> attempts:int -> string
(** The shell command to run on the server after starting the orchestrator.

    It requests the orchestrator's health endpoint on [port] from inside the
    container itself, so no tooling is required on the host beyond Docker, and
    retries up to [attempts] times at one-second intervals. It stops early if
    the container is no longer running: a container that has already died will
    not start answering, and the operator should not wait out the full timeout
    to be told so.

    The verdict is carried by a marker on standard output, and the command
    always exits 0. Leaving the exit status alone keeps it meaning "the command
    could be run on that host", which is a different fact and one {!verdict}
    also needs. A failure now carries the command's whole output, so a marker
    printed before a non-zero exit does reach this module -- and is still not
    read as a verdict, because honouring it would give the exit status two
    meanings again. *)

val diagnostics_command : string
(** The shell command that collects what the operator needs to diagnose an
    orchestrator that did not come up: the container's final state and exit
    code, followed by its last log lines. Run only after a failed probe. *)

val verdict : (string, Remote_exec.failure) result -> (unit, string) result
(** Decide, from the outcome of running {!probe_command}, whether the
    orchestrator is serving.

    The argument is the SSH call's own outcome rather than a sentence about it,
    so it distinguishes a probe that ran and reported failure from a probe that
    could not be run at all; both are rejections, and each error names which
    happened. A {!Remote_exec.Command_failed} says the readiness check ran on
    the server and failed — the probe always exits 0, so a non-zero exit is the
    server reporting it could not get that far. Every other failure says the
    check could not be run on the server, which is where it has always pointed
    and is now the only place it does. Output that carries no marker — including
    no output at all — is a rejection rather than a pass: a remote command that
    exited without saying anything is not evidence that the server is up, and
    reading it as one is the defect this module exists to prevent. *)

val failure_message :
  ip_address:string ->
  image:string ->
  reason:string ->
  diagnostics:string ->
  string
(** The operator-facing report for an orchestrator that did not come up.

    Names the server and the image that failed, why the probe rejected it, and
    quotes the server's own account of the failure — the container's exit code
    and logs, obtained with {!diagnostics_command} — so the cause is readable
    without logging into the host. *)
