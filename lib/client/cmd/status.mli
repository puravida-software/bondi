(** The [status] command: what is on every configured server, from both sources.

    The command's own wiring and nothing else. What the orchestrator's answer
    means lives in {!Orchestrator_status}, what the two readings mean together
    lives in {!Status_report}, and both are testable without a server; this
    module reads the configuration, opens a scheduler, and prints. *)

val orchestrator_reading_standalone :
  service_name:string option ->
  Config_file.server ->
  (Status_gather.orchestrator_reading, Status_report.unavailability) result
(** One server's reading from the orchestrator, taken under an Eio loop this
    call opens and closes for itself.

    [setup] runs no scheduler: it spends its time in [ssh] and calls [exit] on
    several paths, and wrapping the whole of it in one to obtain a single HTTP
    response would change the process shape of a command that needs none of it.
    The loop here lives exactly as long as the fetch does.

    This is a deviation from the rule that an Eio loop is opened once, at the
    program's entry point, and it holds only while nothing calls this from
    inside a fiber — {!Eio_main.run} cannot be nested, and nothing in the types
    will say so. The day [setup] or a shared CLI entry point runs under a loop
    of its own, this has to become a function taking [env] instead. *)

val cmd : unit Cmdliner.Cmd.t
(** The command as [bondi status]. *)
