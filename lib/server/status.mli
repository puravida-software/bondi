(** [GET /api/v1/status] -- what Bondi believes is running on this box.

    The endpoint is a read-only aggregate over independent sources: the named
    service's container, the orchestrator's, Traefik's, Alloy's, every managed
    container discovered by label, and the crontab. A source that cannot be read
    becomes an entry in [errors] beside whatever else could be read, rather than
    failing the response: the client renders anything it does not hear about as
    not found, which reads as "setup has not run" when the real cause is an
    unreachable Docker.

    Everything below {!route} is exposed for one of two reasons -- it is part of
    the wire contract, or it is a pure seam the tests reach because the code
    around it needs a Docker client and an Eio net that a unit test has no
    business constructing. Nothing here is intended for another module to call
    in production. *)

type component_status = {
  name : string;
  image_name : string;
  tag : string;
  status : string;
  restart_count : int option;
  created_at : string option;
}
(** One Bondi-managed component as the response reports it. [restart_count] and
    [created_at] are absent for a component that has no container to read them
    from, which is a cron job that is scheduled but has not yet run. *)

type infrastructure_status = {
  orchestrator : component_status option;
  traefik : component_status option;
  alloy : component_status option;
  managed : component_status list;
}
(** The components Bondi runs for its own sake rather than on the operator's
    behalf. Each is absent when no container by that name was found. *)

type comprehensive_status = {
  service : component_status option;
  cron_jobs : component_status list;
  infrastructure : infrastructure_status;
  errors : string list;
}
(** The body of a status response. [errors] carries one entry per source that
    could not be read, so a partial answer is distinguishable from an empty one.
*)

type status_context = {
  service_inspection :
    (Docker.Client.container * Docker.Client.inspect_response) option;
  orchestrator_inspection :
    (Docker.Client.container * Docker.Client.inspect_response) option;
  traefik_inspection :
    (Docker.Client.container * Docker.Client.inspect_response) option;
  scheduled_cron_jobs : Crontab.scheduled_job list;
  cron_container_inspections : (string * Docker.Client.inspect_response) list;
  cron_error : string option;
  alloy_inspection :
    (Docker.Client.container * Docker.Client.inspect_response) option;
  managed_inspections :
    (Docker.Client.container * Docker.Client.inspect_response) list;
  managed_error : string option;
}
(** Everything read from Docker and the crontab, as values. It is the whole
    input to {!plan}, which is what lets the response be decided without a
    Docker client. A source that failed appears here as its error rather than as
    an absence. *)

val pp_component_status : Format.formatter -> component_status -> unit
(** Print a component for a test failure message. *)

val equal_component_status : component_status -> component_status -> bool
(** Structural equality on a component, for tests that compare a planned
    component against an expected one. *)

val comprehensive_status_to_yojson : comprehensive_status -> Yojson.Safe.t
(** Encode a status response for the wire. Absent optional fields are omitted
    rather than sent as [null], so a box with no managed containers produces the
    same bytes it did before that field existed. *)

val managed_containers_of :
  Docker.Client.container list -> Docker.Client.container list
(** Select the managed containers from a Docker listing. Discovery is by label
    because the server never reads [bondi.yaml] and so cannot know the declared
    names. *)

val cron_state_of_listing :
  Crontab.listed_job list -> Crontab.scheduled_job list * string option
(** Pure: the two cron fields of a {!status_context}, from one crontab listing
    -- the entries that resolved to a job, and the warning for those that did
    not.

    An entry the reader could not resolve is reported rather than dropped. A box
    holding jobs it cannot parse would otherwise answer exactly as a box holding
    no jobs at all, which is the one failure an operator cannot see. It is not
    counted as a job either: nothing is known about it beyond its position.

    The warning names how many entries could not be read and where they are. It
    never names an entry: a legacy line carries the job's payload, credentials
    included, and this text is returned over HTTP, mailed by cron and shipped
    off the box with the diagnostics stream. [None] when every entry resolved,
    including when there were none. *)

val plan : service_name:string option -> status_context -> comprehensive_status
(** Build the response from gathered state, purely. [service_name] is absent
    when the caller asked about the box rather than about one service, and the
    [service] field is then omitted rather than reported as missing. *)

val report :
  client:Docker.Client.t ->
  net:_ Eio.Net.t ->
  clock:_ Eio.Time.clock ->
  service_name:string option ->
  (comprehensive_status, Handler_error.t) result
(** What the endpoint decides, naming no transport, so a caller holding no HTTP
    request can reach it. Gathers, plans, and writes one diagnostic line per
    entry in [errors].

    A source that failed is not an [Error] here -- it is an entry in [errors]
    alongside everything that could be read. The [Error] arm is an exception
    that escaped the gather, which is Bondi's own fault rather than the caller's
    and is reported as such. [Eio.Cancel.Cancelled] is the exception to that: it
    propagates rather than being classified, because a cancelled fiber that
    returned a value would break structured concurrency.

    Precondition: it reads Docker through Eio -- [Cohttp_eio] under an
    [Eio.Switch] -- so it must be called from inside an Eio fiber, which in this
    process means under [Lwt_eio.with_event_loop]. {!route} supplies one with
    [Lwt_eio.run_eio]; a caller holding no HTTP request supplies its own, with
    [Eio_main.run] or the same wrapper. *)

val route :
  client:Docker.Client.t ->
  net:_ Eio.Net.t ->
  clock:_ Eio.Time.clock ->
  Dream.route
(** The [GET /api/v1/status] route. It decodes the optional [service] query
    parameter, dispatches to {!report}, and encodes the answer as JSON or as the
    failure's own status and message. *)
