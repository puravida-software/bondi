(** What version of Bondi's orchestrator a server is running, read from the
    server.

    The version that decides a gate is the one running on the box now, not the
    [bondi_server.version] pin in bondi.yaml: the two have diverged before, and
    the pin is what the operator meant rather than what is there. So the answer
    has to come from the host, which is the one thing about this that is not
    pure — {!Server_version} holds the floors and the ordering and performs no
    I/O, and this module is the read that feeds it.

    It exists because two commands ask it. [bondi deploy] holds every server to
    a floor before it posts anything, and [bondi status] holds every server to
    one before it runs the status subcommand; both decide from the same reading
    of the same image, and a command that spelled the listing differently would
    hold its boxes to the same floor from a different answer. That is not a
    drift caught by a failing build — both spellings are valid commands and both
    return a string — it is two commands disagreeing about which release a box
    is on. {!Bondi_common.Builtin_container} was given a home for the same
    reason and on the same evidence.

    What it is not is the two commands' shared vocabulary for failure. A read
    that failed is returned as the value {!Remote_exec.failure} rather than as a
    sentence, because the sentence is the caller's: a deploy that cannot read a
    box says a deploy is not being sent, a status says the source could not be
    consulted and puts it in a cell, and neither wording would be right in the
    other's output. This module answers what the box said; what that means for
    the run is decided where the run is. *)

val image_command : string
(** The [docker] argument list that asks a host for the orchestrator container's
    image.

    Exposed so that a caller which needs to name the read in a message, or a
    test which needs to pin what goes over the wire, is looking at the same
    string the read uses. The [docker] itself is not spelled here — the runner
    supplies it, so that no call site can spell it differently. *)

val read :
  ?session:Remote_exec.session ->
  Config_file.server ->
  (string, Remote_exec.failure) result
(** [read server] is the version the orchestrator on [server] reports, as
    {!Server_version.orchestrator_version_of_image} reads it out of the image
    tag the host answered with.

    The answer is total once it arrives: an empty listing from a box with no
    orchestrator, a [latest] tag, or a fork's image name all come back as
    strings rather than as errors, and it is the floors in {!Server_version}
    that refuse them and say so in words an operator can act on. An [Error] here
    is therefore only ever a box that could not be asked.

    [session] is the staged key the read is made over. It is optional so that a
    caller which has not opened one still gets its answer, the read opening and
    closing a session of its own; a caller that has one pays no second
    handshake. The bound the read is held to is this module's own — see the
    module documentation for why it is not a parameter. *)
