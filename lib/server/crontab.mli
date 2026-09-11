(** Management of the Bondi-owned section of root's system crontab.

    Bondi never owns the whole crontab. It owns the lines between a begin and an
    end marker; everything outside that section is preserved verbatim across
    every write.

    A line inside the section has one of two shapes, and each has its own
    reader.

    The shape this module writes is an exec line: a schedule, a [docker exec]
    into the orchestrator running the server binary's [run] subcommand, and the
    path of the job's run file. The line carries no job field and no value.
    {!job_name_from_exec_line} reads it, by taking the name out of that path,
    and the job's image comes from the file the path names — so the two facts
    reported about a job both come from what the deploy wrote.

    The shape it no longer writes is a legacy [curl] line, which carries the
    whole job as a single-quoted JSON argument. Such a line is live and must
    still read: {!merge_bondi_section} replaces a job's entry whichever shape
    held it, so a host sits in that state between a deploy and the rewrite that
    migrates it. What is bounded is how many remain, not whether one can be met
    — [observed] 2026-09-09, a read of all three boxes in the estate found zero
    legacy lines, which is one day's reading of three hosts and not a claim that
    the shape is gone.

    {!json_from_cron_line} and the two extractors above it answer such a line by
    recovering that JSON from it rather than by splitting on whitespace. They
    are readers only; nothing generates this shape any more, and their deletion
    is a later change than this one.

    A line neither reader can resolve is {!Unreadable}, which carries its
    position in the section and never the line. That distinction is the module's
    one hard rule: a legacy line is the job's payload, including its
    credentials, so nothing here may put a line — or any part of one — into a
    value a caller might report. *)

type scheduled_job = { name : string; image : string }
(** A Bondi-managed cron job recovered from the crontab: the job's name and the
    image it runs. Concrete rather than abstract because the status handler
    reports both fields directly. *)

(** A Bondi line as the reader could resolve it.

    A closed variant rather than a [scheduled_job option] for two reasons. The
    compiler makes every consumer answer for the unreadable case, which is the
    case that is silently dropped today; and a line that could not be read is
    still a line, so reporting it as absent both undercounts the section and
    agrees with the next rewrite that would remove it. *)
type listed_job =
  | Job of scheduled_job  (** the job the entry resolves to *)
  | Unreadable of { position : int }
      (** an entry neither reader could resolve, at this place in the section,
          counting from one *)

val equal_listed_job : listed_job -> listed_job -> bool
(** Structural equality on {!listed_job}. *)

val crontab_spool_dir : string
(** Directory holding the system crontab this module writes, inside the server
    container. Cron notices a change by the directory's mtime, not the file's,
    so a caller checking that scheduled jobs can be installed at all must check
    this directory for writability — updating the file alone is invisible to
    cron. *)

val run_payload_of_cron_job : Strategy.Simple.cron_job -> Yojson.Safe.t
(** The job as the run endpoint's request body: exactly the contents of the file
    {!entry_of_cron_job}'s line points at, and nothing else. Encoded from the
    same record the endpoint decodes, so the file cannot carry a field that
    decoder would reject. The job's [secret_env_vars] are not part of it; those
    have their own file, written by {!Cron_secrets.write_env_file}. *)

val entry_of_cron_job : Strategy.Simple.cron_job -> string
(** Render one cron job as a single crontab line: the job's schedule, then a
    [docker exec] into the orchestrator running the server binary's [run]
    subcommand with the job's run file on standard input.

    The line carries a schedule, a command and a path — no job field, no
    environment value and no credential — so the job's values stay out of the
    crontab spool file and out of the argument list of every process the line
    starts. What they do not stay out of is Docker's create-container API, so
    they remain visible in [docker inspect]; the exposure closed here is the
    crontab and the process table.

    The redirection is evaluated inside the container, which is why the command
    is wrapped in [sh -c]. [/etc/bondi/cron] is the orchestrator's own view of
    the job's files; setup bind-mounts the host directory at the same path so a
    rebuilt container does not lose them, and the reader inside the container is
    the only side that has to be right about where they are.

    The name is interpolated into a shell command unescaped, which is safe only
    for a name {!Cron_secrets.is_valid_name} accepts. Callers write the job's
    files first, and that is where the check lives. *)

val generate_bondi_entries : Strategy.Simple.cron_job list -> string list
(** Render the complete Bondi section for the given jobs: the begin marker, one
    line per job, then the end marker. *)

val json_from_cron_line : string -> Yojson.Safe.t option
(** Recover the JSON payload embedded in a legacy [curl] line — the shape Bondi
    wrote before the payload moved to a file. [None] when the line carries no
    payload or the payload does not parse, which is what a line from
    {!entry_of_cron_job} returns.

    Such a line is live, and this reader is part of why: {!merge_bondi_section}
    replaces a job's entry whichever shape held it, which it could not do
    without reading the legacy shape first, so a host sits in that state between
    a deploy and the rewrite that migrates it. What is bounded is how many
    remain, not whether one can be met — [observed] 2026-09-09, a read of all
    three boxes in the estate found zero legacy lines, which is one day's
    reading of three hosts and not a claim that the shape is gone.

    The grammar is {!Bondi_common.Cron_legacy_line}'s, which is where it is
    spelled once for every reader of it; this adds the parse. *)

