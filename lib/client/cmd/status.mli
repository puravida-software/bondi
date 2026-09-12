(** The [status] command: what is on every configured server, from both sources.

    The command's own wiring and nothing else. What the orchestrator's answer
    means lives in {!Orchestrator_status}, what the two readings mean together
    lives in {!Status_report}, and both are testable without a server; this
    module reads the configuration, takes the readings and prints. *)

val orchestrator_reading :
  ?session:Remote_exec.session ->
  service_name:string option ->
  Config_file.server ->
  (Status_gather.orchestrator_reading, Status_report.unavailability) result
(** One server's reading from the orchestrator, taken by running the
    orchestrator's own status subcommand inside its container.

    The version the box reports is read first and held to the floor for that
    subcommand's existence. A binary from before there were subcommands does not
    refuse one: it ignores the arguments and starts a second server against a
    port already bound, so a caller that asked anyway would spend its bound on a
    command that was never going to answer. A box below the floor is answered
    with what it reported, what is required and the command that fixes it, as a
    cell in the report rather than as an exit -- this command reports on every
    configured server, and a run that stopped at the first old box would lose
    the account of the ones that are fine.

    Every failed remote read is a source that could not be consulted, including
    one the box ran and refused: what failed is the box's account of why the
    orchestrator could not be reached, and the orchestrator itself said nothing.
    A source that answered unreadably is the other outcome and keeps its own
    name, which is what an older client against a newer orchestrator produces.

    [session] is the staged key the two reads are made over. It is optional so
    that a caller which has not opened one still gets its reading, each read
    opening and closing a session of its own. *)

val cmd : unit Cmdliner.Cmd.t
(** The command as [bondi status]. *)
