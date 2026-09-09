(** Whether the orchestrator a box is running can execute the command Bondi
    writes into its crontab.

    A generated cron line runs [bondi-server run] inside the orchestrator
    container. That subcommand arrived in 0.15.0; an older image ignores its
    arguments entirely and starts a second server against a port already bound,
    so a line written against one of those boxes does not fail at deploy time
    when someone is watching -- it fails at its next fire, which is 3am on a box
    nobody is looking at.

    This module exists so the check is a pure, tested decision made against the
    version the box itself reports, taken before the deploy is posted rather
    than discovered by a cron job later. It performs no I/O: the caller reads
    the orchestrator's image over SSH and passes what it found here. *)

val minimum_for_exec_lines : string
(** The oldest orchestrator release that carries the [run] subcommand.

    Named so that a caller reporting the requirement and the caller deciding
    against it cannot drift apart. *)

val orchestrator_version_of_image : string -> string
(** [orchestrator_version_of_image image] is the version an orchestrator image
    reports, read from its tag.

    An image published under Bondi's own name answers with its tag alone. Any
    other -- a fork, a locally built image, a mirror -- is still the
    orchestrator by name, and is answered with the whole image string rather
    than a guess at which part of it is a version. That string carries no
    recognisable version, so {!supports_run_subcommand} refuses it and names it,
    which is what lets an operator recognise what their box is running.

    Total by construction: every string is either a published tag or something
    reported as it stands, and there is no arm that fails. *)

val supports_run_subcommand : string -> (unit, string) result
(** [supports_run_subcommand version] decides whether an orchestrator reporting
    [version] can execute a generated cron line.

    The comparison is an ordering, not an equality: everything from
    {!minimum_for_exec_lines} upwards is accepted. Comparing for equality would
    refuse every release but one, and comparing the strings would refuse 0.9.0
    correctly and accept it for the wrong reason while getting 0.100.0 wrong.

    Returns an error naming what the box reported, what is required, and the
    command that fixes it, so an operator can act on it without reading the
    source. A version with no recognisable ordering in it -- an empty answer
    from a box with no orchestrator running, a [latest] tag, a fork's image name
    -- is a refusal rather than a pass: an unreadable answer is not evidence of
    an image that can run the line, and the error quotes what the box actually
    said. *)
