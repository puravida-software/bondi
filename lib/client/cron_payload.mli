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
    presence, or a path under the payload directory. Never a file's contents:
    nothing here opens a file, and {!listing_command} prints paths and nothing
    else. The two files are where a job's command, its environment and its
    credentials live, so this is the guarantee that matters — they are written
    on the box, copied on the box and read on the box, and a client that never
    opens one cannot disclose it.

    The one value that carries text the host wrote is {!Unlisted}, and what it
    carries is the transport's own account of a call that failed, which on a
    stream cut part-way can hold paths the listing had already printed. A path
    holds a job's name and the fixed names of its two files, and the job's name
    is what this module exists to report, so there is nothing in one that is not
    already on its way to the operator.

    A job's name reaches this module twice over and by two routes, and neither
    of them opens anything. The crontab section hands over the names its lines
    read, and the listing's own paths carry the rest: a path under the payload
    directory is a job's name and one of two fixed file names, so the name is
    recovered from the path and the path is then rebuilt from the name, exactly
    as the line's reader does. A path that is neither of a job's two files
    answers for no job rather than becoming one.

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

(** What a job named by the section is missing from the payload directory.

    A job holding both files is not one of these: it is absent from the report
    entirely, so nothing has to be said about the ordinary case. Each of the
    three is a different sentence to an operator — a job with no run file fails
    at its next fire, a job with no environment file runs on with an empty one,
    and a job with neither does both. *)
type shortfall =
  | Env_file_missing  (** the secret environment file survives nowhere *)
  | Run_file_missing  (** the run payload file survives nowhere *)
  | Both_files_missing  (** neither survives *)

(** A disagreement between the two sources, in whichever direction it runs. *)
type divergence =
  | Job_missing_files of { job : string; shortfall : shortfall }
      (** the section names it; the directory does not hold what it fires *)
  | Files_without_a_line of { job : string; unnamed_entries : int list }
      (** the directory holds a job's files and no line the section reader could
          name fires them; [unnamed_entries] are the positions of the entries no
          reader could name, empty when the section was read whole *)

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
    and nothing is reported about it: {!Crontab_listing.jobs_read} answers that
    there was no section to name jobs from, so {!divergences} has nothing to
    compare in either direction and the report says only that. That is the safe
    pair. The copy costs a directory on a host nothing is about to rewrite,
    while skipping it on the one host whose crontab Bondi understands least is
    how the recreate deletes the files of lines that go on firing.

    It always exits 0. A container that holds no such directory is not a
    failure: the files were lost before this run, which is a fact for
    {!divergences} to report rather than a reason to refuse. Nor is a host that
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

    It says where the paths end as well as where they begin, and the listing's
    own success is what says it. The guard asks only whether the directory can
    be opened, so a listing that then fails — refused by the same rule that
    permitted the guard, killed part-way through, or stopped on something it
    could not descend — would otherwise hand back part of the directory with
    nothing to say it was a part. The closing marker is joined to the listing's
    exit rather than printed after it, which is the protocol
    {!Crontab_listing.read_command} uses and not a second one: the two are read
    into one comparison, and a guard on one side only makes a reported
    disagreement real in one direction.

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
    that as "the directory is empty" names every job on the host.

    A stream cut after the opening marker is {!Unlisted} too, and that is the
    closing marker's whole purpose. Such output is paths announced and not
    delivered, or delivered in part, and neither is a directory: the first read
    as an empty one names every job the section fires as having lost both its
    files, and the second names every job below the cut as having lost them.
    Both are a disagreement invented out of a listing that never finished. The
    marker is matched as its own line, newline and all, so a path whose own name
    ends in the word cannot close a listing the host never closed. A directory
    the host listed and found empty prints the two markers with nothing between
    and is an answer, not a truncation. *)

