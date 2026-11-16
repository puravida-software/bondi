(** Whether journald on a server stores its journal persistently, and what setup
    does about it when it does not.

    Alloy reads a cron container's lines from the host journal under
    {!Alloy_run_args.journal_path}. On a box where journald keeps its journal in
    memory only, that path holds nothing for this machine, and an Alloy started
    against it reads nothing and says nothing. So before setup starts Alloy it
    reads the journal's storage, provisions persistent storage where there is
    none, and reads it again.

    What it holds is the command the box runs, the reading taken from what came
    back, the commands that reading calls for, and what a reading taken after
    those commands means. It performs no I/O: the runner is the caller's. *)

type reading =
  | Present
      (** the box has a journal directory for its own machine id under
          {!Alloy_run_args.journal_path}, which journald creates only when it
          stores persistently *)
  | Absent
      (** the box answered, and has no such directory: journald keeps the
          journal in memory *)
  | Undetermined of string
      (** the probe did not run, or answered in a shape this module does not
          read; the text says which *)

val probe_command : string
(** [probe_command] is the shell command that asks whether
    [/var/log/journal/<machine-id>] exists, and always exits 0, saying which on
    standard output. A box with no machine id says so by its own marker, and a
    [sudo] that fails prints its own error, so neither reads as absent.

    The bare directory is not enough. With [Storage=volatile] in [journald.conf]
    the directory can exist and stay empty, so only the directory named for this
    machine shows that journald is writing there. The test is run under [sudo],
    because a directory the login user cannot traverse is not absent. *)

val reading_of_probe : (string, string) result -> reading
(** [reading_of_probe outcome] reads the outcome of running {!probe_command}.

    The trimmed output must be exactly one of the probe's markers. A failed call
    is {!Undetermined}, and so is a missing machine id and any other answer: a
    box that was not reached, or that said nothing, has not said where its
    journal is. *)

type plan =
  | Nothing_to_do  (** the journal is already stored persistently *)
  | Provision_then_recheck of string list
      (** run these commands in order, stopping at the first that fails, then
          read the storage again with {!probe_command} and pass that reading to
          {!recheck} *)

val plan : reading -> (plan, string) result
(** [plan reading] is what setup does about the storage it read.

    {!Present} plans nothing. {!Absent} plans persistent storage: create
    {!Alloy_run_args.journal_path}, have [systemd-tmpfiles] give it journald's
    ownership and mode, and restart [systemd-journald] so it moves its journal
    there. An {!Undetermined} reading is an [Error] naming the path: setup does
    not restart a box's journald on a question it could not get answered. The
    message does not name the server, which the caller does. *)

val recheck : reading -> (unit, string) result
(** [recheck reading] is what the reading taken after provisioning means.

    {!Present} is [Ok ()]. {!Absent} is an [Error] that names
    {!Alloy_run_args.journal_path} and the setting that keeps the journal out of
    it, because an Alloy started now would read an empty journal. An
    {!Undetermined} reading is an [Error] as well. The message does not name the
    server, which the caller does. *)
