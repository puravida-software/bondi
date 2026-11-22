(** What the orchestrator and the log-shipping sidecar were created from, as a
    digest setup stamps on each container and reads back on the next run.

    A running container records nothing about how setup created it: not the
    mounts it was given, not the River configuration its sidecar was started
    against. Reading those back field by field needs a normalisation for each
    one, and a field nobody thought to normalise reads as a match. A digest of
    what setup issued cannot drift from what setup would issue, because both
    sides are computed by the same rendering.

    A container created by a setup that stamped no digest carries none, so it
    can never be shown to match. The first setup after an upgrade therefore
    recreates both containers once. *)

val label : string
(** The Docker label key the digest travels in. It is the key the managed
    containers carry their own digest in, taken from the same place rather than
    spelled again, so every container Bondi stamps carries its digest under the
    one key. *)

val hash : run_command:string -> files:string list -> string
(** [hash ~run_command ~files] is a digest over the [docker run] command a
    container is created with and the contents of the files it reads at start,
    in the order given.

    [run_command] is the command as setup renders it, without the {!label} flag,
    which cannot carry a digest of itself, and without the restart policy, which
    [docker update] converges on the running container in place and so is no
    reason to recreate it.

    Every input is bounded before it is digested, so moving text from one input
    to the next, or from the command into the first file, changes the digest:
    two different containers cannot be read as one because their texts happen to
    concatenate to the same bytes. Equal inputs give equal digests, run to run
    and box to box.

    A change-detection digest, not a security primitive. The sidecar's
    credentials file is among its inputs, so a rotated key reads as a change;
    the digest does not reveal what fed it. *)

val label_flag : string -> string
(** [label_flag digest] is the [docker run] flag, with its leading space, that
    stamps [digest] on the container under {!label}. The digest is hex, which no
    shell reads specially, so the flag needs no quoting. *)

val matches : expected:string -> string option -> bool
(** [matches ~expected recorded] is whether a running container's recorded
    digest is [expected], the digest of what setup would create it with. A
    container that recorded none cannot be shown to match, so it never does. *)