val divergences : crontab:Crontab_listing.t -> listing -> divergence list
(** Where the crontab section and the payload directory disagree, in both
    directions: first the jobs the section names whose files the directory does
    not hold, in the order the section's entries appear, then the jobs whose
    files it holds that the section does not name, in name order. That is the
    order within the disagreements; {!report} keeps it and prints a line for a
    source that was never read ahead of the whole of it, so the order an
    operator sees is stated there and not composed from two places here.

    A job holding both its files under a line that names it is neither, so it is
    absent entirely and the ordinary host answers with nothing.

    [crontab] is the section's own outcome and not a list of names, because what
    is knowable here differs by outcome and a projection to names loses the
    difference. A section nobody read — a spool that never arrived, or markers
    that do not balance — yields nothing at all. The first direction has no name
    to ask about; the second would report every job in the directory as having
    no line firing it, on the strength of a section that was never delivered.
    That is the same claim about a source nobody looked at that a listing which
    was never taken is refused below, and the host it would be made about is the
    one that refuses [sudo -n], which is precisely the host a preserve is
    planned for. A section the host answered that holds no Bondi line at all is
    the opposite case: that host fires none of Bondi's jobs, and files on it are
    a divergence worth naming.

    A listing that was never taken yields nothing either, for the same reason
    and in both directions. A directory the host says is not there is the host's
    answer: every job the section names has lost both files and is named, and
    nothing is reported the other way, because a directory that is not there
    holds no file whose line could be missing.

    A section read whole and a section holding an entry no reader could name are
    also different, and the second direction carries which it was.
    {!Crontab_listing.jobs_read} does not name such an entry — the line fires
    all the same, and it may be the very line firing a job whose files are here
    — so every {!Files_without_a_line} carries the positions of the entries
    nobody could name, empty where the section was read whole. What is claimed
    about the host is then a claim about lines that were actually read, which is
    the same rule the outcomes above are kept apart for. The positions are where
    an operator opens the file, and they are what points at the reconciliation.
*)

val report :
  server:string -> crontab:Crontab_listing.t -> listing -> string list
(** What the preserve found on [server], as the lines to print, in the order to
    print them.

    Empty for the ordinary host: the two sources agree and there is nothing an
    operator has to be told. Silence is therefore meaningful, which is what
    makes the loud cases legible.

    A source that was never read is said out loud and first — the section, then
    the directory — because silence there would read as the two agreeing. Both
    of them going unread is one sentence naming both, and not two: a host that
    refuses a privileged read refuses both reads for the one reason, and the
    caller has already printed that reason above these lines. Either source
    failing on its own keeps a sentence of its own — a section read against a
    directory that was not, and the reverse, are different facts and send an
    operator to different places. A directory the host says is not there adds no
    such line, and neither does a section the host answered holds nothing: those
    are the host answering rather than failing to. Each divergence
    {!divergences} finds then gets the one sentence its own outcome earns, in
    that function's order — the jobs the section names whose files are missing
    before the jobs whose files have no line. At most one unread line is
    possible, so the whole order is that line, if there is one, and then those
    two groups.

    The sentence for a job whose files no line fires is the one that has to be
    chosen with care, because it is the only one making a claim about lines
    rather than about files. Where the section was read whole it says the job
    never runs, which is then true: every line was read and none of them names
    it. Where the section held an entry nobody could name it says instead that
    no line {i that could be read} fires the job, and names the positions to go
    and look at — that entry fires on its schedule, and on a host part-way
    through the migration off the shape an older bondi wrote it is the line
    firing this very job.

    The section's half carries no account of why. That read is not this
    module's, and the caller's own crontab reporting is where what went wrong is
    said; this line says what is consequently not known here. So where the two
    are said together, the account carried is the listing's, and it is attached
    to the clause naming the listing.

    The wording lives here rather than in the caller's interpreter for the
    reason {!Setup_phases.failure_message}'s does: these sentences are the whole
    of what the operator receives, and an arm that builds its own leaves them
    with nowhere to be asserted. *)
