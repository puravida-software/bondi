(** What a private key declared in the configuration is, read without decrypting
    it.

    An OpenSSH key file stores its public half and its cipher name in cleartext,
    so whether a key needs a passphrase to sign with is a fact that can be read
    off the file. Reading it is what lets a configuration that cannot work be
    refused before anything is dialled, rather than arriving as the host's
    authorization error once the connection is already up.

    Nothing here decrypts, and nothing here holds key material longer than the
    call it was passed to. The module reads a cipher {e name} and answers a
    variant; it links no cipher and no key-derivation function and is not a step
    towards doing so.

    The module exists rather than a helper inside [Config_file] or the setup
    command because neither of those carries an [.mli]: a helper added to either
    becomes public by accident. And the decision is pure and has more than one
    outcome a caller must handle, which is a thing worth being able to ask for
    directly in a test, with no host and no key on disk. *)

val decode : string -> string
(** [decode contents] is [contents] base64-decoded, or [contents] unchanged when
    it is not base64.

    A key is carried in the configuration either base64-encoded or verbatim, and
    a value that does not decode is one of the latter rather than a failure.
    Both encodings are legal and neither is announced, so every reader of a
    configured key passes it through here first — there is one unwrap and no
    caller decides for itself what it was handed. *)

(** Whether the key in a configured value needs a passphrase before it can sign.
*)
type encryption =
  | Unencrypted
      (** The key can sign as it stands, with no secret beyond the file. *)
  | Encrypted of { cipher : string }
      (** The key needs a passphrase to sign with. [cipher] is what could be
          determined about how it is encrypted, not a guarantee of the
          algorithm: an OpenSSH key names its own cipher in cleartext and that
          name is carried through, while the two PEM containers are recognised
          by their armour alone and answer the container's name. It is a string
          for an operator to read in a refusal, never something to dispatch on.
      *)

