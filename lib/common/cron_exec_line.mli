(** The crontab line the orchestrator writes for a cron job, and the run file
    that line names.

    The line carries a schedule, a command and a path — no job field, no
    environment value and no credential. The job's payload lives in the file the
    path names, so the only thing a reader can recover from the line is the
    name, and it recovers it from the path.

    Both libraries need this grammar: the server writes the line and reads it
    back, and the client reads a host's spool file to report what is scheduled
    there. It lives here so that neither can drift from the other — a change to
    the emitted command that left one of them behind would leave every scheduled
    job reported as unnamed while the whole suite stayed green.

    The directory the run files live under is here for the same reason: the
    writer of the files and the writer of the line must name the same path or
    the line points at nothing. *)

val cron_root : string
(** The directory a cron job's files live under, one directory per job. It is a
    path inside the orchestrator container; setup bind-mounts the host directory
    at the same path so a rebuilt container does not lose them. *)

val run_file_of : string -> string
(** The path of a job's run payload file, under {!cron_root}. Only meaningful
    for a name accepted by [Managed_container.is_valid_name]. *)

val exec_marker : string
(** The part of the line that precedes the run file's path: the server binary's
    [run] subcommand and the redirection into it. Written by the line's
    generator and searched for by both readers, so the shape they agree on is
    one string. *)

val job_name_of : string -> string option
(** The job named by a line carrying {!exec_marker}, taken from the path of the
    run file the line reads.

    [None] for a line of any other shape. The path is accepted only when
    {!run_file_of} rebuilds it exactly from the name read out of it, so the path
    this answer stands for and the path the line carried are the same string,
    and a line naming its way out of {!cron_root} names nothing rather than
    reporting a job called after somebody else's directory. *)
