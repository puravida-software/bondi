(** The crontab line the orchestrator used to write, and the payload it carries.

    The shape is a [curl] into the run endpoint with the job's whole payload as
    a single-quoted [-d] argument. Nothing writes it any more — the payload
    moved into a file the line names — but every crontab in the estate still
    holds lines like this and they still fire, so it has to be read.

    This module exists only to read a shape nothing writes, and it goes when the
    reader for those lines goes.

    Both libraries need the grammar: the orchestrator reads its own spool file
    to merge a deploy into it, and the client reads a host's spool file to
    report what is scheduled there. It lives here so that neither can drift from
    the other — one reader undoing the writer's quoting and the other not is how
    the same line comes to name a job on one side and nothing on the other.

    Nothing here returns an error, and nothing here renders a line. A payload is
    a job's environment, and often a credential; a reader that could not read
    one says so with [None] and says nothing about what it read. *)

val payload_of : string -> string option
(** The JSON payload a legacy line carries, as the text the shell would have
    handed to [curl]: the [-d] argument's contents with the writer's [' -> '\'']
    escaping undone.

    Text rather than a parsed value on purpose. What is recovered here is the
    shell's argument, and a [-d] argument is not required to be JSON — see
    below. Handing the bytes back unparsed is what keeps this module's answer to
    "the line carries no payload" apart from a caller's answer to "the payload
    does not parse", which are different facts about a line and are reported
    differently; the caller that wants a value parses it and answers for that
    failure itself.

    [None] for a line carrying no [-d '] argument — which is what a line of the
    shape written now returns — and for one whose argument never closes. The
    text is not validated as JSON: a line carrying an argument that is not JSON
    yields that argument. *)

val job_name_of : string -> string option
(** The [job] field of the payload {!payload_of} recovers.

    [None] when the line carries no payload, when the payload does not parse, or
    when it holds no [job] field of type string. *)

val image_of : string -> string option
(** The [image] field of the payload {!payload_of} recovers.

    [None] on the same three grounds as {!job_name_of}. *)
