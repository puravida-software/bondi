(** Taking the report's readings off a server.

    The thin impure half of the report: it runs the reads and hands back what
    each one returned, including the ones that failed. Nothing here decides what
    a reading means — that a container is missing, that the sources disagree,
    that a section was never written — because every one of those decisions is a
    claim about the box and belongs where it can be tested against plain data.

    The five reads are independent on purpose. Each carries its own outcome, so
    a host that answered about its containers and refused its crontab reports
    both of those facts rather than one summary that is true of neither. *)

type orchestrator_reading = {
  components : Status_report.component list;
      (** what it says is on the box, named as the host names it *)
  warnings : string list;
      (** what it reported alongside them, in its own words *)
}
(** What the orchestrator answered about itself. *)

type reading = {
  docker : Host_inventory.t;  (** the host's own containers, over SSH *)
  crontab : Crontab_listing.t;  (** the Bondi section of the host's crontab *)
  payloads : Cron_payload.listing;
      (** what the host's payload directory holds, or why that is not known —
          which is the half of a host's cron state no crontab read can see *)
  orchestrator : (orchestrator_reading, Status_report.unavailability) result;
      (** the orchestrator's account, or why there is none — which distinguishes
          a source that was never reached from one that answered unreadably *)
}
(** Everything one server was asked, and what came back. *)

val reading_of_reads :
  listing:(string, Remote_exec.failure) result ->
  inspection:(string, Remote_exec.failure) result ->
  crontab:(string, Remote_exec.failure) result ->
  payloads:(string, Remote_exec.failure) result ->
  orchestrator:(orchestrator_reading, Status_report.unavailability) result ->
  reading
(** Assemble a reading from the outcome of each read.

    Every argument is the call's own outcome rather than a sentence about it, so
    a read that never happened stays distinguishable from one that answered and
    found nothing, and a host that answered badly stays distinguishable from one
    that was never reached. Each of the four is handed to the module that owns
    that reading, and each of those decides for itself what a
    {!Remote_exec.failure} means for the thing it reports. This is the single
    place those five outcomes are turned into the report's own vocabulary, which
    is why it is a function rather than five lines inside {!gather}: it can be
    checked without a host. *)

val gather :
  ?session:Remote_exec.session ->
  timeout_seconds:int ->
  fetch:
    (Config_file.server ->
    (orchestrator_reading, Status_report.unavailability) result) ->
  Config_file.server ->
  reading
(** Run every read against [server] and assemble the result.

    The orchestrator's own reading arrives as [fetch] rather than being
    performed here, and the reason is a dependency and not a preference:
    {!Orchestrator_status} reads an answer into {!orchestrator_reading}, which
    is this module's type, so it depends on this module. A read performed here
    would have to call it back, and the two would be a cycle. The parameter is
    what keeps the read above both of them, in the command that wants it.

    It is not what it was for. It arrived because the orchestrator was reached
    over a scheduler its caller owned and this module did not; there is no
    scheduler now, and every one of these reads goes over the same runner. What
    survives is the type-level reason above.

    No read is allowed to abort the others or the run: a failure becomes a value
    in the reading, which is the only way a report survives the conditions that
    make it worth printing.

    [timeout_seconds] is how long each remote read may take before it is given
    up on, per read rather than for the four together: they are independent
    calls and a budget shared between them would make one slow read report the
    others as failures. The fetch is not covered — it is the caller's own call
    and arrives here already bounded or not.

    [session] is the staged key the four remote reads are made over. It is
    optional so that a caller which has not opened one still gets its reading,
    each read opening and closing a session of its own — which is what all four
    did before there were sessions, and is the same answer at four times the key
    material's time on disk. A caller that reaches the orchestrator over the
    same runner hands [fetch] the session it opened here, which is how the fifth
    reading joins the four rather than paying its own handshake. *)

val health_waits :
  ?session:Remote_exec.session ->
  timeout_seconds:int ->
  Config_file.server ->
  Host_inventory.t ->
  (string * Container_health.verdict) list
(** Wait on the host for every container in the reading that has a declared
    healthcheck to answer for, and bring back what each one said.

    Which containers those are is the inventory's own answer, so nothing is
    waited on that the host has already said has no check to pass, and nothing
    is waited on that the host does not have. The wait runs on the server and
    each verdict is a value: a container that never passes costs the bound and
    is reported, and one whose wait could not be run at all is reported as that
    instead.

    This is a caller's choice and not part of taking a reading. Reporting a
    health state and waiting for one are different jobs, and the command that
    only reports one never calls this.

    [session] is the staged key each wait is run over, as in {!gather}: a caller
    that took its reading inside a session waits inside the same one.

    [timeout_seconds] is the wait the host is asked to perform, and this is the
    only read whose invocation bound is not the caller's to choose: it is that
    number plus enough slack for the connection, because a bound at the wait's
    own length would report a container that used its whole budget as a call
    that was given up on. *)

val report_of_reading :
  config:Config_file.t ->
  address:string ->
  waits:(string * Container_health.verdict) list ->
  reading ->
  Status_report.server_report
(** Turn one server's reading, and whatever it waited for, into the report for
    it.

    Both commands that print this report build it here, so neither can grow its
    own idea of what a server's report contains. *)
