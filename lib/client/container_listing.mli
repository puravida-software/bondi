(** What [docker ps -a] says about one container Bondi starts by name: whether
    it is there, whether it is running, and what it was created from.

    The one reading of that listing, for every container setup looks up by name.
    Two copies of it, one per container, had already drifted: one read a line
    that did not parse as a container needing replacement, the other read the
    same line as present without looking at its columns. *)

type t =
  | Absent  (** The listing answered, and no container holds the name. *)
  | Not_running
      (** A container holds the name and is not running: created, restarting,
          paused, exited, removing or dead. An unknown state word in a line of
          three columns is read the same way. *)
  | Running of { image : string; spec_hash : string option }
      (** A running container. [image] is the listing's image column, which is
          the reference the container was created from only while that reference
          still names the container's image; after a pull moves the tag, it is
          the container's image id cut to twelve hex digits. [spec_hash] is the
          [bondi.spec-hash] label, [None] when the container carries no such
          label or an empty one. *)
  | Undetermined of string
      (** The listing never answered, with what the runner said instead, or
          answered with a line that does not decode, quoted in the message: it
          is neither a container to replace nor one to keep. Not a container
          that is absent: reading it as one plans a [docker run] against a name
          that may be taken. *)

val command : name:string -> string
(** The listing for the container named [name], without the leading [docker],
    for the runner that adds it. [name] is a Docker container name, which holds
    no character a shell treats specially.

    [-a] rather than a plain [ps], so that a container that is not running is
    seen at all. The columns are the state, the image and the spec-hash label,
    tab-separated, and the label's column is printed empty rather than left out
    when the container has no such label. *)

val of_probe : (string, string) result -> t
(** The reading of what {!command} answered: [Ok] with its standard output, or
    [Error] with the runner's failure.

    The first line that is not blank is the container. *)
