(** Running a command on a configured server over SSH.

    This is the one remote path the client has. It had no interface at all and
    was public by everything it happened to define; what is exposed here is what
    callers outside this module actually use, so the temporary key handling and
    the process plumbing stay private. *)

val ssh_options : string list
(** The options every remote call is made with.

    Two of them refuse to wait on a prompt: nothing that reads a host is
    attended by anyone who could answer a password or a host-key question, and a
    prompt is a wait with no deadline.

    The rest bound the network. A host that refuses a connection answers at
    once; one that accepts it and then drops the packets answers never, and
    [ssh] has no deadline of its own. Both commands that read a host print a
    report at the end of their work, so an unbounded read loses the report on
    exactly the failure it exists to describe — and the keepalive is the half a
    connect timeout cannot reach, a session established and then gone quiet.

    Exposed so the bounds can be asserted on. They are a property of the client,
    not of any one call site, and a call site spelling them differently is the
    defect. *)

val multiplex_options : unit -> string list
(** SSH options that reuse one connection across many commands.

    [bondi setup] issues 31 separate ssh invocations; measured on 2026-09-02 a
    cold connection costs 2.48s and a multiplexed one 0.39s, so this is the
    difference between roughly 77 seconds of handshake per setup and roughly 15.

    The control socket is created in a private mode-700 directory named after
    the calling process. Anyone able to open that socket can multiplex onto the
    connection it holds, which is root on a deploy box; on the runner fleet all
    agents share one uid, so a predictable path in a shared /tmp would let one
    repo's job ride another's deployment connection.

    Not folded into {!ssh_options} because a tunnel does not want it. *)

val decode_private_key : string -> string
(** The key material as it must be written to disk.

    A key is carried in the configuration either base64-encoded or verbatim, and
    a value that does not decode is one of the latter rather than a failure. *)

val with_temp_key : string -> (string -> 'a) -> 'a
(** [with_temp_key contents f] writes the decoded key to a mode-600 temporary
    file, calls [f] with its path, and removes it on every path out including an
    exception from [f].

    Exposed for [Ssh_tunnel], which needs the same key on disk for a forward
    rather than for a remote command. Key material must not outlive the call
    that needs it, and duplicating the write-then-delete is how one copy gets
    left behind. *)

val command_output :
  command:string -> Config_file.server -> (string, string) result
(** Run [command] on the server through a shell and collect what it printed.

    Standard error is merged into the output, so a command that failed is
    reported with whatever it said about why rather than with an exit code
    alone.

    A server with no [ssh] block in the configuration is a source that cannot be
    consulted, not an error to raise: the result says so and the caller decides
    what that means. *)

val docker_command_output :
  command:string -> Config_file.server -> (string, string) result
(** Run [docker command] on the server, as {!command_output} otherwise.

    The [docker] is supplied here rather than by each caller so no call site can
    spell it differently. *)
