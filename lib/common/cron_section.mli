(** The section of a crontab that Bondi owns, and where it begins and ends.

    A host's crontab holds lines Bondi wrote and lines an operator wrote. The
    two are told apart by a pair of marker comments, and everything outside them
    is preserved verbatim by every writer that touches the file.

    Both libraries need that boundary: the orchestrator writes the section and
    merges into it, and the client reads a host's spool file to report what is
    scheduled there. It lives here so that neither can drift from the other — a
    marker changed in one place and not the other leaves a plainly marked
    section read as absent, and the next write appends a second one. *)

(** What is wrong with a crontab's markers.

    Each is a defect an operator fixes differently, and none of them is an empty
    section. Carrying which one rather than the offending line is what makes it
    possible to report a defect in a file whose every line may be a credential.
*)
type malformation =
  | End_without_begin  (** a section closes that was never opened *)
  | Begin_without_end  (** a section opens and the file ends inside it *)
  | Nested_begin  (** a section opens inside one already open *)

type split = {
  before : string list;  (** the lines ahead of the first begin marker *)
  section : string list option;
      (** the lines between the markers, or [None] when the file carries no
          markers at all. An empty section and an absent one are different facts
          about a host: the first says Bondi wrote here and holds nothing, the
          second says Bondi has never written here. *)
  after : string list;
      (** the lines following the first end marker that lie outside every
          section *)
}
(** A crontab's lines, cut at the markers that delimit the section.

    Every section is the section. A file holding a second, separately balanced
    one is not malformed, and it is the state an earlier reader produced: it
    matched markers untrimmed, so a marker carrying a carriage return read as no
    section and the next write appended one below the first. Both sections'
    lines therefore arrive together in [section], in file order, and neither the
    second pair of markers nor its lines is left in [after] — a section read by
    nothing is a section every rewrite leaves standing, with its jobs firing
    beside the ones the rewrite wrote. *)

val begin_marker : string
(** The comment line that opens the section. *)

val end_marker : string
(** The comment line that closes the section. *)

val split_lines : string list -> (split, malformation) result
(** Cut a crontab's lines at its markers.

    Markers are recognised after trimming, so an editor that left a carriage
    return or a trailing space on one still leaves a section a reader can see;
    the alternative reports a plainly marked section as having none.

    The whole file is walked, so markers after the first section still have to
    balance and an unbalanced one is an error rather than a section read short.
    A second balanced section is not an error: its lines are part of {!split}'s
    [section], which is what lets a writer heal a doubled crontab. *)

val is_entry_line : string -> bool
(** Whether a line inside the section is an entry.

    A blank line is not one. Both libraries have to agree on that: the reader
    that numbers entries gives a blank line no position, and the writer that
    rewrites the section does not write it back, so one of them changing its
    mind alone is how the position a report names stops being the position the
    next rewrite addresses. *)

val join : split -> string list
(** Rebuild a crontab's lines from a split, writing one section.

    Inverse of {!split_lines} for any file holding at most one section whose
    marker lines are exactly {!begin_marker} and {!end_marker}. A file whose
    markers carried surrounding whitespace comes back with them normalised, and
    a file holding two balanced sections comes back holding one — those are the
    only two ways the bytes change, and the second is the point: it is how a
    crontab that acquired a duplicate section converges on the next write. *)
