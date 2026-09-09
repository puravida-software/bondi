(** The directory a host's cron jobs keep their files in, kept alive across an
    orchestrator recreate.

    A cron job's definition lives in two files beside the crontab line rather
    than in it: the run payload the line reads, and the secret environment the
    container is started with. On a host that bind-mounts the directory they
    survive anything done to the container. On a host that does not — every host
    whose orchestrator was created before the mount existed — they live in the
    container's writable layer, and a version bump stops, removes and re-runs
    that container by design. The crontab line survives the recreate; the file
    it names does not, and the job then fails silently at every fire until the
    next deploy.

    So the directory is copied out of the existing container onto the host
    before anything stops it, and it is copied {i on the box}: no file, no
    payload and no credential travels through the client. The files keep the
    mode and ownership the writer gave them.

    Everything this module returns is a job's name, a fact about a file's
    presence, or a path under the payload directory. Never a file's contents and
    never a crontab line: nothing here opens a file, and {!listing_command}
    prints paths and nothing else, so no output of it can carry a secret to cut
    out of. That is why this has no counterpart to the redaction
    {!Crontab_listing} performs, whose reads return a spool file in which every
    line may be a credential — the difference is in what the two commands can
    print, not in how carefully their results are filtered.

    The one value that carries text the host wrote is {!Unlisted}, and what it
    carries is the transport's own account of a call that failed, which on a
    stream cut part-way can hold paths the listing had already printed. A path
    holds a job's name and the fixed names of its two files, and the job's name
    is what this module exists to report, so there is nothing in one that is not
    already on its way to the operator.

    It performs no I/O. The caller runs {!preserve_command} and
    {!listing_command} on the server and brings the output here, in the same
    shape as {!Crontab_listing} and {!Host_inventory}. *)

(** What the host's payload directory holds.

    A directory that is not there and a directory that could not be listed are
    different facts and an operator acts differently on each. Collapsing the
    second into the first would name every job on the host as having lost its
    files, on the strength of a read that never happened. *)
type listing =
  | Payloads of { files : string list }
      (** the absolute paths of the files the directory holds *)
  | Root_absent  (** the host answered that the directory is not there *)
  | Unlisted of string  (** the directory was never listed *)

(** What a job named by the section is missing from the payload directory — or,
    for a job that keeps nothing there, why it is missing nothing.

    A job holding both files is not one of these: it is absent from the report
    entirely, so nothing has to be said about the ordinary case. Each of the
    four is a different sentence to an operator — a job with no run file fails
    at its next fire, a job with no environment file runs on with an empty one,
    and a job whose payload is on its crontab line goes on working exactly as it
    did. *)
type shortfall =
  | Env_file_missing  (** the secret environment file survives nowhere *)
  | Run_file_missing  (** the run payload file survives nowhere *)
  | Both_files_missing  (** neither survives *)
  | Payload_on_the_line
      (** the job is named by a legacy line carrying its own payload: it keeps
          no files here, never did, and has lost nothing *)

val preserve_command : string
(** The shell command that copies the payload directory out of the existing
    orchestrator onto the host.

    It names the directory and nothing inside it, so no job's name and no file's
    path is ever built into a command line. It creates the host directory first,
    at the mode the writer of the files uses, because the copy has nowhere to
    land on a host that has never had one.

    The copy is skipped when the container already bind-mounts that directory,
    which it asks the container rather than inferring from what the host
    directory holds. A bind-mounting host would otherwise have the archive read
    and the extraction write the same files at once, and [docker cp] streams, so
    a file the writer never touched can come back truncated. That host is also
    the one with nothing to rescue, since the mount is what makes its files
    outlive the container — so the run where the copy could do damage is the run
    where it has nothing to do. Reading the host directory's contents instead
    would answer a different question, and answer it wrong for good: an
    extraction cut part-way leaves that directory non-empty and incomplete, and
    every later run would skip the copy on the strength of the residue.

    A host whose section's markers do not balance is copied out of all the same,
    and nothing is reported about it: {!Crontab_listing} names no job in a
    section it could not make sense of, so {!shortfalls} has no job to answer
    for and the report is empty. That is the safe pair. The copy costs a
    directory on a host nothing is about to rewrite, while skipping it on the
    one host whose crontab Bondi understands least is how the recreate deletes
    the files of lines that go on firing.

    It always exits 0. A container that holds no such directory is not a
    failure: the files were lost before this run, which is a fact for
    {!shortfalls} to report rather than a reason to refuse. Nor is a host that
    refuses [sudo -n] — which is the very host whose crontab could not be read,
    and so the very host a preserve is planned for, so a non-zero exit here
    would abort setup on it every time. Every host-side failure is therefore
    swallowed and {!listing_command} is what says which files are actually
    there. What is not swallowed is the call failing to reach the host at all:
    that arrives on the caller's error channel, and the caller runs this before
    anything stops the container so a host that cannot be reached is never a
    host left with lines whose files this run deleted. *)

