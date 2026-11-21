(** A container image reference, parsed once and read the same way everywhere.

    The client reads references from [bondi.yaml] and the server reads them from
    the deploy payload. Both decode through this one module, so a reference that
    one side accepts is split the same way by the other.

    The grammar is the Docker Engine's: [[registry/]path[:tag][@digest]].
    - The first [/]-separated component is the registry when it contains [.] or
      [:], is [localhost], or has an uppercase letter, which is the test the
      engine applies. A registry is a dot-separated host name, or a bracketed
      IPv6 address, with an optional [:port].
    - Each path component is lowercase letters and digits, joined by [.], [_],
      [__] or a run of [-].
    - A tag is a word character followed by up to 127 word characters, [.] or
      [-].
    - A digest is [sha256], [sha384] or [sha512], a [:], and exactly 64, 96 or
      128 lowercase hex digits. These are the only algorithms the engine
      accepts.
    - The name, registry included, is at most 255 characters.

    Nothing is normalised. [docker.io/library/redis] and [redis] are different
    references here, and each prints back as it was written. *)

type t
(** A reference that parsed. *)

(** Why a reference was refused. *)
type error =
  | Empty  (** The reference is the empty string. *)
  | Malformed of string
      (** The reference does not match the grammar. It carries the rejected
          text, as written. *)

val of_string : string -> (t, error) result
(** Parse a reference. Nothing is trimmed, so surrounding whitespace is refused.
*)

val to_string : t -> string
(** Print a reference. It is the inverse of {!of_string}: the text it parsed
    from comes back unchanged. *)

val of_name_and_tag : name:string -> tag:string -> (t, error) result
(** Compose a reference from a name with no tag or digest and a tag, as
    [name:tag]. A name that already carries a tag or a digest is refused rather
    than given a second one, and so is an empty or malformed tag. [Malformed]
    then carries the composed text. *)

val name : t -> string
(** The repository, registry included: everything before the tag and the digest.
*)

val registry : t -> string option
(** The registry, as [host] or [host:port], when the reference names one. [None]
    means the engine's default registry. *)

val tag : t -> string option
(** The tag, when the reference has one. *)

val digest : t -> string option
(** The digest, as [algorithm:hex], when the reference has one. *)

val pull_tag : t -> string
(** The value to send as the [tag] query of the Engine API's [ImageCreate]: the
    digest, else the tag, else [latest]. The engine documents that query as "Tag
    or digest. If empty when pulling an image, this causes all tags for the
    given image to be pulled", so an empty value is never sent. The digest comes
    first because the container is created from the reference as written, and
    the engine resolves a reference that carries a digest by its digest. A pull
    by tag could leave that image unpulled. *)

val image_and_tag : t -> string * string
(** The reference as the two columns a status listing shows: the image, and its
    tag, or the empty string when it has none. A reference that carries a digest
    is the whole reference with an empty tag, because a digest names no tag and
    is what the container was created from.

    Both the host's listing, read by the client, and the orchestrator's status,
    written by the server, split through this, so the two report one container
    the same way. *)

val to_yojson : t -> Yojson.Safe.t
(** Encode as a JSON string holding {!to_string}. *)

val of_yojson : Yojson.Safe.t -> (t, string) result
(** Decode a JSON string through {!of_string}. A value that is not a string, or
    a string that does not parse, is refused, and the message carries the
    rejected JSON. *)

val grammar : string
(** One sentence stating what a reference is, for a refusal that must not quote
    the rejected text, which may hold a pasted credential. *)
