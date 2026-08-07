(** One report about a server, assembled from two sources that are never
    reconciled.

    Docker read over SSH is ground truth about the box; the orchestrator's own
    HTTP report holds what only it knows, such as whether a cron job's last run
    completed. Each keeps its own field on every row, because a single merged
    value would have to prefer one of them, and preferring one silently is how a
    table stops being auditable — a blend cannot be checked against anything.

    Where the two describe the same component differently, the difference is the
    finding, not a defect in the report: it is drift nothing else detects.

    This module performs no I/O. The caller brings both readings, in the same
    shape as {!Host_inventory} and {!Orchestrator_probe}. *)

type observation = {
  image : string;  (** the image without its tag *)
  tag : string;  (** empty when the source reported no tag *)
  state : string;  (** the source's own word: running, exited, completed, … *)
  health : Host_inventory.health option;
      (** absent when the source reports no health at all, which is not the same
          as a health it could not read *)
  wait : Container_health.verdict option;
      (** the outcome of waiting for this container's declared healthcheck,
          absent where nothing waited — which is every row of a command that
          only reports a state, and every container the host says has no check
          to pass. It sits inside the source's own account rather than beside it
          because only the source that read the host can have one, and a verdict
          on a row no source reported would be a failure with nowhere to be
          read. *)
  restart_count : int option;
  created_at : string option;
}
(** What one source said about one component. *)

(** Why a source has nothing to say.

    Two failures that an operator resolves in two different places. A source
    that was never reached is a question about the network; a source that
    answered with something this client cannot read is a question about what is
    running at the other end, and is usually a version skew between the two.
    Reporting the second as the first sends the reader looking in the wrong
    place, and the answer that would have shown them which is gone by then —
    hence the message carries what arrived. *)
type unavailability =
  | Not_consulted of string  (** nothing was obtained from it at all *)
  | Not_understood of string
      (** it answered, and its answer could not be read. The message carries
          that answer *)

(** What a source had to say about a component.

    A source that answered and found nothing is not a source that could not be
    consulted: the first is a fact about the box, the second a fact about the
    read, and an operator acts differently on each. Collapsing them turns a
    failed connection into a claim that a component is gone. *)
type source_view =
  | Reported of observation  (** the source has this component *)
  | Absent  (** the source answered, and it does not have it *)
  | Unavailable of unavailability  (** the source has nothing to say *)

(** Whether the configuration asks for this component.

    The inverse of a declared component that is missing is a component running
    that nothing declares, and it is the one convergence would remove on the
    next run without ever having named it. *)
type declaration =
  | Declared  (** the configuration asks for it *)
  | Undeclared
      (** it is on the box, or the orchestrator has it, and no configuration
          asks for it *)

(** What part of a deployment a row is about.

    Carried on the row rather than re-derived by a reader, so the one walk over
    the configuration that decides it happens once. *)
type kind =
  | Service  (** the deployed service itself *)
  | Cron_job  (** a scheduled job, whose container is gone between runs *)
  | Infrastructure
      (** the orchestrator, Traefik, Alloy and managed containers *)

type row = {
  name : string;  (** the container name both sources use *)
  kind : kind;
  declaration : declaration;
  docker : source_view;  (** ground truth, read from the host over SSH *)
  orchestrator : source_view;  (** the orchestrator's report of the same thing *)
}
(** One component, as each source has it. *)

type component = { name : string; observation : observation }
(** One component the orchestrator reported, named as the host names it. *)

val rows :
  config:Config_file.t ->
  docker:Host_inventory.t ->
  orchestrator:(component list, unavailability) result ->
  waits:(string * Container_health.verdict) list ->
  row list
(** Merge both readings into one row per component.

    [waits] is what a caller that waited on declared health got back, keyed by
    container name. It is required rather than defaulted so that a caller which
    waits for nothing says so: reporting a health state and waiting for one are
    different jobs, and only one command does the second.

    A row exists for everything the configuration declares and everything either
    source found, so no row's existence depends on a source having answered: an
    orchestrator that could not be reached is a row saying so rather than a
    table one line shorter, and that is the line the report exists to print.

    Neither reading is allowed to remove a row, and neither value is written
    over the other. A component only one source has keeps the other source's own
    account of why it does not have it. *)

val disagrees : row -> bool
(** Whether the two sources describe the same component differently.

    True only when both reported it and their accounts of what is running differ
    — the image, its tag, or the state. Those three are claims about identity
    that cannot both be right; a restart count read a second apart legitimately
    differs and is not a finding.

    One source reporting a component the other does not is not a disagreement
    either: a cron job's container is gone between runs, so the host has nothing
    to show while the orchestrator still holds the record of its last run. That
    is the reason for reading both, and flagging it would flag every scheduled
    job on every server. Both accounts are on the row regardless, so nothing is
    hidden by leaving it unflagged. *)

val exit_failure : row list -> bool
(** Whether a run that produced these rows may still claim to have succeeded.

    Only two verdicts allow it: the check passed, or the container declares none
    to pass. This is deliberately not the negation of "did it pass" — a
    container with no healthcheck has passed nothing, and reading that as a
    failure would fail every run on every container that defines no check, which
    is most of them.

    A health that could not be read fails the run alongside one that ran out of
    time. A run that could not establish the precondition has not established
    it, and an exit code has two values and cannot say which of the two
    happened; the row's own wording is where that distinction lives.

    Only declared components are consulted. A run converges what the
    configuration asks for, and this answers whether it managed to; a container
    nothing declares is on the box for reasons the run neither chose nor
    touched, and letting one decide would settle the question with something
    outside it. Its row still carries the verdict — reporting what is on the
    host and judging what the run achieved are different jobs. *)

type server_report = {
  address : string;  (** the server this report is about *)
  rows : row list;
  crontab : Crontab_listing.t;
      (** the Bondi section of the host's crontab, as the read left it *)
  warnings : string list;
      (** what the orchestrator reported alongside its components *)
}
(** Everything one server's report holds. *)

val render_table : server_report list -> string
(** Render the report as a table, one block per server.

    A component's line names the source it came from. Where both sources
    describe it the same way there is one line, because two identical lines
    would be noise rather than provenance; where they describe it differently
    there are two, one per source, and the row is flagged. Neither is dropped
    and neither is preferred: the reader is the one who decides which to
    believe, and that is only possible if both are on the page.

    A source that could not be consulted is a line saying so, never a missing
    one. A component only the orchestrator could confirm is flagged as
    unverified, so nothing the host never saw reads as ground truth. *)

val render_json : server_report list -> string
(** Render the same report as JSON, keyed by server address.

    Each source keeps its own object on every component, so a consumer of this
    is no more able to read a single reconciled value than a reader of the
    table. *)
