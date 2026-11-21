(** Whether a service name can name the service's Traefik router.

    Each service's router and its load-balancer service are named after the
    service, so the name becomes a segment of a Traefik label key, as in
    [traefik.http.routers.<name>.rule]. Both the client, reading [bondi.yaml],
    and the server, reading the deploy payload, refuse a name that cannot be one
    before anything is stopped.

    The grammar is [[a-z0-9][a-z0-9_-]+]: a lowercase letter or digit, then one
    or more lowercase letters, digits, [_] or [-]. That is Docker's
    container-name grammar with [.] and uppercase removed, and the container is
    named after the service, so Docker's grammar bounds the set. Docker refuses
    a name shorter than two characters. Traefik splits a label key at [.], so a
    name holding one makes Traefik drop the container's whole configuration and
    the service is not served. Traefik's reference says "Labels are
    case-insensitive", so [Api] and [api] would be one router: uppercase is
    refused. A name Bondi's own Traefik container already defines is refused
    too; see {!reserved}. *)

type t
(** A name in the grammar above that is not {!reserved}. *)

val reserved : string list
(** Every router, middleware and service name that Bondi's own Traefik container
    defines. A test ties this list to the labels in the Traefik container's
    definition. *)

val acme_challenge_name : string
(** The name of the router, middleware and service that answer the ACME
    challenge. It is {!reserved}, and the Traefik container's labels take it
    from here. *)

val of_string : field:string -> string -> (t, string) result
(** [of_string ~field name] accepts a name in the grammar above that is not
    {!reserved}. The refusal names [field], quotes [name] and says why. *)

val to_string : t -> string

val to_yojson : t -> Yojson.Safe.t
(** The name as a JSON string. *)

val of_yojson : field:string -> Yojson.Safe.t -> (t, string) result
(** Reads a JSON string through {!of_string}. Any other JSON value is refused,
    naming [field] and echoing the value. *)

val grammar : string
(** One sentence stating what a router name is, for a refusal that must not
    quote the rejected value. *)