val listing_command : string
(** The shell command that prints the paths the host's payload directory holds.

    It says on standard output which of three things happened — the directory
    was listed, it is not there, or it could not be read — and always exits 0. A
    non-zero exit would arrive as an SSH-layer error, which is the same channel
    a dropped connection uses, so the host's answer and the failure to get one
    would again be the same value.

    The read is privileged: the files are mode 600 in a 0700 directory owned by
    root, so an unprivileged guard reports "not there" for a directory that is
    plainly there — and that false absence would be reported as every job on the
    host having lost its files. It never waits on a password prompt.

    Only the file paths are printed. Nothing reads a file, so no output of this
    command can carry what one holds. *)

val of_listing_output : (string, Remote_exec.failure) result -> listing
(** Read the payload directory's contents out of the output of
    {!listing_command}.

    The argument is the remote call's own outcome rather than a sentence about
    it, so a directory that could not be listed is distinguishable from one that
    was listed and holds nothing. Output carrying none of the command's markers
    is {!Unlisted} rather than an empty directory: a stub, a truncated stream
    and a shell that never ran the command all answer with nothing, and reading
    that as "the directory is empty" names every job on the host. *)

val shortfalls :
  jobs:Crontab_listing.named_job list -> listing -> (string * shortfall) list
(** What each of [jobs] does not hold in the payload directory, in the order the
    jobs were given, omitting the jobs that hold everything they should.

    A job named by an exec line is expected to hold the two files
    {!Bondi_common.Cron_exec_line.run_file_of} and
    {!Bondi_common.Cron_exec_line.env_file_of} name, which are the paths the
    orchestrator writes and the paths its crontab lines read. They are compared
    whole rather than by their last segment, so a file the host reports from
    somewhere else under the directory answers for no job.

    A job named by a legacy line is answered from its shape alone and never from
    the directory. Its payload is on the line, so it holds neither file on any
    host and on no host has it lost one: judging it by the same absence would
    tell the operator that every unmigrated job on the box fails at its next
    fire, which on the boxes this phase was written for is most of them. It is
    still reported, as {!Payload_on_the_line}, because a legacy line still on
    the box is the one thing about that job worth saying — and it is reported
    whatever the listing did, since what makes it legacy was read from the
    crontab rather than from the directory.

    For an exec-line job, a listing that was never taken yields nothing at all
    rather than every job: a read that failed is not the host's answer, and a
    report naming every job on a host whose directory was never read is a claim
    about files nobody looked at. A directory the host says is not there is the
    host's answer, and every such job is named. *)

val report :
  server:string -> jobs:Crontab_listing.named_job list -> listing -> string list
(** What the preserve found on [server], as the lines to print, in the order to
    print them.

    Empty for the ordinary host: every job holds both its files and there is
    nothing an operator has to be told. A listing that was never taken is said
    first and out loud, because silence there would read as every job holding
    its files; a directory the host says is not there adds no such line, because
    that is the host answering rather than failing to. Each job {!shortfalls}
    names then gets the one sentence its own shortfall earns.

    The wording lives here rather than in the caller's interpreter for the
    reason {!Setup_phases.failure_message}'s does: these sentences are the whole
    of what the operator receives, and an arm that builds its own leaves them
    with nowhere to be asserted. *)
