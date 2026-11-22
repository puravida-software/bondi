(** Whether a container Bondi starts by name is still running the image its
    reference now names, read after that reference has been pulled.

    The comparison is by image id, not by reference. A pull that moves a tag
    leaves the container on the image it was created from, and the reference it
    was created from still reads the same, so only the ids can tell an updated
    tag from an unchanged one. Both ids are the full [sha256:] form the docker
    CLI prints: the pulled image's [docker image inspect] [.Id], and the
    container's [docker container inspect] [.Image]. The two are equal until the
    tag moves. *)

(** What the two ids say about the container. *)
type verdict =
  | Same
      (** Both ids were read and they are equal: the container runs the image
          its reference names now, and is kept. *)
  | Moved
      (** Both ids were read and they differ: the reference names another image
          now, such as a new [latest], and the container is replaced. *)
  | Unreadable of Host_answer.t
      (** Not both ids were read, with what the host answered instead. Neither a
          match nor a difference: setup refuses on it and touches nothing,
          because keeping the container would claim an image the host never
          reported and replacing it would stop a container for want of a
          reading. *)

val command : image:Bondi_common.Image_reference.t -> container:string -> string
(** The one command that prints both ids, one per line: the image [image] names
    first, then the image the container named [container] was created from. It
    is a whole shell line with both [docker] invocations spelled out, for a
    runner that adds nothing, because it is two invocations joined by [&&]: a
    failure of the first prints no second id and fails the line.

    Both [image] and [container] are quoted for the shell: a parsed reference
    can still hold a character a shell expands, such as the brackets of an IPv6
    registry address, which are a glob. [container inspect] rather than a plain
    [inspect], so that the second id is never read off an image that happens to
    share the container's name. *)

val verdict : (string, string) result -> verdict
(** The reading of what {!command} answered: [Ok] with its standard output, or
    [Error] with the runner's failure.

    [Ok] is read by position: the first line is the pulled image's id, the
    second the container's. Anything else, including fewer lines, more lines, or
    a line that is not a [sha256:] id of 64 lowercase hex digits, is
    [Unreadable] with that output. Two equal lines that are not ids, such as the
    [<no value>] a template prints for a field that is not there, are not
    [Same]. [Error] is [Unreadable] with the runner's text, which quotes the
    host's output when the host ran the command. *)
