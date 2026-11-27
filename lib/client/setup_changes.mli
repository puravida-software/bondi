(** What a setup run changed on one server, and the one line that says so.

    Public, and a module of its own rather than a part of the setup command,
    because the command has no interface file: its plan and its interpreter are
    reached by tests through the whole module, and the vocabulary its account is
    worded in would otherwise have no signature of its own to be documented and
    held to. Tests read it here, and the command builds its values here.

    Every value below is a fact about Bondi's own containers, files and network.
    Nothing here takes a value read out of a [bondi.yaml] except a managed
    container's name and the version the manifest asks of the orchestrator. The
    version it ran at is the box's own answer, flattened by {!Host_answer}. No
    secret and no other declared value can reach the line it renders. *)

(** Why a container that existed was replaced rather than kept. A version move
    is not among them: only the orchestrator is versioned, and it has
    {!orchestrator_reason} for that. *)
type recreate_reason =
  | Config_changed
      (** The spec it was created from differs from the one this run would
          create. *)
  | No_digest  (** It records no spec digest, so it cannot be compared. *)
  | Image_moved
      (** Its tag names a different image after the pull than the one it runs.
      *)
  | Not_running  (** It existed but was not running. *)
  | Mounted_file_missing
      (** A file it mounts is missing from the host. Only Alloy mounts one. *)

(** Why the orchestrator was replaced: the version it ran differs from the one
    the manifest asks for, or any reason a container can be replaced for. *)
type orchestrator_reason =
  | Version of { running : Host_answer.t; wanted : string }
      (** It ran at [running], which the box reported, and the manifest asks for
          [wanted]. *)
  | Reason of recreate_reason

(** The places a run can correct a value it read back, other than the journal,
    whose correction is {!Journal_provisioned}. *)
type corrected_site =
  | Alloy_config_mode
  | Alloy_env_mode
  | Orchestrator_restart_policy
  | Acme_file_permissions

(** One change a setup run made on a server. A check that found the box already
    right is not a change and has no constructor here. *)
type change =
  | Docker_installed  (** Docker was absent and this run installed it. *)
  | Network_created of string  (** This run created the named network. *)
  | Acme_file_created  (** The ACME file was absent and this run created it. *)
  | Orchestrator_created of string
      (** The orchestrator was absent and this run created it at this version.
      *)
  | Orchestrator_recreated of orchestrator_reason
      (** The orchestrator existed and this run replaced it, for this reason. *)
  | Orchestrator_removed
      (** This run removed the orchestrator and did not start it again: the
          replacement it was the first half of stopped before its run. *)
  | Orchestrator_stopped
      (** This run stopped the orchestrator and a later step that was meant to
          remove or replace it did not complete, so the box is left with a
          stopped container where it had a running one. *)
  | Alloy_created  (** Alloy was absent and this run created it. *)
  | Alloy_recreated of recreate_reason
      (** Alloy existed and this run replaced it, for this reason. *)
  | Alloy_removed
      (** This run removed Alloy's container: it is no longer declared, or the
          replacement the removal began stopped before its run. *)
  | Alloy_stopped  (** As {!Orchestrator_stopped}, for Alloy. *)
  | Alloy_config_removed
      (** Alloy is not declared and this run deleted a configuration directory
          it found on the host. A run that found nothing there changed nothing
          and does not record this. *)
  | Journal_provisioned
      (** The host journal was held in memory and this run made it persistent.
      *)
  | Managed_created of string
      (** The named managed container was absent and this run created it. *)
  | Managed_recreated of string
      (** The named managed container's spec differs from the one declared, and
          this run replaced it. *)
  | Managed_removed of string
      (** This run removed the named managed container: it is no longer
          declared, or the replacement the removal began stopped before its run.
      *)
  | Managed_stopped of string
      (** As {!Orchestrator_stopped}, for the named managed container. *)
  | Corrected of corrected_site
      (** A value this run read back at the site differed from Bondi's, and this
          run corrected it. *)

val of_correction : Setup_phases.correction -> change option
(** The change a line of the correction account stands for.

    A correction at the journal's site is {!Journal_provisioned}, since what was
    corrected there is that the journal is now persistent; one at any other site
    is {!Corrected} at that site. A reading that could not be taken changed
    nothing and is [None]: it keeps its own line in the correction account and
    is not listed as a change. *)

val settled : change list -> change list
(** The changes a run made, with each replacement said once.

    A run records a removal when the container leaves the box and a recreation
    when its successor is started, so a replacement that completed is a removal
    followed, later in the list, by the recreation of the same container. That
    pair is one change, and only the recreation is kept, since it carries the
    reason. A stop is the first step of the same sequence and is folded the same
    way: a stop followed, later in the list, by the removal or the recreation of
    that container is said by that change, and a stop nothing followed is kept,
    since the container is left stopped. A removal nothing recreated is kept:
    the box lost that container, and saying nothing about it would be saying
    nothing happened. Everything else keeps its place and its order. *)

val closing_line : server:string -> change list -> string
(** The line that ends a server's account:
    [setup changed on server <server>: <item>, <item>] with one item per change,
    in the order given, or [setup changed nothing on server <server>] when the
    list is empty.

    The order is the caller's, and is meant to be the order the run made the
    changes in. Nothing is deduplicated or sorted: two entries are two changes.
    Lines, never a verdict: nothing here decides an exit code. *)
