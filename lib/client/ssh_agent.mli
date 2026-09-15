(** An [ssh-agent] Bondi raises, loads one identity into, and tears down again.

    A key that needs a passphrase cannot be handed to [ssh] as a file: [ssh]
    would offer its public half, the host would accept it, and the signature
    would never come, which the host reports as an authorization failure on a
    fault that is entirely local. An agent is how OpenSSH itself solves this —
    the decrypted key lives inside the agent process and nowhere else, and no
    decrypted key is ever written to disk.

    The module exists rather than a section of the module that runs remote
    commands because it is the only part of authenticating that has a lifetime,
    and a lifetime is the thing a caller forgets to end. Its failures are its
    own type so that the module which runs remote commands may map them into its
    own vocabulary without depending on it in return.

    {b The socket path has a length limit that is the operating system's.} A
    Unix domain socket address caps near 107 bytes on Linux, so a long [TMPDIR]
    produces an agent that cannot be reached — in exactly the way it already
    produces a [ControlPath] that cannot be reached. Nothing here shortens it;
    this is stated so the failure is recognised rather than discovered. *)

type t
(** A raised agent, valid only inside the call that raised it. *)

val auth_sock : t -> string
(** [auth_sock agent] is the path of the socket the agent is listening on, which
    is what [SSH_AUTH_SOCK] must be set to for a client to use it.

    The path is inside a directory this module created at mode 700 and removes
    on the way out. Whoever can open the socket can sign with every key the
    agent holds, which on a deploy box is root — the same reasoning the control
    socket already carries, and the reason the path is neither predictable nor
    shared. *)

val client_environment : auth_sock:string -> string array -> string array
(** [client_environment ~auth_sock environment] is [environment] with the
    variable every OpenSSH client reads naming [auth_sock], which is what makes
    a client spawned in it sign through this agent rather than through whatever
    the operator's own shell was pointing at.

    An inherited assignment of that variable is removed rather than shadowed. A
    second assignment of the same name is not an override: the C library answers
    with the first it finds, so appending would leave a client reaching for an
    agent that does not hold this key.

    Here rather than at the caller because both facts it rests on are this
    module's -- which variable names an agent, and what has to happen to one
    that is already set. [auth_sock] is taken as a path rather than as a
    {!type-t} so that the environment can be built once and carried by a caller
    for as long as the agent is up. *)

val public_half : t -> string
(** [public_half agent] is the public half of the identity this agent holds, in
    the one line an OpenSSH client reads a public key out of.

    It comes from the agent rather than from the key file because the key file
    is encrypted and the agent is what holds the decrypted form. A container
    that is not OpenSSH's -- a traditional PEM, a PKCS#8 -- keeps its public
    half inside the encryption, so a client handed that file alone cannot derive
    one and, under [BatchMode], cannot ask for the passphrase that would let it.
    The caller that staged the key is the one that decides where this goes; this
    module writes nothing.

    No passphrase reaches the program that answers this. It is asked in its own
    invocation, in an environment carrying the socket and nothing else, so the
    two process environments {!with_agent} names remain the only two. *)

(** Why no agent is holding this key. Every arm is this machine's own account of
    its own work; none of them is anything a host said. *)
type failure =
  | Not_available of { program : string }
      (** [program] is not on [PATH]. Settled before anything is spawned,
          because a local shell that cannot find a command exits 127, and 127 is
          what a host reports a missing Docker with. *)
  | Spawn_failed of { reason : string }
      (** The agent could not be raised, or was raised and could not be asked
          what it holds: no private directory to put its socket in, no
          descriptors left to spawn with, an [ssh-agent] that started and said
          nothing this module could read, or a listing of the loaded identity
          that did not come back. [reason] is this machine's own account of it
          and never a host's. *)
  | Passphrase_rejected of { output : string }
      (** The identity was not loaded. In practice the passphrase was wrong, and
          that is the only cause worth naming to an operator, but the cause
          carried here is whatever the loading program said. [output] is that
          program's own text, unbounded: the caller that renders it is the one
          that bounds it. It never contains the passphrase — the passphrase
          reaches the loading program down a separate channel and no arm of this
          module puts it in a message. *)

val with_agent :
  timeout_seconds:int ->
  passphrase:Private_key.passphrase ->
  key_path:string ->
  (t -> 'a) ->
  ('a, failure) result
(** [with_agent ~timeout_seconds ~passphrase ~key_path f] raises an agent, loads
    the key at [key_path] into it using [passphrase], and calls [f] with it.

    The agent is torn down before this returns, on every path out — including
    the one [f] leaves by raising, whose exception is re-raised after the
    teardown and not converted into a value. An identity is loaded with a
    lifetime, so a process killed outright leaves no agent holding a usable key
    behind it.

    [timeout_seconds] is the bound the caller holds a command over this agent
    to, and the identity's lifetime is derived from it. Taken rather than fixed
    because the property wanted is that the identity outlive the command, and a
    constant only asserts that — one caller raising its own bound past the
    constant makes the assertion false without touching this module. What the
    derivation does {e not} cover is a caller that issues several commands over
    one agent and spends near the whole bound on each: the lifetime bounds a
    command, not a session.

    [key_path] is a key already staged by the caller. This function writes no
    key of its own: a second write-then-delete is a second place a copy can be
    left behind, and the caller that staged it is the one that knows how long it
    should live.

    [passphrase] reaches the loading program through that program's own prompt
    channel — an askpass helper — and so never appears on a command line, in a
    file, in a crontab line, or in any text this module returns. The helper this
    module writes contains no secret of its own: it prints an environment
    variable.

    That variable is set in the loading program's environment and inherited by
    the helper the loading program spawns, so the passphrase is in {b two}
    process environments while the call is in flight, and anything running as
    this uid can read both out of [/proc]. That is the whole of the exposure and
    it is stated rather than narrowed — the same attacker can sign through the
    agent socket directly, and no part of this module claims a defence against
    them.

    The helper answers exactly once. Once is not an optimisation. A helper that
    keeps answering makes the loading program retry a wrong passphrase for as
    long as it is willing to, and the call never returns; a helper that answers
    once turns the same input into a refusal this function can report. *)
