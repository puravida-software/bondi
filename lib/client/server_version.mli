(** Whether the orchestrator a box is running is new enough for what the client
    is about to ask of it.

    There are two floors here, not one, because there are two capabilities and
    they arrived a release apart. Reading them as one number refuses boxes that
    work, or accepts boxes that answer with silence; both have happened.
    {!answers_command_surface} names the earlier and weaker one -- a binary with
    subcommands, which is what a command reaching the box over [docker exec]
    needs. {!writes_exec_lines} names the later and stronger one -- a server
    that writes the exec-shaped cron line and the run file beside it. A box can
    satisfy the first and not the second, and that is the normal case for one
    release, not a corner.

    A generated cron line runs [bondi-server run] inside the orchestrator
    container. That subcommand arrived in 0.15.0; an older image ignores its
    arguments entirely and starts a second server against a port already bound,
    so a line written against one of those boxes does not fail at deploy time
    when someone is watching -- it fails at its next fire, which is 3am on a box
    nobody is looking at.

    Writing the line is the later capability, and it is the one this gate is set
    to. The deploy that rewrites a box's crontab runs on the box, so a release
    that can execute a generated line while its own writer still emits the
    legacy curl shape answers the deploy with success and changes nothing. That
    describes 0.15.0 exactly, which is why the floor is 0.16.0 rather than the
    release the subcommand arrived in.

    This module exists so the check is a pure, tested decision made against the
    version the box itself reports, taken before the deploy is posted rather
    than discovered by a cron job later. It performs no I/O: the caller reads
    the orchestrator's image over SSH and passes what it found here. *)

val minimum_for_exec_lines : string
(** The oldest orchestrator release whose server writes exec lines and run
    files.

    Named so that a caller reporting the requirement and the caller deciding
    against it cannot drift apart. *)

val orchestrator_version_of_image : string -> string
(** [orchestrator_version_of_image image] is the version an orchestrator image
    reports, read from its tag.

    An image published under Bondi's own name answers with its tag alone. Any
    other -- a fork, a locally built image, a mirror -- is still the
    orchestrator by name, and is answered with the whole image string rather
    than a guess at which part of it is a version. That string carries no
    recognisable version, so {!writes_exec_lines} refuses it and names it, which
    is what lets an operator recognise what their box is running.

    Total by construction: every string is either a published tag or something
    reported as it stands, and there is no arm that fails. *)

val writes_exec_lines : string -> (unit, string) result
(** [writes_exec_lines version] decides whether an orchestrator reporting
    [version] is one whose own server writes exec lines and run files -- not
    whether it can execute a generated cron line, which is the earlier and
    weaker capability.

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

val minimum_for_command_surface : string
(** The oldest orchestrator release whose server binary carries subcommands.

    Distinct from {!minimum_for_exec_lines}, and lower: writing an exec line is
    the later and stronger capability, and a box that answers a deploy or a
    status perfectly well would be refused by that floor. Named for the same
    reason the other floor is -- so the caller reporting the requirement and the
    caller deciding against it cannot drift apart. *)

val answers_command_surface : string -> (unit, string) result
(** [answers_command_surface version] decides whether an orchestrator reporting
    [version] is one whose binary has subcommands to answer with, which is what
    a client reaching it by running a command inside its container requires.

    Refuses in the same shape as {!writes_exec_lines}: what the box reported,
    what is required, and the command that fixes it. The comparison is the same
    ordering against the same reading of a version, so the two gates cannot
    disagree about an answer neither can read: an empty answer from a box with
    no orchestrator running, a [latest] tag, or a fork's image name is a refusal
    rather than a pass, because an unreadable answer is not evidence of a binary
    that has the subcommand.

    A box below this floor does not fail loudly on its own: its binary ignores
    the arguments and starts serving, so the caller waits on a command that was
    never going to answer. That is what this gate is taken before the call to
    avoid. *)
