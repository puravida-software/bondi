(** Whether a server's [curl] can run the crontab lines an older Bondi wrote.

    The line this Bondi writes carries no curl at all: it is a [docker exec]
    into the orchestrator, and [docker exec] exits with the status of the
    command it ran, so a failed run is a non-zero line and cron mails it. That
    is what the curl flags used to buy.

    Lines written before that change are [curl] invocations carrying
    [--fail-with-body], so that a failed run exits non-zero {i and} carries the
    server's explanation into cron's mail. A deploy replaces only the lines for
    the jobs it names, so those lines survive on a host until each job is
    deployed again -- and they keep firing on their schedule meanwhile. That is
    what this check now guards, and the only thing it guards.

    [--fail-with-body] arrived in curl 7.76.0; an older curl rejects it as
    unknown and exits before issuing the request, which would break every such
    job on the host at once. The check outlives the shape that motivated it
    because the lines do: it is kept on the whole cron path rather than narrowed
    to hosts observed to hold one, since [setup] does not read the crontab and a
    gate on its way out is not worth a new read. When the reader for those lines
    is deleted, this check is deleted with it.

    This module exists so that the check is a pure, tested decision made against
    the host's own [curl --version] output, run once at setup time rather than
    discovered by a cron job at 3am. It performs no I/O -- the caller obtains
    the output over SSH and passes it here. *)

val supports_fail_with_body : string -> (unit, string) result
(** Decide whether the output of [curl --version] describes a curl new enough
    for the legacy crontab lines.

    Accepts output whose version is 7.76.0 or later. Returns an error naming
    both what the host reported and what is required, and both ways out -- a
    newer curl, or re-deploying every cron job on the host so that no line
    needing one is left -- so the operator can act on it without consulting the
    source. Output that carries no recognisable version — an empty string, or a
    shell's "command not found" — is a rejection rather than a pass: an
    unreadable answer is not evidence of a usable curl, and the error quotes
    what the host actually said. *)
