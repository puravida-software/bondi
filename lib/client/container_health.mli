(** Whether a container the host is running has passed its own healthcheck.

    A container that is up is not a container that works: the process can be
    parked on a dialog nothing will ever dismiss, and a listener can stay open
    on a port for the seconds it takes to destroy and rebuild what is behind it.
    Liveness answers a different question, and substituting it for health is
    wrong on exactly the schedule that makes it hard to notice.

    This module reports a state; it never waits on a caller's behalf. It
    performs no I/O either: the caller runs {!wait_command} on the server over
    SSH and brings the output here, in the same shape as {!Orchestrator_probe}.
*)

(** What the host said about a container's healthcheck.

    Silence is not a pass, and neither is the absence of a check to fail: a
    container that defines no healthcheck has passed nothing, and a read that
    never happened has established nothing. Both are distinct from a check that
    ran and failed, because an operator acts differently on each. *)
type verdict =
  | Healthy  (** the container's own healthcheck passed *)
  | Unhealthy of string
      (** it failed, and this is how many runs in a row have failed — the one
          thing about a failing check a reader of the report cannot work out for
          themselves, and the whole of what the host is asked for *)
  | No_healthcheck
      (** the container defines none, so there is nothing here to wait for *)
  | Timed_out of { seconds : int }
      (** it did not pass within the bound the host waited out *)
  | Gone
      (** the container is not running: it stopped while being waited on, or it
          was never there to wait on. The host said so — a reading that could
          not be taken is {!Unreadable}, never this *)
  | Unreadable of string  (** the wait produced no verdict *)

val wait_timeout_seconds : int
(** How long {!wait_command} is given before it reports a timeout.

    A healthcheck that retries a few times at its own interval can legitimately
    take over a minute to reach its first verdict, so this is a bound on how
    long a slow-but-healthy component is allowed, not an expected wait. *)

val wait_command : container_name:string -> timeout_seconds:int -> string
(** The shell command that waits on the host for [container_name] to become
    healthy, for at most [timeout_seconds].

    The bound is a required argument rather than a value this module reaches
    for, so a caller waiting for a different length of time has to say so. It is
    a bound in seconds, enforced against the host's own clock: a loop counting
    its passes would run for as long as those passes take, which is materially
    longer than the number the report prints beside it.

    The loop runs on the server, so the bound costs one round-trip rather than
    one per attempt. The SSH call itself does block for the wait's duration —
    what is saved is the polling, not the connection.

    It stops as soon as the container is no longer running: a container that has
    already died will not start passing, and an operator should not wait out the
    bound to be told so. A container the operator started with
    [--no-healthcheck] carries a healthcheck record whose test is [NONE], and
    that is read as no check to wait for rather than as one that never passes.

    Every reading is tested for having been taken. Each [docker inspect]
    discards its stderr, so a daemon that is down or a socket that may not be
    opened comes back indistinguishable from a container that is not running,
    and reporting the second on the strength of the first states as a fact about
    the container something that was never read.

    What a failing check printed is never asked for. A healthcheck is a command
    line, and a command line on a deployment host is a place credentials live,
    so a check that fails while calling an authenticated URL prints that URL. A
    verdict cannot report what the wait never fetched, which is a defence that
    holds against a later reader of the type; declining to render it at the one
    site that does today is not.

    The verdict is carried by a marker on standard output and the command always
    exits 0. A non-zero exit would be reported by the SSH layer as an error
    carrying only stderr, which discards the marker that said what happened;
    leaving the exit status alone keeps it meaning "the command could be run on
    that host", which is a different fact and one {!verdict_of_output} also
    needs. *)

val verdict_of_output : (string, string) result -> verdict
(** Decide, from the outcome of running {!wait_command}, what the host said.

    The argument is the SSH call's own result, so a wait that ran and reported a
    failure is distinguishable from one that could not be run at all. Output
    that carries no marker — including no output whatsoever — is a rejection
    rather than a pass: a remote command that exited without saying anything is
    not evidence that a container is healthy, and reading it as one is the
    defect this module exists to prevent. *)
