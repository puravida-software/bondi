(** The Bondi-managed section of a host's crontab, read from its spool file.

    The declared cron jobs and the section on the box are different facts, and
    the second is the one nothing currently reports: a run that aborted before
    writing the crontab leaves the two disagreeing, and a host whose section was
    never written at all looks identical to one whose jobs all succeeded.

    Everything this module returns is a count, a job's name, or a position.
    Never a command line and never any part of one. The spool file holds every
    scheduled job's API secret in plaintext, inside the payload each line hands
    to curl, so a value quoting a line it read would put those secrets into
    standard output, into the operator's scrollback, and into every log and
    transcript of the run.

    {!Section}, {!No_section} and {!Malformed} cannot carry a line by
    construction. {!Unreadable} is the one that could: the string it is given is
    a transport's own error, and a transport that failed part-way through a read
    reports the bytes it had already returned. {!of_read_output} therefore cuts
    that message at the marker {!read_command} prints ahead of the file's first
    byte, so the guarantee holds on the failure paths as well as the successful
    one rather than only on the paths the type closes.

    It performs no I/O. The caller runs {!read_command} on the server and brings
    the output here, in the same shape as {!Host_inventory} and
    {!Orchestrator_probe}. *)

(** One line of the section, and the whole of what may be said about it.

    A line whose job cannot be read is still a line: dropping it would report a
    section smaller than the file holds, and the next run rewrites the section
    and removes exactly those lines — so the one report that could have warned
    about the rewrite would instead have agreed with it. The position is the
    entry's place in the section, which is enough to go and look at the line
    without this module rendering it. *)
type entry =
  | Named of string  (** the job the entry names *)
  | Unnamed of { position : int }
      (** an entry whose job could not be read, counting from one *)

(** What is wrong with the section's markers.

    Each is a defect an operator fixes differently, and none of them is zero
    jobs. Carrying which one rather than a description of the offending line is
    what makes it impossible to report a secret while reporting a defect. *)
type malformation =
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
  | Unreadable of string  (** the file was never read *)

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

    The file is read into a shell variable rather than streamed, so a failure
    part-way through prints no fragment of it. *)

val of_read_output : (string, string) result -> t
(** Read the section out of the output of {!read_command}.

    The argument is the remote call's own result, so a file that could not be
    read is distinguishable from one that was read and holds no section. Only
    the lines between the markers are read; entries an operator added by hand
    outside them are neither counted nor named, because they are not Bondi's to
    report on and not Bondi's to converge.

    An error is cut at the marker that precedes the file's contents before it
    reaches {!Unreadable}. See this module's own description for why. *)

val job_count : t -> int option
(** How many entries the section holds, when there is a section to count.

    Absent for every other outcome rather than zero: a missing section, broken
    markers and a failed read each leave the number genuinely unknown, and
    answering zero would be a count nothing on the host supports. *)
