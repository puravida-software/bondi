(** Whether a server's [curl] can run the command Bondi writes into its crontab.

    The generated crontab line uses [--fail-with-body], so that a failed run
    exits non-zero {i and} carries the server's explanation into cron's mail.
    That option arrived in curl 7.76.0; an older curl rejects it as unknown and
    exits before issuing the request, which would break every scheduled job on
    the host at once.

    This module exists so that the check is a pure, tested decision made against
    the host's own [curl --version] output, run once at setup time rather than
    discovered by a cron job at 3am. It performs no I/O — the caller obtains the
    output over SSH and passes it here. *)

val supports_fail_with_body : string -> (unit, string) result
(** Decide whether the output of [curl --version] describes a curl new enough
    for the crontab command.

    Accepts output whose version is 7.76.0 or later. Returns an error naming
    both what the host reported and what is required, so the operator can act on
    it without consulting the source. Output that carries no recognisable
    version — an empty string, or a shell's "command not found" — is a rejection
    rather than a pass: an unreadable answer is not evidence of a usable curl,
    and the error quotes what the host actually said. *)
