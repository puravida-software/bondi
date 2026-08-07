(** The orchestrator's own account of a server, as it arrives over HTTP.

    The wire shape of [GET /api/v1/status] and the one step that turns a
    response body into the report's vocabulary. It performs no I/O: the caller
    obtains the body and brings it here, so what this client does with an answer
    can be checked against a captured one rather than against a running server.
*)

type component_status = {
  name : string;
  image_name : string;
  tag : string;
  status : string;
  restart_count : int option; [@default None]
  created_at : string option; [@default None]
}
[@@deriving yojson]
(** One component, as the orchestrator names and describes it. *)

type infrastructure_status = {
  orchestrator : component_status option; [@default None]
  traefik : component_status option; [@default None]
  alloy : component_status option; [@default None]
  managed : component_status list; [@default []]
}
[@@deriving yojson]
(** The components the orchestrator installs rather than deploys. *)

type comprehensive_status = {
  service : component_status option; [@default None]
  cron_jobs : component_status list;
  infrastructure : infrastructure_status;
  errors : string list;
}
[@@deriving yojson]
(** A whole response. *)

val components_of : comprehensive_status -> Status_report.component list
(** Every component the response holds, flattened out of its sections.

    The report keys both of its sources by the container name the host uses, so
    which section a component arrived in is a fact about the response's
    structure and not about the box. A section this forgets is a row that
    silently loses its orchestrator side. *)

val reading_of_body :
  ip_address:string ->
  string ->
  (Status_gather.orchestrator_reading, Status_report.unavailability) result
(** Read a response body into the report's vocabulary.

    A body that is not JSON and a body that is JSON of the wrong shape are the
    same outcome here — the orchestrator answered, and what it said could not be
    read — and that outcome is {!Status_report.Not_understood} rather than a
    source that could not be reached. The two send an operator to different
    places, and a version skew between this client and that orchestrator
    presents as the second while looking exactly like the first.

    The failure carries an excerpt of the body. Without it the one piece of
    evidence that identifies what answered is discarded at the moment it is
    needed, and the report says only that something went wrong. *)
