(** Secret environment for cron jobs, kept out of the crontab.

    A cron job's [env_vars] are inlined into the [curl -d] argument of its
    crontab line (see [Crontab]). That is fine for [RUN_ENV=paper] and wrong for
    a brokerage API key: the value comes to rest in
    [/var/spool/cron/crontabs/root], and appears in the process argument list —
    readable through [/proc] — every time cron fires.

    [secret_env_vars] are written instead to a mode-600 file under
    [/etc/bondi/cron/<job>/] at deploy time and read back when the job runs, so
    no credential is in the crontab and none reaches any command line. This is
    the same treatment {!Bondi_common.Managed_container} already gives managed
    containers; cron jobs and services predate it.

    What this does NOT do: the value is passed to Docker's create-container API
    and is therefore visible in [docker inspect] and on disk under
    [/var/lib/docker]. Anything with root on the box reads it either way. The
    exposure this closes is the crontab and the process table. *)

val dir_of : string -> string
(** The per-job config directory, [/etc/bondi/cron/] followed by the job name.
    Only meaningful for a name accepted by {!is_valid_name}. *)

val env_file_of : string -> string
(** Path to the job's secret environment file inside {!dir_of}. *)

val is_valid_name : string -> bool
(** Whether a job name is safe to interpolate into a path.

    A job name arrives over the network in a deploy payload and is placed into a
    path that is written and removed, so a name containing a separator or a
    leading dot must not be representable. Same rule as a managed container's
    name, for the same reason. *)

val file_contents : (string * string) list -> string
(** One [KEY=value] line per entry, in order, each newline-terminated. *)

val parse_file : string -> (string * string) list
(** Read back what {!file_contents} wrote. Blank lines and lines without an [=]
    are skipped; the value may itself contain [=] and is not split further. *)

val merge :
  plain:(string * string) list -> secret:(string * string) list -> string list
(** The container's [Env] list, [KEY=value] strings. [secret] wins on a
    duplicate key, because a key declared in both is a value the operator
    intended to keep out of the crontab. *)

val write_env_file :
  name:string -> (string * string) list -> (unit, string) result
(** Create {!dir_of} and write {!env_file_of} at mode 600.

    The file is created with the mode already applied rather than chmod'd
    afterwards: between an [open] and a [chmod] the credential is world-readable
    on disk, and that window is the whole point of the file. Always written,
    even when there are no secrets, so that withdrawing a credential truncates
    it rather than leaving the last one behind. *)

val read_env_file : string -> (string * string) list
(** The job's secrets, or the empty list when the file is absent or unreadable.

    Absence is not an error: a job deployed before this existed has no file, and
    it should run with whatever the crontab carries rather than fail. *)
