(** A cron job's on-disk definition, kept out of the crontab.

    A job's directory [/etc/bondi/cron/<job>/] holds two files, both mode 600
    and both written at deploy time: [env], the job's [secret_env_vars], and
    [run.json], the run payload. Neither travels in the crontab line.

    The whole job used to travel in the line, as a single-quoted JSON argument
    to [curl]. That is fine for [RUN_ENV=paper] and wrong for a brokerage API
    key: the value comes to rest in [/var/spool/cron/crontabs/root], and appears
    in the process argument list — readable through [/proc] — every time cron
    fires. The secrets moved out first and the rest of the payload followed.
    This is the same treatment {!Bondi_common.Managed_container} already gives
    managed containers; cron jobs and services predate it.

    What this does NOT do: the values are passed to Docker's create-container
    API and are therefore visible in [docker inspect] and on disk under
    [/var/lib/docker]. Anything with root on the box reads it either way. The
    exposure this closes is the crontab and the process table. *)

val dir_of : string -> string
(** The per-job config directory, [/etc/bondi/cron/] followed by the job name.
    Only meaningful for a name accepted by {!is_valid_name}. *)

val env_file_of : string -> string
(** Path to the job's secret environment file inside {!dir_of}.

    This is {!Bondi_common.Cron_exec_line.env_file_of} rather than a second way
    of spelling the same path, for the reason {!run_file_of} gives and for one
    more: the client looks for this file to tell whether a job survived a
    rebuilt orchestrator, and it cannot look for a name written only here. *)

val run_file_of : string -> string
(** Path to the job's run payload file inside {!dir_of}, beside {!env_file_of}.
    Only meaningful for a name accepted by {!is_valid_name}.

    This is {!Bondi_common.Cron_exec_line.run_file_of} rather than a second way
    of spelling the same path: the file written here and the file the crontab
    line names are one path by construction. *)

val is_valid_name : string -> bool
(** Whether a job name is safe to interpolate into a path.

    A job name arrives over the network in a deploy payload and is placed into a
    path that is written and removed, so a name containing a separator or a
    leading dot must not be representable.

    This is {!Bondi_common.Managed_container.is_valid_name} rather than that
    rule written out a second time, so a cron job and a managed container cannot
    come to disagree about what a name may hold. *)

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

val write_run_file : name:string -> Yojson.Safe.t -> (unit, string) result
(** Create {!dir_of} and write {!run_file_of} at mode 600.

    Created with the mode already applied rather than chmod'd afterwards, for
    the reason {!write_env_file} gives: between an [open] and a [chmod] the
    payload is world-readable on disk, and that window is the whole point of the
    file. Truncating, so a field withdrawn from the job does not survive in the
    tail of the old file.

    The name is checked before any I/O, so a name that could escape the job's
    directory is refused rather than written. The error names the file's path
    and never its contents: the contents are the payload this file exists to
    keep out of the crontab, and this text is returned over HTTP and mailed by
    cron. *)

val read_env_file : string -> (string * string) list
(** The job's secrets, or the empty list when the file is absent or unreadable.

    Absence is not an error: a job deployed before this existed has no file, and
    it should run with whatever the crontab carries rather than fail. *)
