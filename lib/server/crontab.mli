(** Management of the Bondi-owned section of root's system crontab.

    Bondi never owns the whole crontab. It owns the lines between a begin and an
    end marker; everything outside that section is preserved verbatim across
    every write. Each Bondi line is a [curl] invocation that posts a JSON
    payload to the server's run endpoint, so the job definition and the line
    that schedules it are the same piece of data — which is why the parsers
    below read a line by recovering the JSON from it rather than by splitting on
    whitespace. *)

type scheduled_job = { name : string; image : string }
(** A Bondi-managed cron job recovered from the crontab: the job's name and the
    image it runs. Concrete rather than abstract because the status handler
    reports both fields directly. *)

val equal_scheduled_job : scheduled_job -> scheduled_job -> bool
(** Structural equality on {!scheduled_job}. *)

val crontab_spool_dir : string
(** Directory holding the system crontab this module writes, inside the server
    container. Cron notices a change by the directory's mtime, not the file's,
    so a caller checking that scheduled jobs can be installed at all must check
    this directory for writability — updating the file alone is invisible to
    cron. *)

val escape_for_shell : string -> string
(** Escape single quotes in a string so it survives inside a single-quoted shell
    argument, rendering each quote as the usual close-escape-reopen sequence. *)

val entry_of_cron_job : Strategy.Simple.cron_job -> string
(** Render one cron job as a single crontab line: the job's schedule followed by
    a [curl] call carrying the job as JSON. The line is built so that the first
    occurrence of the payload flag is the payload itself — nothing may be
    inserted ahead of it that introduces the same sequence, or
    {!json_from_cron_line} will read the wrong span. *)

val generate_bondi_entries : Strategy.Simple.cron_job list -> string list
(** Render the complete Bondi section for the given jobs: the begin marker, one
    line per job, then the end marker. *)

val json_from_cron_line : string -> Yojson.Safe.t option
(** Recover the JSON payload embedded in a crontab line written by
    {!entry_of_cron_job}. [None] when the line carries no payload or the payload
    does not parse. *)

val job_name_from_cron_line : string -> string option
(** The job name from a crontab line's embedded payload, or [None] when the line
    is not a Bondi line or carries no name. *)

val image_from_cron_line : string -> string option
(** The image from a crontab line's embedded payload, or [None] when the line is
    not a Bondi line or carries no image. *)

val parse_bondi_section : string list -> string list * (string * string) list
(** Split crontab lines into the lines outside the Bondi section and the named
    Bondi entries, each paired with its full line. Markers are dropped. Lines
    inside the section whose payload yields no job name are dropped too: they
    cannot be addressed by name on the next upsert. Both lists keep their
    original order. *)

val parse_scheduled_jobs : string list -> scheduled_job list
(** Pure: the Bondi-managed jobs described by these crontab lines. Entries whose
    payload carries no image are omitted. *)

val list_scheduled_jobs : unit -> (scheduled_job list, string) result
(** Read the system crontab and return every Bondi-managed job in it. A crontab
    that does not exist yet reads as no jobs rather than as an error. *)

val upsert : Strategy.Simple.cron_job list option -> (unit, string) result
(** Merge these jobs into the Bondi section of the system crontab, add or
    replace by job name, and keep both the lines outside the section and any
    Bondi job not named here, each in its original order. The lines outside are
    rewritten trimmed of surrounding whitespace and with blank lines dropped,
    which is the one way the rewrite is not byte for byte. [None] or an empty
    list removes the section entirely. On success the crontab file has been
    rewritten with owner-only permissions and the spool directory's mtime bumped
    so cron picks the change up. *)
