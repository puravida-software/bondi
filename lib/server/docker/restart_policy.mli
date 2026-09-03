(** The restart policy Bondi puts on the containers it starts itself.

    Docker's default is to leave a container down after the daemon stops, so a
    host reboot or a Docker upgrade quietly removes the reverse proxy and the
    deployed service. Nothing in a user's configuration asks for these
    containers, so nothing in it can declare their policy either — Bondi names
    it here instead, once, so the sites that start those containers cannot drift
    apart. *)

val bondi_managed : Client.restart_policy
(** [unless-stopped], shaped as the Engine API's [Client.restart_policy] record.
    Restarts the container whenever the daemon starts, unless an operator
    stopped it by hand. No maximum retry count: Docker accepts one only for
    [on-failure] [observed — 2026-09-02]. *)

val applied_matches : Client.restart_policy option -> bool
(** Whether the policy the daemon reports on a running container is the one
    Bondi applies. Compared on the name alone: the Engine reports a
    [MaximumRetryCount] of [0] on every container, including policies that
    cannot carry one [observed — 2026-09-02], so a whole-record comparison
    against [bondi_managed] would report a difference on a container that is
    already compliant.

    A container the daemon reports no policy for is a mismatch, not a pass. An
    unreadable answer is not agreement, and correcting a container that needs no
    correction costs nothing — the update is idempotent and does not restart it.
*)

val of_inspect :
  (Client.inspect_response, string) result -> Client.restart_policy option
(** The policy to compare against, read out of an inspect that may itself have
    failed. An inspect Bondi could not make answers [None] — the same answer as
    a daemon reporting no policy, which [applied_matches] already refuses to
    read as agreement — so a read that failed converges the container rather
    than stopping the caller that needed the read. The failure is not swallowed:
    the caller holds the error and logs it. *)
