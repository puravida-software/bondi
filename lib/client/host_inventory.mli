(** What is actually on a server, read from Docker over SSH.

    A report assembled only from what the orchestrator says about itself cannot
    describe a host whose orchestrator is not running, which is the state it is
    most needed in. This module is the other source: the host's own container
    listing, plus the health Docker itself records, in a shape the report can
    render without asking anything else.

    It performs no I/O. The caller runs {!listing_command} and
    {!inspection_command} on the server and brings their output here, in the
    same shape as {!Curl_version} and {!Orchestrator_probe}. *)

(** What Docker records about a container's health.

    A container that defines no healthcheck and one whose health could not be
    read are separate outcomes, and neither is a verdict about whether the
    container works: reporting silence as a pass is exactly the claim this type
    exists to make unavailable. [Starting] is Docker's own word for a check that
    has not answered yet, and it is not a pass either. *)
type health =
  | Healthy  (** the container's own healthcheck last passed *)
  | Unhealthy of string  (** what the host called it *)
  | Starting  (** a healthcheck that has not answered yet *)
  | No_healthcheck  (** the container defines none, so there is none to pass *)
  | Not_recorded
      (** the container defines one, and the host has recorded no verdict *)
  | Unreadable of string  (** the health was never read *)

type container = {
  name : string;
  image : string;  (** the image without its tag *)
  tag : string;  (** empty when the host reported no tag *)
  state : string;  (** the host's own word: running, exited, created, … *)
  health : health;
  restart_count : int option;
  created_at : string option;
}
(** One container the host reported, with what Docker records about it. *)

(** The outcome of reading a host's containers.

    A listing that could not be run and a listing that found nothing are
    different facts, and collapsing the first into the second turns a failure to
    look into a claim that the box is empty — which would make every declared
    component read as absent on a host that may be running all of them. *)
type t =
  | Observed of container list
      (** the listing ran; these are the containers it found *)
  | Unreadable_listing of string  (** the listing never ran *)

val listing_command : string
(** The [docker] sub-command that lists every container on the host.

    Run over the same remote path as the other Docker reads, which supplies the
    [docker] itself. [-a] rather than a plain listing, because a container that
    died is still on the host and is exactly what the report has to show. *)

val inspection_command : string
(** The [docker] sub-command that reads health, restart count and creation time
    for every container on the host.

    The listing cannot carry these, so they are a second read. Every container
    on the host is inspected on its own rather than all of them in one call:
    [docker inspect] is all-or-nothing over an argument list, and the ids come
    from a listing taken a moment earlier, so one container pruned in the gap
    between the two reads would otherwise fail the whole inspection and report
    every container's health as unread. One at a time, a container that has gone
    costs its own line and the rest are still read.

    It reads whether a healthcheck is declared as well as what the host recorded
    for it, because the recorded status is empty in both of two unrelated cases
    — a container with no check, and a container whose check the host has not
    run — and the declaration is the only thing that tells them apart.

    Both are guarded: a container with no healthcheck has no health record at
    all, and asking for a field of a record that is not there fails the entire
    read rather than that one container's, so an unguarded template would lose
    every container to the first one without a healthcheck. *)

val split_image : string -> string * string
(** An image reference split into the image and its tag, with the empty string
    for a reference that names no tag.

    The tag is what follows the last colon of the final path segment. Splitting
    on the first colon reads a registry's port as a tag, and a reference pinned
    by digest names no tag at all — [org/app@sha256:abc] is one image, not
    [org/app@sha256] at [abc].

    Exposed because the report compares what two sources said about the same
    container, and the other source splits references with a parser that answers
    differently. Comparing the halves each produced reports drift between two
    parsers as drift on the box; comparing what both are put back together into,
    split once here, compares the containers. *)

val health_to_wait_for : t -> string list
(** The containers a caller waiting on declared health has something to wait
    for, in the order the host listed them.

    A container the host says defines no healthcheck is not among them: there is
    nothing there to pass, and spending a bound on it is how a caller with
    nothing to wait for waits anyway. A container whose health could not be read
    is among them, because a read that failed is not the host saying there is no
    check — and a wait re-reads, so it answers the question rather than guessing
    at it.

    Neither is a container that is not running, whatever health it carries.
    Nothing about a stopped container is going to change while it is waited on,
    so the wait reads its state, reports it gone and returns — a remote session
    spent to repeat what this listing already said, ending in a verdict that
    fails the run. A cron job's container sits stopped between its runs by
    design, and a job image built on a stock base inherits that base's
    healthcheck, so including them fails [setup] on every host with a schedule.

    A listing that never ran names no container. It has not said the host is
    running nothing; it has said nothing. *)

val of_reads :
  listing:(string, string) result -> inspection:(string, string) result -> t
(** Assemble the inventory from the output of the two commands.

    Each argument is the remote call's own result, so a read that never happened
    is distinguishable from one that answered. A failed listing yields
    {!Unreadable_listing}, never an empty inventory. A failed inspection leaves
    the containers themselves observed, with their health unreadable — the host
    said which containers it has, and that much is still known. *)
