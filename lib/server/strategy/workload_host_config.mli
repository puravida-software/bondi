(** The Docker host config of a deployed service's container.

    Every strategy starts the service's container from this one function, so the
    containers of one deploy cannot disagree on what they mount: the simple
    strategy's container and both colours of a blue-green switch get the same
    value for the same volumes. *)

val of_volumes :
  Bondi_common.Bind_mount.t list option -> Docker.Client.host_config
(** One [Type = "bind"] mount per volume, in the order declared, each with its
    host path as the source, its container path as the target, and its read-only
    flag. [None], as a deploy input that declares no volumes carries, is the
    same as [Some []]. With no volumes there is no [Mounts] key at all, so the
    host config is exactly the one a service's container got before volumes
    existed.

    The restart policy is [Docker.Restart_policy.bondi_managed] either way, and
    [Binds] is never set: a [Binds] entry creates a missing host path instead of
    refusing it (see [Docker.Client.mount] for the observation). *)
