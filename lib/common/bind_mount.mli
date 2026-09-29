(** A host directory mounted into a service's container.

    The type is abstract and can only be built through {!create} or
    {!list_of_yojson}, both of which validate it. The same list is decoded twice
    — once from [bondi.yaml] on the client and once from the deploy payload on
    the server — so both ends share this one definition of what a well-formed
    mount is.

    Only the form of a path is checked. Whether the host path exists is a
    property of a particular server, and what it names is the configuration
    author's business: whoever writes [bondi.yaml] already holds a shell on the
    box. Paths are not secrets, so every error names the one it rejected. *)

type t
(** A validated bind mount. Both paths are absolute and normalised, and the
    container path is not [/]. *)

(** Which side of a mount a rejected path was declared for. *)
type path_role = Host | Container

(** Why a mount, or a list of them, was rejected. *)
type error =
  | Not_absolute of { role : path_role; path : string }
      (** The path does not start with [/]. *)
  | Not_normalised of { role : path_role; path : string }
      (** The path has a [.] or [..] segment, an empty segment ([//]), or a
          trailing [/]. The host path [/] itself is normalised. *)
  | Control_character of { role : path_role; path : string }
      (** The path holds a control character (a newline, NUL, tab, DEL...). *)
  | Container_root
      (** The container path is [/]. Mounting over the container's root would
          hide the image's whole filesystem. *)
  | Duplicate_container_path of string
      (** Two entries of one list mount at this container path. Docker would
          refuse the container, so the list is refused when it is read. *)

val create :
  host:string -> container:string -> read_only:bool -> (t, error) result
(** Validate and build a mount. [host] is checked before [container], so a mount
    with both paths malformed is refused naming the host path. *)

val host : t -> string
(** The host path, as declared. *)

val container : t -> string
(** The path inside the container, as declared. *)

val read_only : t -> bool
(** Whether the container sees the mount read-only. *)

val error_to_string : error -> string
(** A one-line message naming the rejected path, for whoever wrote the
    configuration. *)

val list_of_yojson : Yojson.Safe.t -> (t list, string) result
(** Decode a list of mounts, preserving order. Each entry must be an object with
    exactly the keys [host] and [container] (strings) and [read_only] (a
    boolean); a missing key, an unknown key, a wrong type, or an entry that is
    not an object refuses the whole list, and the message carries the rejected
    entry. Each entry is validated as by {!create}, and a container path
    declared twice refuses the list naming it. *)

val list_to_yojson : t list -> Yojson.Safe.t
(** Encode a list of mounts in the shape {!list_of_yojson} reads back. *)
