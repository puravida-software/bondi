(** The Bondi-managed section of a host's crontab, read from its spool file.

    The declared cron jobs and the section on the box are different facts, and
    the second is the one nothing currently reports: a run that aborted before
    writing the crontab leaves the two disagreeing, and a host whose section was
    never written at all looks identical to one whose jobs all succeeded.

    Everything this module returns is a count, a job's name, or a position.
    Never a command line and never any part of one.

    The one shape of line it can {e name} is a schedule, a [docker exec] into
    the orchestrator, and the path of the job's run file. That shape holds no
    secret: the job's own values — what it runs, the environment it runs in, the
    credentials that environment carries — are in the run file, beside the line
    rather than in it, and nothing here opens it.

    But the shape it can name is not the shape it can be handed. It reads a
    spool file, which is a file anything may write: another tool's entry, a line
    an operator typed, or the shape Bondi itself wrote before this one, which
    carries the whole job as a single-quoted JSON argument to [curl] with its
    API secrets in plaintext. Those still arrive here — the orchestrator's
    crontab writer migrates them, which it could not do if they were gone — and
    this module cannot tell which shape it is holding until it has already read
    the line. So the rule is not that a line is dangerous; it is that the only
    guarantee available is one that does not depend on knowing.

    Two of the three defences that guarantee once had are still here and the
    third is not. The rule above is kept, and so is the cut {!of_read_output}
    makes at the marker. What went is reading the spool into a shell variable so
    that a read dying part-way through printed no fragment of it: that cost the
    whole file held in the shell's memory before a byte of it was printed, and
    the cut covers the same failure at the boundary instead.

    The shape classifier that told a legacy line from an exec one went with it,
    on a different premise. Such a line is live — a host sits in that state
    between a deploy and the rewrite that migrates it — and it arrives here as
    an {!Unnamed} entry carrying its position and nothing else, which is already
    what a reader can act on: a line that fires, that nobody could name, and
    that the next rewrite replaces. A caller comparing this against the payload
    directory hedges on exactly that, reporting those positions beside the jobs
    it found no line for, so the two readings of one box are offered together
    rather than one of them asserted. What the shape added on top was a label,
    and a label is not a branch.

    [observed] 2026-09-09, a read of all three boxes in the estate found zero
    legacy lines. That bounds how much migration the reports below will be read
    against; it is not a claim that such a line cannot arrive, which is why
    neither the redaction nor the unnamed entry rests on it.

    {!Section}, {!No_section} and {!Malformed} cannot carry a line by
    construction. {!Unreadable} is the one that could: the string it is given is
    a transport's own error, and a transport that failed part-way through a read
    reports the bytes it had already returned.

    What a section read alone cannot see is the other half of a cron job. The
    section is the record of what fires: which lines are there, when they fire,
    and which job's run file each of them reads. It says nothing at all about
    whether those files are on the host. A section naming three jobs reads
    identically whether all three run or all three fail at every fire, and this
    module cannot tell those hosts apart — the payload directory is where that
    is answered, and a caller wanting both facts reads both.

    A job's name is in the path or it is nowhere. It is taken from that path and
    then the path is rebuilt from it, and the line is named only when the two
    are the same string — so what is reported is a name some valid job produces,
    and never a fragment of whatever path a hand-edited line happened to carry.

    It performs no I/O. The caller runs {!read_command} on the server and brings
    the output here, in the same shape as {!Host_inventory} and
    {!Orchestrator_probe}. *)

(** One line of the section, and the whole of what may be said about it.

    A line this module cannot name is still a line -- a shape Bondi wrote before
    this one, or something an operator added by hand, both fire on their
    schedule all the same. Dropping it would report a section smaller than the
    file holds, and the next run rewrites the section and removes exactly those
    lines — so the one report that could have warned about the rewrite would
    instead have agreed with it. The position is the entry's place in the
    section, which is where an operator goes to look at the line itself. *)
type entry =
  | Named of string  (** the job the entry names *)
  | Unnamed of { position : int }
      (** an entry whose job could not be read, counting from one *)

(** What is wrong with the section's markers.

    Each is a defect an operator fixes differently, and none of them is zero
    jobs. Which of the three it is, is the whole of what a report can act on:
    the offending line is found by opening the file, which is what fixing any of
    them starts with. *)
type malformation = Bondi_common.Cron_section.malformation =
  | End_without_begin  (** a section closes that was never opened *)
  | Begin_without_end  (** a section opens and the file ends inside it *)
  | Nested_begin  (** a section opens inside one already open *)

(** The outcome of reading a host's crontab.

    A section that is absent, one that is present and empty, one whose markers
    do not make sense, and a file that could not be read are four different
    facts about a host, and an operator acts differently on each. Collapsing any
    of them into "zero jobs" states that the section is there and holds nothing,
    which is a claim about a file that may never have been written. *)
