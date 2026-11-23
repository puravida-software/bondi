(** The reverse proxy's plan and its interpreter, whichever strategy rolls the
    workload forward.

    Traefik is one container per box, named
    {!Bondi_common.Builtin_container.traefik}, and it is found by that name and
    nothing else. A container whose image merely mentions Traefik is not the
    proxy: it is never adopted, stopped or replaced here.

    The plan is pure and takes the proxy's own input rather than a strategy's,
    so every strategy and the deploy around them can reach it without one
    depending on another's internals. *)

type input = {
  image : Bondi_common.Image_reference.t;
      (** The Traefik image the deploy asks for. *)
  domain_name : string;
  acme_email : string;
  acme_ca_server : Bondi_common.Acme_ca_server.t option;
      (** [None] sends no certificate-server flag, so Traefik's own default,
          Let's Encrypt production, applies. *)
  force_redeploy : bool;
      (** Replace a running proxy even when its version already matches. *)
}
(** What a deploy asks of the proxy. A deploy that declares no proxy has no
    [input] at all, so nothing here can be missing. *)

(** What the plan does about the proxy. A replacement carries the container it
    stops, and keeping one carries nothing, so there is no decision that stops a
    proxy without creating its successor. *)
type decision =
  | Keep
      (** A proxy is there at the requested version and no redeploy was forced.
          Its other settings are not compared: a changed certificate server or
          ACME email reaches Traefik through a forced redeploy or a new image.
      *)
  | Create  (** No container under the proxy's name. *)
  | Replace of Docker.Client.container
      (** The proxy's version differs from the requested one, or a redeploy was
          forced. *)

(** One step of the proxy's convergence. *)
type action =
  | CreateNetwork of { network_name : string }
      (** Create the network Bondi manages if it is absent. *)
  | PullImage of { image : Bondi_common.Image_reference.t }
      (** Pull the proxy's image, never with credentials. *)
  | StopAndRemove of { container_id : string }
      (** Stop the running proxy, then remove it. *)
  | EnsureTraefik of { traefik_config : Docker.Traefik.docker_config }
      (** Create and start the proxy under its reserved name, and wait until it
          runs. *)

val decide : input -> current:Docker.Client.container option -> decision
(** Decide, purely, from the container a lookup by the proxy's name returned. A
    [current] not carrying that name is not the proxy and decides {!Create}, as
    no container does. A version is compared by tag and digest, not by the name
    it is spelled with, and an image Docker reports that does not parse is never
    replaced unless the redeploy is forced. *)

val plan : input -> decision -> action list
(** The actions for a decision, purely. The network comes first; for {!Create}
    and {!Replace} the image is pulled before anything is stopped, so a proxy
    image that cannot be pulled leaves the running proxy serving. {!Keep} plans
    no pull and no stop. *)

val interpret :
  clock:_ Eio.Time.clock ->
  client:Docker.Client.t ->
  net:_ Eio.Net.t ->
  action list ->
  (unit, string) result
(** Run the actions in order, stopping at the first that fails. *)
