(** The images setup pulls the orchestrator and the log-shipping sidecar from,
    and the pull itself as a command and as a failure.

    Setup used to leave the fetch to [docker run], which runs after the old
    container has been stopped and removed. A registry that is down, or a
    version that was never published, then left the box with no container at
    all. The pull is now its own step ahead of the teardown, and it needs the
    reference it fetches before the plan exists: a reference that cannot be
    fetched refuses the run on a box where nothing has been touched yet.

    A module of its own rather than values in the setup command, because they
    are pure and that command has no interface to document them in. *)

val orchestrator_repository : string
(** The repository the orchestrator is published under, spelled once. *)

val orchestrator :
  version:string -> (Bondi_common.Image_reference.t, string) result
(** [orchestrator ~version] is the orchestrator's published image at [version],
    composed by {!Bondi_common.Image_reference.of_name_and_tag}.

    A version that does not make a tag is refused with a sentence naming
    [bondi_server.version] and echoing the composed text. The release floor
    reads a version only up to its minor number, so a version can clear the
    floor and still not be a tag. *)

val alloy :
  declared:Bondi_common.Image_reference.t option ->
  Bondi_common.Image_reference.t
(** [alloy ~declared] is the sidecar's image: [declared], which is [alloy.image]
    as the configuration decoded it, or {!Bondi_common.Defaults.alloy_image}
    when none is declared. It cannot fail: the configuration refuses a value
    that is not a reference when it is read, and the default is a constant that
    the tests pin as one. *)

val pull_command : Bondi_common.Image_reference.t -> string
(** The [docker pull] for a reference, without the leading [docker], for
    {!Remote_exec.docker_command_output}. The reference is shell-quoted: the
    grammar admits a bracketed IPv6 registry, and an unquoted bracket is a glob
    to the host's shell. *)

val pull_failure : Bondi_common.Image_reference.t -> reason:string -> string
(** [pull_failure reference ~reason] is a failed pull reported as
    [could not pull <reference>: <reason>], with [reason] the host's own words.
    It is the server's wording for its own pulls, so an operator reads one
    sentence for one failure wherever the pull ran. *)