type t =
  | Section of { entries : entry list }
      (** the markers balance; these are the lines between them *)
  | No_section  (** the file was read and carries no Bondi markers *)
  | Malformed of malformation  (** the markers are there and do not balance *)
  | Unreadable of string  (** the read did not deliver the file *)

val read_command : string
(** The shell command that prints the host's crontab spool file.

    It says on standard output which of three things happened — the file was
    read, it is not there, or it could not be read — and always exits 0. A
    non-zero exit would arrive as an SSH-layer error, which is the same channel
    a dropped connection uses, so the host's answer and the failure to get one
    would again be the same value.

    The read is privileged. The orchestrator writes this file as root into a
    directory only root may traverse, so an unprivileged guard reports "not
    there" for a file that is plainly there — a false claim about the host's
    jobs, made on a host where every job is present. It never waits on a
    password prompt: a read that cannot be taken is an outcome, not a reason to
    hang the report.

    The file is streamed onto standard output as it is read, between a marker
    that announces it and a marker the read's own success prints after its last
    byte. The second is what makes a complete read something the reader is told
    rather than something it infers. The guard only asks whether the file can be
    opened, so a [cat] that then fails — refused by the same sudoers rule that
    permitted the [test], or killed part-way through — would print a truncated
    file, and the command's trailing [exit 0] would leave nothing to say so. The
    closing marker is joined to the read rather than printed after it, so only a
    [cat] that exited 0 prints it; the command still exits 0 either way, which
    is what carries the host's answer through the ssh layer.

    What that attests is the read having run to its end and the stream having
    arrived whole. A failed [cat] and a connection cut mid-transfer both reach
    {!of_read_output} without the closing marker and are reported as a read that
    did not happen, never as a shorter file. What it cannot attest is a file
    whose own last line spells the marker; {!of_read_output} requires the marker
    to stand on a line of its own, which leaves only a file that literally holds
    that line, and a file whose last byte is not a newline runs into the marker
    and reads as a read that did not finish. *)

val of_read_output : (string, Remote_exec.failure) result -> t
(** Read the section out of the output of {!read_command}.

    The argument is the remote call's own outcome rather than a sentence about
    it, so a file that could not be read is distinguishable from one that was
    read and holds no section — and a spool the host read and refused is
    distinguishable from one the host was never asked about. A
    {!Remote_exec.Command_failed} yields an {!Unreadable} saying the read ran on
    the host and failed, which is a permission or a missing file to go and look
    at; every other failure reads as {!Remote_exec.message} renders it, and
    points at the connection instead. Only the lines between the markers are
    read; entries an operator added by hand outside them are neither counted nor
    named, because they are not Bondi's to report on and not Bondi's to
    converge.

    A failure reaches {!Unreadable} as the transport described it, cut at the
    marker {!read_command} prints ahead of the file's first byte. The transport
    reports the bytes it had already returned, and those bytes are spool lines;
    everything from the marker onwards is the file, so the cut is decided by
    where the marker is and not by inspecting what follows it. What is before
    the marker is the transport's own account of what went wrong, which is the
    operator's only pointer to where to go and look, and it is kept whole. *)

val jobs_read : t -> string list option
(** The jobs the section names, in the order its entries appear, or absent when
    there was no section read to name them.

    An entry whose job could not be read is not one of them: the position
    {!Unnamed} carries locates a line for a human to go and look at, and it is
    not a job any other reader can act on.

    {!No_section} answers [Some []] and not [None]. The file was read and holds
    no Bondi line, so nothing on that host fires any of Bondi's jobs — which is
    an answer, and the one a caller comparing this against the payload directory
    most needs, since a host whose section was wiped while its files stayed is
    exactly the divergence worth reporting. {!Malformed} and {!Unreadable}
    answer [None]: the first could hold lines this cannot parse and the second
    was never delivered, so neither supports a claim about what fires there.
    This is the opposite treatment of {!No_section} to {!job_count}'s, which
    counts the entries of a section and has none to count.

    A name comes out of the path the line reads, by
    {!Bondi_common.Cron_exec_line.job_name_of}, which rebuilds the path from the
    name it took and accepts the line only when the two are the same string. A
    line of any other shape names nothing rather than naming whatever fragment
    it happened to carry, and it is still an entry and still counted — so a
    section holding one is an answer that names fewer jobs than it fires, and a
    caller comparing it against the payload directory can report a job's files
    as unfired when an entry nobody could name fires them. That entry is
    reported in its own right, and it is what points at the reconciliation. *)

val job_count : t -> int option
(** How many entries the section holds, when there is a section to count.

    Absent for every other outcome rather than zero: a missing section, broken
    markers and a failed read each leave the number genuinely unknown, and
    answering zero would be a count nothing on the host supports. *)
