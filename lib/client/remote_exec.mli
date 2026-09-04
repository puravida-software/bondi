(** What the outcome of a command run on a configured server over SSH is, and
    how it reads.

    A remote call can fail in ways an operator resolves in different places: the
    box could not be reached, or the box ran the command and it exited non-zero.
    Formatting both into one sentence and returning that sentence loses the
    difference, and a caller cannot recover it by reading the sentence back.
    What this module holds is the outcome as a value, the pure decision that
    produces it, and the one rendering of it into the text operators already
    see. *)

type failure =
  | Not_configured of { server : string }
      (** The server has no [ssh] block, so nothing was attempted. This is a
          source that cannot be consulted rather than an answer that could not
          be understood, and the two send an operator to different places. *)
  | Ssh_failed of { code : int; output : string }
      (** ssh could not reach or authenticate to the host: no command ran.
          [output] is what ssh itself printed. *)
  | Command_failed of { code : int; output : string }
      (** The host ran the command and it exited [code]. [output] is what the
          command printed, standard error included. *)
  | Signalled of { signal : int; output : string }
      (** The shell this client spawns to run ssh was killed by [signal].
          Neither a remote death nor the ssh client's own death, both of which
          arrive as exit codes: see {!failure_of_status}. [signal] is OCaml's
          numbering rather than the operating system's, in which SIGTERM is -11.
      *)
  | Stopped of { signal : int; output : string }
      (** That same shell stopped rather than killed, numbered as above. *)

val ssh_config : Config_file.server -> (Config_file.server_ssh, failure) result
(** [ssh_config server] is the credentials a remote call needs, or the arm
    saying the configuration does not carry any.

    A server with no [ssh] block is a fact about the configuration, decided once
    and here, so that no runner has to hold an opinion about it and no caller
    has to discover it by catching something. *)

val failure_of_status :
  Unix.process_status -> output:string -> (string, failure) result
(** [failure_of_status status ~output] decides what a finished ssh invocation
    means, from how the process ended and what it printed. Exit 0 is the only
    success and returns [output] exactly as it was collected, untrimmed. Nothing
    here alters the bytes; what collecting them does to them is
    {!command_output}'s to say.

    ssh reserves exit code 255 for its own failures, so a 255 is read as ssh
    never having got as far as running the command. Observed on 2026-09-03
    against OpenSSH_10.5p1 with OpenSSL 3.6.4 on Linux x86_64, with a real sshd
    on 127.0.0.1:2222 as the reachable host: an unroutable address (192.0.2.1,
    RFC 5737 TEST-NET-1) returned 255 after the client's own ConnectTimeout, a
    closed port returned 255, an unauthorised key returned 255, and a reachable
    host running [exit 7] returned 7 rather than 255.

    Two things this decision cannot do, stated so that no caller infers coverage
    it does not have.

    A remote command that itself exits 255 is misclassified as ssh's own
    failure. Measured in the same session: [exit 255] on the reachable host
    arrives as 255, which is what a connection that never opened also arrives
    as. Standard error is merged into [output], so a remote command can print
    text shaped like ssh's own as well; there is no test on the code and no test
    on the output that separates the two. Mitigating and not to be relied on:
    the three remote commands that carry a verdict deliberately always exit 0,
    and nothing this client runs is known to exit 255 on purpose.

    Nothing that happens to ssh, at either end, arrives here as [Signalled]. A
    remote command killed by a signal comes back as an ordinary exit code, 128
    plus the signal number, from the remote shell -- a remote SIGTERM was
    observed as exit 143. The local ssh client killed by SIGTERM was observed on
    2026-09-04, through this module's own spawn against the same sshd, to come
    back as exit 255: ssh handles the signal and leaves by its own door, so a
    client killed locally is indistinguishable from a client that never
    connected.

    What [Signalled] reports is the shell this module spawns to run ssh, killed
    while it waits. An operator's Ctrl-C reaches it because that shell shares
    this process's group. Observed in the same session: signalling the shell
    with SIGTERM produced [Unix.WSIGNALED] while signalling ssh produced
    [Unix.WEXITED 255]. The number carried is OCaml's own -- SIGTERM reaches
    this arm as -11 -- and the rendered text says so, which is what the shapes
    this module replaces also printed. [Stopped] is that shell stopped rather
    than killed; nothing in how this runner reaps asks to be told about a stop,
    so the arm is believed unreachable and exists because the compiler requires
    it and the text it renders is pinned.

    Every code above is a property of that one OpenSSH. The client actually
    invoked is whatever [ssh] is on the operator's PATH, and nothing in the
    configuration pins it. *)

