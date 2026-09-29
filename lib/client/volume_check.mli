(** Whether the host paths a service mounts exist on a server, asked before the
    deploy is sent to it.

    The daemon refuses a bind mount whose source is missing (see
    [Docker.Client.mount] for the observation), but only when it creates the
    container -- and the simple strategy has already stopped the old one by
    then, so a missing directory found that late is an outage. This is the same
    question asked over SSH while nothing on the box has changed.

    What it holds is the command the box runs, the pure verdict read from what
    came back, and the refusal an operator reads. The runner is the caller's. *)

type verdict =
  | All_present  (** the box ran the check to its end and every path is there *)
  | Missing of string list
      (** the box ran the check to its end and these paths are not there, in the
          order the configuration declares them *)
  | Unreadable of string
      (** the check did not run to its end, or answered in a shape this module
          does not read; the text says which, and why *)

val command : Bondi_common.Bind_mount.t list -> string
(** [command mounts] is the shell command that tests each mount's host path with
    [-e], so a file is as valid a source as a directory, and prints one line for
    each path that is not there.

    Every path is quoted with [Filename.quote], so a path is one word to the
    box's shell whatever it holds. The test is asked as the login user first and
    then under [sudo -n], because the daemon that will mount the path asks as
    root, and a path below a directory the login user cannot traverse is not
    missing. A box that refuses [sudo -n] cannot say what root sees, so a path
    the login user does not see is reported unchecked, which {!val-verdict}
    reads as {!Unreadable}. A path is reported missing only when root was asked
    and says so, and nothing on this path creates, changes or removes anything.

    The command ends by printing a completion marker, and always exits 0. The
    marker is what lets {!val-verdict} tell "checked, and these are missing"
    from "did not run": an empty answer, or one cut short, carries no marker and
    is never read as every path being present. *)

val verdict : (string, Remote_exec.failure) result -> verdict
(** [verdict outcome] reads the outcome of running {!command} on a server.

    A failed call is {!Unreadable}, never {!Missing}, whatever its output says:
    a box that was not reached, or a check that did not finish, has not said
    whether any path is there. Output without the completion marker as its last
    line, or with any line before it that is not a missing path's, is
    {!Unreadable} as well. *)

val refusal : verdict -> (unit, string) result
(** [refusal verdict] is [Ok ()] when every path is present, and otherwise what
    the operator is told, without the server's name, which the caller prefixes.

    A missing path and a check that could not be read are worded apart: one
    sends the operator to create a directory on the box, the other to the
    connection or the box's shell. *)

val refusal_for :
  check:(string -> (string, Remote_exec.failure) result) ->
  Bondi_common.Bind_mount.t list option ->
  (unit, string) result
(** [refusal_for ~check volumes] is what one server's payload is refused for on
    the host paths it mounts, without the server's name.

    A payload that mounts nothing, [None] or [Some []], is not asked about:
    [check] is not called and the result is [Ok ()]. Otherwise [check] is given
    {!command} for the mounts, runs it on the server, and its outcome is read
    through {!val-verdict} and {!val-refusal}. *)
