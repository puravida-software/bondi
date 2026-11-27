(** The deployment strategies a service can declare, and what each says about a
    service that has no [traefik:] block.

    Both the client, reading [bondi.yaml], and the server, reading the deploy
    payload, decide the same two things: which strategy a token names, and that
    blue-green needs a proxy to switch traffic through. They decide them here,
    so the token and the sentence an operator reads cannot drift between the two
    sides. *)

type t = Simple | Blue_green

val of_string : string -> t option
(** [of_string token] reads a strategy as the orchestrator reads it, exactly:
    ["simple"] or ["blue-green"]. Any other token, including ["auto"] and a
    different case, is [None]. *)

val to_string : t -> string
(** The wire name of a strategy. [of_string (to_string s) = Some s]. *)

val valid_values : string
(** The tokens {!of_string} accepts, as a phrase for a refusal. *)

val no_proxy_reason : string
(** Why a service with no domain and no declared strategy is {!Simple}:
    ["no traefik: block"]. The server reports it as the strategy's reason. *)

val blue_green_refusal :
  service:string option -> domain:string option -> t -> string option
(** [blue_green_refusal ~service ~domain strategy] is the sentence refusing
    [strategy] when it is {!Blue_green} and [domain] is [None]: blue-green
    switches traffic through the proxy, and with no domain there is none. [None]
    for every other pair. [service] names the service in the sentence; [None]
    says the request names no service. *)

val auto_without_proxy_notice :
  service:string ->
  domain:string option ->
  declared:string option ->
  string option
(** [auto_without_proxy_notice ~service ~domain ~declared] is the sentence
    saying that [service] is deployed with {!Simple} because it declares no
    strategy and no domain, which is what the orchestrator chooses for it.
    [None] when a strategy is declared (whatever its token) or a domain is. *)