val job_name_from_cron_line : string -> string option
(** The job name from a crontab line's embedded payload, or [None] when the line
    is not a Bondi line or carries no name. *)

val image_from_cron_line : string -> string option
(** The image from a crontab line's embedded payload, or [None] when the line is
    not a Bondi line or carries no image. *)

val job_name_from_exec_line : string -> string option
(** The job named by a line {!entry_of_cron_job} wrote, taken from the path of
    the run file the line reads.

    [None] for a legacy line and for anything else. The path is accepted only
    when {!Bondi_common.Cron_exec_line.run_file_of} rebuilds it exactly from the
    name read out of it, so the path this answer stands for and the path the
    line carried are the same string, and a line naming its way out of the cron
    directory is not a Bondi line.

    This is {!Bondi_common.Cron_exec_line.job_name_of}, the same reader the
    client uses on a host's spool file, so the shape this module writes and the
    shape either side reads back are one definition. *)

val parse_listed_jobs :
  read_file:(string -> string option) ->
  string list ->
  (listed_job list, string) result
(** Pure: every Bondi entry these crontab lines hold, in order, each resolved as
    far as it can be, or the refusal for a crontab whose markers do not balance.

    An entry written by {!entry_of_cron_job} is resolved by reading the run file
    its line points at: the name comes from the path and the image from the
    file, so both facts come from what the deploy wrote rather than from a line
    a scanner reconstructed. A legacy [curl] line is resolved by
    {!job_name_from_cron_line} and {!image_from_cron_line} against its own
    embedded payload. Anything else — an entry an operator hand-wrote, a line
    whose run file is gone or does not decode, and a run file whose declared job
    disagrees with the directory it sits in — is {!Unreadable}, never dropped.

    [read_file] answers a path with the file's contents, or [None] when there
    are none to be had; it is a parameter so that a missing or malformed run
    file is a value rather than a filesystem. Blank lines inside the section are
    skipped and do not take a position. *)

val list_scheduled_jobs : unit -> (listed_job list, string) result
(** Read the system crontab and return every Bondi-managed entry in it. A
    crontab that does not exist yet reads as no entries rather than as an error;
    an entry that cannot be resolved reads as {!Unreadable} rather than as
    nothing. A crontab whose markers do not balance is the error, carrying
    {!parse_listed_jobs}'s refusal as its message. *)

val merge_bondi_section :
  Strategy.Simple.cron_job list option ->
  string list ->
  (string list, string) result
(** Pure: the crontab {!upsert} writes, given the jobs of a deploy and the lines
    it read, or the refusal for a crontab whose markers do not balance.

    Entries inside the section are addressed by name across both shapes, so a
    job these jobs name replaces whichever shape held it and stands where that
    shape stood. Everything else the section held is emitted as it was read: a
    job not named here keeps its line, and so does a line neither reader names,
    which has no name to be merged by and would otherwise be dropped by every
    rewrite. Jobs the section did not hold follow, in the order given. [None] or
    an empty list removes the section.

    One section is written, whichever number the crontab arrived with. A file
    holding two balanced sections is not malformed and is not refused — it is
    what an earlier reader that matched markers untrimmed left behind — so every
    section's entries are merged into the one this writes and the surplus marker
    pairs go. Left alone, each deploy would update one of them and leave the
    other stale, and cron would fire both.

    A name the section holds more than once is written once: the first entry
    these jobs name is replaced and later entries of that name are dropped. A
    restored crontab backup, or a hand edit applied to half the file, can leave
    a job's legacy line and its exec line side by side, and rewriting each of
    them in place would fire the job twice a schedule.

    Blank lines inside the section are dropped rather than kept: they are
    entries of neither shape, and {!parse_listed_jobs} does not give them a
    position either. *)

val upsert : Strategy.Simple.cron_job list option -> (unit, string) result
(** Merge these jobs into the Bondi section of the system crontab, add or
    replace by job name, and keep both the lines outside the section and any
    Bondi job not named here, each in its original order. The lines outside are
    rewritten trimmed of surrounding whitespace and with blank lines dropped,
    which is the one way the rewrite is not byte for byte. That carve-out is for
    the lines outside and does not extend to the lines inside: an entry the
    merge keeps is written back with the bytes it was read with, including a
    legacy line's whitespace and the order of the fields in its payload. [None]
    or an empty list removes the section entirely — every section, on a crontab
    that somehow holds more than one. On success the crontab file has been
    rewritten with owner-only permissions and the spool directory's mtime bumped
    so cron picks the change up.

    A crontab whose markers do not balance is refused with
    {!merge_bondi_section}'s message and nothing is written: which lines are
    Bondi's is exactly what such a file does not say, and a rewrite that guessed
    would leave a job's old line outside the markers and its new one inside,
    both firing. *)