val ran_on_host : failure -> bool
(** Whether the host ran the command and this is its answer.

    True of [Command_failed] alone: the other four are the command never having
    been run, so nothing about them is the host's verdict on anything. Callers
    word their reports around that difference -- one sentence sends an operator
    to the host, the other to the network or to [bondi.yaml] -- and they were
    each spelling the same five-arm split out for themselves. The policy is one
    decision, so it is decided here; only the wording is each caller's own. *)

val message : failure -> string
(** The operator-facing text for a failure.

    Byte-identical to what each of the two implementations this module replaces
    printed, which is what lets their existing assertions stand as evidence that
    consolidating them changed nothing. Output is trimmed here rather than on
    the way in, so a caller that needs what the host actually said still has it.

    Exposed so that no call site spells the rendering itself: two call sites
    spelling it separately is how they came to render it differently. A caller
    that acts on the kind of failure takes the value; re-deriving the kind by
    parsing this string is the defect this module exists to close. *)

val command_output :
  ?input:string ->
  command:string ->
  Config_file.server ->
  (string, failure) result
(** [command_output ~command server] runs [command] on [server] through a shell
    and collects what it printed, as the outcome rather than as a sentence.

    Standard error is merged into the output when the command failed, so a
    failure is reported with whatever it said about why rather than with an exit
    code alone. A command that succeeded is answered with its standard output
    alone: the host answered the question it was asked, and the warnings ssh and
    sudo print alongside that answer -- a host key accepted for the first time,
    a hostname that does not resolve -- are not part of it. Callers read these
    outputs by shape, so a warning ahead of the reading would be read as the
    reading.

    The output is collected a line at a time, so a final line the command left
    unterminated arrives with a newline that the command did not print. Nothing
    else about the bytes is changed, and nothing is trimmed.

    The runner is not re-entrant. It changes this process's SIGPIPE disposition
    for the duration of the write and restores it afterwards, and that setting
    belongs to the whole process rather than to a call: two calls in flight at
    once would restore each other's. Every remote call this client makes is
    serial -- the servers are walked with [List.map] -- so there is never a
    second one in flight; a caller that runs these concurrently has to make the
    disposition its own problem rather than this module's.

    [input] is fed to the command's standard input. It is optional because a
    command that is not fed is a different call, not a call with an empty
    payload: nothing is written and the command reaches end of input at once.
    Feeding it here rather than embedding it in the command keeps a payload that
    carries credentials out of argv on both machines, and it is the reason there
    is one runner instead of a second one for callers that have something to
    send. Nothing drains the command's output while the write is in flight, so
    [input] must be small enough to fit the pipe buffer.

    A server with no [ssh] block is a source that cannot be consulted, not an
    error to raise: the result says so and the caller decides what that means.
*)

val docker_command_output :
  ?input:string ->
  command:string ->
  Config_file.server ->
  (string, failure) result
(** [docker_command_output ~command server] runs [docker command] on the server,
    as {!command_output} otherwise.

    The [docker] is supplied here rather than by each caller so no call site can
    spell it differently. *)

val command_output_text :
  ?input:string ->
  command:string ->
  Config_file.server ->
  (string, string) result
(** As {!command_output}, with the failure already rendered by {!message}. *)

val docker_command_output_text :
  ?input:string ->
  command:string ->
  Config_file.server ->
  (string, string) result
(** As {!docker_command_output}, with the failure already rendered by
    {!message}.

    This pair is for a caller that only reports the text. A caller that acts on
    the kind of failure takes the value instead; re-deriving the kind by parsing
    this string is the defect this module exists to close. They exist so that no
    call site spells the rendering itself, which is how the two implementations
    consolidated here came to render it differently. *)

val ssh_options : string list
(** The options every remote call is made with.

    Two of them refuse to wait on a prompt: nothing that reads a host is
    attended by anyone who could answer a password or a host-key question, and a
    prompt is a wait with no deadline.

    The rest bound the network. A host that refuses a connection answers at
    once; one that accepts it and then drops the packets answers never, and
    [ssh] has no deadline of its own. Both commands that read a host print a
    report at the end of their work, so an unbounded read loses the report on
    exactly the failure it exists to describe -- and the keepalive is the half a
    connect timeout cannot reach, a session established and then gone quiet.

    Exposed so the bounds can be asserted on, and so that the one caller that
    does not use this module's runner still makes its connection with the same
    bounds. They are a property of the client, not of any one call site, and a
    call site spelling them differently is the defect. *)

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

    Not folded into {!ssh_options} because a tunnel does not want it: a forward
    is one long-lived connection that gains nothing from a shared master, and
    routing it through one would make tearing it down a question of channels
    rather than of killing a process. Whether a call kind multiplexes therefore
    stays that call kind's own answer. *)

val with_temp_key : string -> (string -> 'a) -> 'a
(** [with_temp_key contents f] writes the decoded key to a mode-600 temporary
    file, calls [f] with its path, and removes it on every path out including an
    exception from [f], whose fault reaches the caller rather than the
    cleanup's.

    A key is carried in the configuration either base64-encoded or verbatim, and
    a value that does not decode is one of the latter rather than a failure. The
    decoding is not exposed on its own because no caller has anything to do with
    a decoded key except write it, and this is the write.

    Exposed for the tunnel, which needs the same key on disk for a forward
    rather than for a remote command. Key material must not outlive the call
    that needs it, and a second implementation of the write-then-delete is a
    second place a copy can be left behind -- which is why there is one here and
    none anywhere else. *)
