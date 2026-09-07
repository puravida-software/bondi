(** [GET /api/v1/health] -- whether the orchestrator is answering at all.

    The endpoint reads nothing and answers 204 with an empty body. What it
    reports is that this process is up and its router reachable, and nothing
    beyond that: it does not establish that Docker can be reached, that Traefik
    is running, or that a deploy would succeed. A readiness check that
    establishes those is separate work, and until it exists this must not be
    read as one. *)

val health : unit -> (unit, Handler_error.t) result
(** What the endpoint decides, naming no transport, so a caller holding no HTTP
    request can reach it. Always [Ok ()]: the handler is empty, and the result
    type is the shape every endpoint's body has rather than a claim that this
    one can fail today. A check with something to report returns its failure
    through here. *)

val route : Dream.route
(** The [GET /api/v1/health] route. It dispatches to {!health} and encodes the
    answer: 204 with no body for a success, and the failure's own status and
    message otherwise. *)
