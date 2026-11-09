(** Removing the images a deploy left behind, as cleanup that cannot fail the
    deploy.

    Split the way every deploy step is: a pure {!plan} decides which images go
    from plain data, and {!interpret} carries the removals out. Docker refuses
    to delete an image a container still uses, and that refusal is the ordinary
    outcome of a cron pass holding the old image, so a failed removal is
    reported and the next one still runs. *)

type image = { id : string; repo_tags : string list }
(** An image on the host, as the listing reports it: its id and every [name:tag]
    reference it carries, possibly none. *)

type context = {
  replaced : string list;
      (** Image ids held by the containers this deploy replaced, read before the
          workload moved. *)
  declared : string list;
      (** Image references this deploy declares, each as [name:tag]: the service
          image and every cron job's image. *)
  candidates : image list;
      (** Local images of the repositories this deploy declares. *)
  referenced : string list;
      (** Image ids any container references, running or stopped. *)
}
(** What cleanup decides from: the images replaced, what is declared, what is on
    the host and what still references it. *)

(** One removal, or one image kept because a container uses it. Interpreting
    either can only warn, never fail. *)
type action = Remove_image of { id : string } | Keep_in_use of { id : string }

val declared_of_input : Strategy.Simple.deploy_input -> string list
(** Pure. The image references a deploy declares, each as [name:tag]: the
    service image when the request carries one, then every cron job's image in
    the order declared. An untagged service image is declared as [name:latest],
    the tag its container runs under. A reference that does not parse is
    declared as written. *)

val plan : context -> action list
(** Pure. The replaced ids followed by the candidate ids, minus every id in
    [referenced] and minus every candidate whose tags include a declared
    reference, each id once and in first-seen order.

    A declared image is kept even when nothing references it yet, which is a
    cron job's image before its first pass. Matching is exact string equality of
    a declared reference against a candidate's [repo_tags].

    A candidate left out only because [referenced] holds it is planned as
    [Keep_in_use] in its place, so the deploy says why it stayed. A replaced id
    that is no candidate and is referenced is left out without one: that is the
    image of a container this deploy did not replace, such as a Traefik left
    running. *)

val interpret :
  remove:(string -> (unit, string) result) ->
  warn:(string -> unit) ->
  action list ->
  unit
(** Runs every action in order. [remove] is given the image id; when it returns
    [Error reason], [warn] is called once with a line naming the id and
    [reason], and the next action still runs. The line carries nothing else. A
    [Keep_in_use] calls [warn] once with a line naming the id and that a
    container uses it, and never calls [remove].

    It does not catch exceptions [remove] raises: a caller whose [remove] can
    raise converts that into an [Error] inside [remove], or a raise on one
    removal skips the rest. *)

val snapshot_replaced :
  client:Docker.Client.t ->
  net:_ Eio.Net.t ->
  clock:_ Eio.Time.clock ->
  service_name:string ->
  string list
(** The image ids held at deploy start by the container named [service_name],
    when it exists, and by the Traefik container, when one exists. Read before
    the workload moves, because afterwards the replaced containers are gone and
    so is the record of which images they held.

    It cannot fail a deploy: the lookups are bounded by one deadline, and a
    failure, a timeout or a raised transport exception is written as one
    {!Diagnostics.write} line and answered with [[]], so cleanup goes ahead
    without the replaced images. [Eio.Cancel.Cancelled] propagates. *)

val run :
  client:Docker.Client.t ->
  net:_ Eio.Net.t ->
  clock:_ Eio.Time.clock ->
  replaced:string list ->
  declared:string list ->
  unit
(** Gather (bounded by one deadline), {!plan} and {!interpret}, with every
    failure and every image kept because a container uses it written as one
    {!Diagnostics.write} line and none returned: it cannot fail a deploy. A
    failed gather is one line and no removals; each failed removal is one line
    and the next removal still runs. An exception raised by the Docker client is
    treated as that call's failure, except [Eio.Cancel.Cancelled], which
    propagates. *)
