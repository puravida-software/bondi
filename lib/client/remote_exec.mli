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
  | Ssh_not_found of { program : string }
      (** No [ssh] on this machine's PATH, so nothing was spawned. The local
          shell reports a missing command by exiting 127, which is exactly what
          the host's own shell exits when the {i remote} command is missing --
          and one of those readings authorises installing Docker on a box nobody
          asked to change. The question is therefore settled before the spawn
          and answered here, where [ran_on_host] is false. *)
  | Local_failure of { reason : string }
      (** This client could not make the call at all: no temporary directory to
          write the key into, no descriptors left to spawn with. A failure this
          module can describe is a value rather than something a caller
          discovers by catching, and nothing ran on any host. *)
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

    Three things this decision cannot do, stated so that no caller infers
    coverage it does not have.

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

    An exit 127 is not on its own the host's report that the remote command is
    missing. The shell this client spawns exits 127 for a command {i it} cannot
    find, and the command it is given is [ssh] -- so an operator with no ssh
    client installed reaches this function with exactly the status a host
    reports a missing Docker with. That reading authorises installing Docker, so
    it is not left to the caller to notice: {!command_output} settles whether
    there is an [ssh] to spawn before spawning and answers [Ssh_not_found],
    which {!ran_on_host} is false of. This function, reached with a status
    alone, still cannot tell the two apart.

    Every code above is a property of that one OpenSSH. The client actually
    invoked is whatever [ssh] is on the operator's PATH, and nothing in the
    configuration pins it. *)

val exited_with : code:int -> failure -> bool
(** [exited_with ~code failure] is whether the host ran the command and it
    exited [code].

    True of [Command_failed] alone, for the reason {!ran_on_host} gives: a code
    carried by any other arm is this machine's or ssh's, not the host's. Two
    setup probes each spelled the guarded [Command_failed] arm and then
    re-listed the remaining constructors after it, which is a match the compiler
    cannot check -- the guarded arm and the catch-all share a constructor. Asked
    of the type instead. *)

val ran_on_host : failure -> bool
(** Whether the host ran the command and this is its answer.

    True of [Command_failed] alone: the other six are the command never having
    been run, so nothing about them is the host's verdict on anything. Callers
    word their reports around that difference -- one sentence sends an operator
    to the host, the other to the network, to this machine, or to [bondi.yaml].
    The policy is one decision, so it is decided here. The most common wording
    around it is {!explain}, which is where the three callers that had each
    spelled out the same sentence now get it; the two whose arms differ by more
    than a noun keep their own wording and take this predicate directly. *)

val explain : subject:string -> failure -> string
(** [explain ~subject failure] is {!message}, prefixed with
    ["<subject> ran on the host and failed: "] when {!ran_on_host}.

    The sentence is the policy's and the noun is the caller's. Four callers were
    each spelling this out around their own {!ran_on_host} test, identical but
    for the noun, so the wording lived in four places while the decision lived
    in one. A caller whose two arms differ by more than the noun -- one that
    routes to different constructors, or words the not-reached arm too -- keeps
    its own and takes {!ran_on_host} directly. *)

val message : failure -> string
(** The operator-facing text for a failure.

    The four format strings are byte-identical to what each of the two
    implementations this module replaces printed, which is what lets their
    existing assertions stand as evidence that consolidating them changed
    nothing. Output is trimmed here rather than on the way in, so a caller that
    needs what the host actually said still has it.

    The interpolated output is bounded at 2 KB. It is carried because it is the
    half of a failure worth reading, and bounded because this text is printed to
    a terminal and rendered into reports while its source is unbounded -- a
    failed [docker logs], or the orchestrator's own
    [docker logs --tail 50 ... 2>&1], is megabytes. Past the bound the text ends
    [" ... (truncated, N bytes in all)"], so a reader is told the payload was
    cut rather than left to wonder where it stopped. An output within the bound
    is untouched, which is every assertion in the suite and every failure an
    operator has seen.

    Exposed so that no call site spells the rendering itself: two call sites
    spelling it separately is how they came to render it differently. A caller
    that acts on the kind of failure takes the value; re-deriving the kind by
    parsing this string is the defect this module exists to close. *)

(** Whether a caller wants the command's error stream, or only its answer. *)
type standard_error =
  | Merged_on_failure
      (** Standard output alone on success, output and error together on a
          failure. What every probe wants: setup reads a successful reading by
          shape -- a marker word, a listing line, a file mode -- so a
          "Permanently added ... to the list of known hosts" ahead of it is read
          as the reading. *)
  | Merged_always
      (** Both streams, whatever the status. What the two pass-through printers
          want: [bondi docker logs] and [bondi docker ps] exist to show an
          operator what the container said, and a container says much of it on
          standard error. *)

val command_output :
  ?input:string ->
  ?standard_error:standard_error ->
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

    [standard_error] is where a caller says otherwise, and there are exactly two
    that do. [bondi docker logs] and [bondi docker ps] are pass-through
    printers: what they exist to show is what the command said, and a container
    says much of it on its error stream, so they pass [Merged_always]. Every
    other caller is a probe read by shape and takes the default.

    Both streams are drained together. A runner that drained one to end of file
    and then the other hangs on any command that fills the pipe it is not
    reading -- 64 KB on Linux, which [docker logs] passes without trying.

    A final line the command left unterminated arrives with a newline that the
    command did not print, which is what the line-at-a-time read this replaced
    also did. Nothing else about the bytes is changed, and nothing is trimmed.

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
    So are the two failures that belong to this machine rather than to a host --
    no [ssh] on PATH ([Ssh_not_found], settled before the spawn so that a local
    shell's exit 127 is never read as the host's) and nowhere to write the key
    or nothing left to spawn with ([Local_failure]). Nothing on this path raises
    for a case it can name. *)

val docker_command_output :
  ?input:string ->
  ?standard_error:standard_error ->
  command:string ->
  Config_file.server ->
  (string, failure) result
(** [docker_command_output ~command server] runs [docker command] on the server,
    as {!command_output} otherwise.

    The [docker] is supplied here rather than by each caller so no call site can
    spell it differently. *)

val command_output_text :
  ?input:string ->
  ?standard_error:standard_error ->
  command:string ->
  Config_file.server ->
  (string, string) result
(** As {!command_output}, with the failure already rendered by {!message}. *)

val docker_command_output_text :
  ?input:string ->
  ?standard_error:standard_error ->
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
