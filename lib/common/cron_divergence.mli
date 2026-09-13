(** Where a host's Bondi crontab section and its cron payload directory
    disagree, and what closes each disagreement.

    Two sources describe the same set of scheduled jobs: the section of the
    host's crontab that Bondi owns, which says what fires, and the payload
    directory, which holds what a firing line runs. Either can survive the
    other. A container recreated without its files leaves lines firing nothing;
    a directory restored under a crontab that was replaced leaves files nothing
    fires.

    {!divergences} is the rule, and it is pure: it takes the two name lists and
    nothing else -- no path, no transport, no filesystem -- so a box that reads
    both sources locally and a client that reads them over a connection could
    reach the same verdict from the same code rather than from two that drift.
    That is why it lives in the shared library: the client library may not
    depend on the server's, and a comparison each end wrote for itself is a
    comparison that can disagree about the same host. {!remedy} is the wording
    rather than the rule, and it does take paths, for the reason its own
    docstring gives.

    Only the box reads it today. The client still runs the comparison it already
    had, over the same two sources read as commands, and that one answers a
    wider question: it requires a job to hold {e both} its run file and its env
    file, and reports the job that holds one of the two and not the other. This
    rule has no such outcome -- a job holding one of its two payload files is a
    job the payload directory names, so both directions here are silent about
    it. A host this rule calls quiet is therefore not yet a host both ends call
    quiet.

    It compares names and nothing else. Which of a job's files are missing --
    the outcome the client reports and this rule does not -- and where in the
    section its line sits, are questions a caller holding the sources can answer
    and this module deliberately cannot: the answer differs by how the source
    was read, and a shared rule that took a reading's shape would have to take
    both ends' readings. *)

(** A disagreement between the two sources, in whichever direction it runs.

    A job that both sources name is neither of these and is absent entirely, so
    the ordinary host yields nothing at all and silence is a fact rather than
    the absence of one. *)
type t =
  | Line_without_files of { job : string }
      (** the section fires [job] and the payload directory holds nothing under
          that name, so the line runs a job whose files are gone *)
  | Files_without_a_line of { job : string }
      (** the payload directory holds [job]'s files and no line in the section
          fires them, so the job never runs *)

val divergences :
  crontab_jobs:string list option -> payload_jobs:string list option -> t list
(** Where the two sources disagree about [crontab_jobs] and [payload_jobs], the
    names each one holds: the jobs the crontab section fires, and the jobs the
    cron payload directory holds files for.

    [None] is a source that was never read -- a crontab that could not be
    opened, markers that do not balance, a directory listing that failed. It
    yields nothing in either direction, and that is the whole of the answer for
    that host: the direction that asks about the unread source has no name to
    ask about, and the other would report every job in the source that was read
    as diverging, on the strength of an answer nobody received. [Some []] is the
    opposite and is an answer: a section holding no Bondi line fires none of
    Bondi's jobs, and files on that host are a divergence worth naming.

    The lines whose files are gone come first, in the order the section names
    them, and then the jobs whose files no line fires, in name order. A caller
    printing the list unchanged therefore prints the same host the same way
    twice, and the two ends print it the same way as each other. *)

val remedy : crontab_path:string -> payload_dir:string -> t -> string
(** What closes the divergence, as the sentence to report, where [crontab_path]
    is the file the section lives in on the host being described and
    [payload_dir] is the directory the payload files were listed from.

    The wording lives here rather than with each caller that reaches this rule,
    so that two of them cannot describe the same disagreement differently. It is
    not yet the only wording in the repository: the client's own comparison
    carries sentences of its own, written for a report that names a server and
    covers outcomes this rule does not have. Both paths are parameters rather
    than constants of this module because each end already holds them for the
    reads it performs, and a third spelling here is one more value nobody can
    detect the drift of -- a sentence naming a directory the reader never opened
    describes some other host.

    The two directions do not close the same way, and the asymmetry is the
    reason this function exists at all. A job whose files are present and whose
    line is missing is written by an ordinary deploy of that service, so the
    sentence names it. A line whose files are gone has no command that clears
    it: the writer merges rather than replaces, deliberately, so that a job it
    was not told about keeps its line -- which means a deploy of any other
    service preserves the stale entry, and so does removing the job from the
    configuration, because a job nobody names is exactly the case that carve-out
    protects. The only lever that removes it removes the whole section with it.
    So that sentence says plainly that no command clears it and names the file
    to open instead. Naming a command that would not work is worse than naming
    none: an operator runs it, watches the line survive, and stops believing the
    report. *)