(** Why a configured value could not be classified. Not a refusal on its own:
    what a caller does with each arm is {!type-identity}'s to decide. *)
type unreadable =
  | No_armour  (** No [-----BEGIN ...-----] line: not a PEM container. *)
  | Body_not_base64
      (** Armoured, but the body between the markers is not base64. *)
  | Body_not_openssh of string
      (** The body decoded, and did not begin with the OpenSSH v1 magic. The
          payload is the leading bytes that were found in its place, escaped, so
          a rejection can be read without the fixture in hand. *)

val encryption : string -> (encryption, unreadable) result
(** [encryption contents] is whether the key in [contents] needs a passphrase to
    sign with.

    [contents] is unwrapped with {!decode} first, so a base64-wrapped key
    classifies as the key it wraps.

    Three shapes of encrypted key are recognised. An OpenSSH v1 key is read
    properly: the armour is stripped, the body decoded, the 15-byte magic
    checked and the cipher name taken from the length-prefixed field that
    follows it, with the name ["none"] meaning unencrypted. The two other
    containers are recognised by their armour alone — a [Proc-Type: 4,ENCRYPTED]
    header for a traditional PEM key, and a [BEGIN ENCRYPTED PRIVATE KEY] marker
    for PKCS#8 — because in neither case is the cipher stated anywhere a reader
    that does not parse DER can reach it.

    An [Error] is not by itself a refusal, and the arms differ in how much they
    permit a caller to conclude. [No_armour] is a format this parser has not met
    — a future revision, a vendor variant, a container it does not read — and
    the authority on whether such a key is usable is OpenSSH, not this parser,
    so a caller stages it and lets [ssh] judge. The other two are not that: the
    value announced a container in its armour and then did not hold one, which
    is enough to say something useful about. See {!val-identity}. *)

type passphrase
(** The secret that unlocks an encrypted key, carried so that it cannot be
    printed.

    It is abstract, has no printer and no general [to_string], and leaves by
    exactly one door: {!expose_to_askpass}, whose name says the single place a
    passphrase legitimately becomes a string again. An interpolation that would
    put one into a command line, a log line or a rendered failure therefore does
    not compile, rather than passing review and failing in production. A bare
    [string] is what let the configured passphrase sit unread for the life of
    this project without anything noticing.

    Every manifest carries the field and most leave it empty, so the empty
    string is the ordinary case rather than an edge, and it is not a passphrase:
    see {!val-passphrase}. *)

val passphrase : string -> passphrase option
(** [passphrase value] is [value] as a passphrase, or [None] when [value] is
    empty.

    The empty string is what a manifest says when it has no passphrase to give,
    so refusing to build one from it is what makes an identity that must unlock
    a key, but holds nothing to unlock it with, a value that cannot be
    constructed at all. *)

val expose_to_askpass : passphrase -> string
(** [expose_to_askpass p] is the passphrase as a string.

    The one legitimate use is answering the prompt of the program that loads the
    key, over that program's own channel. The name is deliberately specific and
    deliberately greppable: every call is a place a secret becomes ordinary text
    and should have to justify itself. *)

(** Why a declared key cannot work as it stands, in enough detail for
    {!refusal_message} to say so without the key in hand. *)
type refusal =
  | Encrypted_without_passphrase of { cipher : string }
      (** The key needs a passphrase to sign with and the manifest carried none.
          [cipher] is what could be determined of how it is encrypted, for the
          message to name; it is a string for an operator to read, never
          something to dispatch on. *)
  | Unreadable_body of { detail : string }
      (** The value carries PEM armour around a body that could not be read —
          see {!type-unreadable}, whose two armoured arms this is built from.
          [detail] is that arm in a sentence, already bounded and escaped, so a
          refusal can be read without the key in hand and cannot carry a key's
          worth of bytes into a message. *)

(** How a server declaring a key — or declaring none — is authenticated to. One
    arm per outcome, so a caller cannot reach a host without having settled
    which of them it is in. *)
type identity =
  | Ambient
      (** No key was declared. Authenticate with whatever the operator's own ssh
          configuration provides — their agent, their config file, a jump host,
          a hardware-backed key. Nothing is staged and no identity is imposed.
      *)
  | Staged_key
      (** A key that can sign as it stands. It is written out and named to
          [ssh], which is what has always happened. *)
  | Own_agent of { passphrase : passphrase }
      (** An encrypted key and the secret that unlocks it. Signing needs an
          agent holding the decrypted key, which the caller raises for the life
          of the session and tears down after; the decrypted form exists only
          inside it and is never written anywhere. *)
  | Refused of { reason : refusal }
      (** A key that cannot work as declared. Nothing should be dialled: the key
          would be offered, accepted, and then fail to sign, and the operator
          would read the host's authorization error for a fault that is entirely
          local. [reason] is what the classifier could determine, for
          {!refusal_message} to name. *)

val identity : contents:string option -> passphrase:string option -> identity
(** [identity ~contents ~passphrase] is how a server declaring these two
    configured values is authenticated to.

    [contents] absent is a manifest that declines to carry key material, which
    is a legitimate shape and not an omission: a developer should not paste a
    private key into a configuration file to use a credential they already hold,
    and a hardware-backed key cannot be carried as a string at all. A passphrase
    with no key to unlock is nothing to act on and resolves the same way.

    A declared key is classified with {!val-encryption}. One that can sign is
    staged. One that cannot is refused, unless a passphrase came with it. A
    value with no armour at all is staged and left to [ssh] to judge, because
    [ssh] is the authority on a usable key and a format this parser has not met
    is a key it can prove nothing about rather than a key that will fail.

    A value that carries armour and then a body this module cannot read is
    refused rather than staged. That is not a format it has not met: the value
    named its own container and did not hold one, and the way it usually happens
    is a multi-line key substituted into a quoted YAML scalar, which folds it
    onto a single line. Staged, it would be offered to the host, accepted, and
    fail to sign — the exact failure this module exists to keep off the wire. *)

val refusal_message : server:string -> reason:refusal -> string
(** [refusal_message ~server ~reason] is the sentence an operator reads when a
    configuration cannot authenticate.

    It names the server, the field that holds the key and what could be
    determined of what is wrong with it, because the failure it replaces named
    none of them and arrived as the host's verdict on a fault that was local.
    Each arm also names the remedies: setting the passphrase or declaring no key
    at all for an encrypted one, since an operator who already has a working
    agent is otherwise told to supply a secret they may not have and do not
    need; and the two encodings that survive substitution for an unreadable
    body, since the value that reaches it is usually a key that was intact when
    it was exported. *)
