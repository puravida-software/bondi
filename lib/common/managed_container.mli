(** Pure specification of a Bondi-managed infrastructure container.

    A managed container is a long-running container declared in [bondi.yaml]
    that Bondi keeps converged: started at its pinned tag when declared, removed
    when withdrawn. This module holds only the declarative spec and the pure
    values derived from it — naming, filesystem paths, Docker labels, and the
    spec digest used to detect drift. It performs no I/O.

    The spec type is abstract and can only be built through {!create}, which
    validates it. A managed container's name is interpolated into a filesystem
    path that later receives a mode-600 secrets file and is deleted recursively
    when the container is withdrawn, so a name that escapes its directory must
    not be representable at all. *)

(** An environment value attached to a managed container. [Secret] values are
    written to a mode-600 file on the server and passed to the container by file
    reference; [Plain] values are passed inline and remain visible in
    [docker inspect]. *)
type env_value = Plain of string | Secret of string

type port = { host : int; container : int }
(** A published port mapping, host port to container port. *)

(** Docker restart policy for a managed container. *)
type restart_policy = No | On_failure | Always | Unless_stopped

type t
(** A validated managed container specification. Values of this type are
    guaranteed to carry a name that is safe to use as both a Docker container
    name and a single path segment. Build with {!create}. *)

(** Why a specification was rejected. *)
type error =
  | Empty_name
  | Invalid_name of string
  | Empty_image
  | Empty_tag
  | Invalid_restart_policy of string
  | Invalid_port of string
  | Duplicate_env_key of string
  | Invalid_env_key of string
  | Invalid_env_value of string
      (** Carries the offending {i key}, never the value: the value may be a
          credential and the message is surfaced to stderr. *)

val error_to_string : error -> string
(** A message naming the offending value, suitable for surfacing to whoever
    wrote the configuration. The one exception is {!Invalid_env_value}, which
    names only its key, so that a rejected credential is not echoed. *)

val restart_policy_of_string : string -> (restart_policy, error) result
(** Parse a declared restart policy. Accepts exactly Docker's own spellings:
    ["no"], ["on-failure"], ["always"], ["unless-stopped"]. There is no default
    — a managed container never falls back to an unrequested restart behaviour.
*)

val ports_of_strings : string list -> (port list, error) result
(** Parse declared port mappings written as ["<host>:<container>"], preserving
    order. Both sides must be integers between 1 and 65535; anything else is
    rejected, carrying the offending entry. *)

val create :
  name:string ->
  image:string ->
  tag:string ->
  restart:restart_policy ->
  network:string option ->
  ports:port list ->
  env:(string * env_value) list ->
  (t, error) result
(** Validate and build a specification.

    [name] must be non-empty, must begin with an alphanumeric character, and may
    otherwise contain only alphanumerics, underscore, dot and hyphen. This is
    the intersection of what Docker accepts as a container name and what is safe
    as a single path segment: it admits no separator and no leading dot, so a
    name can neither traverse out of its directory nor resolve to one.

    [image] and [tag] must be non-empty. A managed container is never started
    from an implied or defaulted image.

    [env] must not declare the same key twice. A duplicate is rejected rather
    than resolved by precedence: the losing value may be a credential, and which
    one wins would not be visible in the configuration. *)

val is_valid_name : string -> bool
(** Whether a string would be accepted by {!create} as a name.

    This exists so that a name recovered from a running container's label —
    which Bondi reads but did not necessarily write — can be rejected before it
    is interpolated into a path that is deleted recursively. *)

val container_name_of : string -> string
(** The Docker container name for a declared name, [bondi-] followed by it. Only
    meaningful for a name that satisfies {!is_valid_name}. *)

val config_dir_of : string -> string
(** The server-side config directory for a declared name. Only meaningful for a
    name that satisfies {!is_valid_name}: this path is removed recursively when
    a container is withdrawn. *)

val name : t -> string
(** The declared name, as validated by {!create}. *)

val image : t -> string
(** The image repository, without a tag. *)

val tag : t -> string
(** The pinned image tag. *)

val restart : t -> restart_policy
(** The declared restart policy. *)

val network : t -> string option
(** The container network to join, when one is declared. *)

val ports : t -> port list
(** The declared port mappings, in declared order. *)

val container_name : t -> string
(** The Docker container name, [bondi-] followed by the declared name. *)

val config_dir : t -> string
(** The server-side directory holding this container's Bondi-managed state,
    [/etc/bondi/] followed by the declared name. Removed when the container is
    withdrawn from configuration. *)

val env_file_path : t -> string
(** Path to the secret environment file inside {!config_dir}. The file is always
    written, so that withdrawing a credential truncates it; it is referenced by
    {!run_args} only when {!secret_env_file_contents} returns [Some]. *)

val secret_env_file_contents : t -> string option
(** Contents of the secret environment file: one [KEY=value] line per [Secret]
    entry, in declared order, each terminated by a newline. Returns [None] when
    the spec declares no secrets, in which case no file reference is passed to
    Docker. The file itself is still created, and truncated, so that a
    credential withdrawn from the configuration does not outlive its
    declaration.

    [Plain] values never appear here. *)

val plain_env : t -> (string * string) list
(** The non-secret environment entries, in declared order, suitable for passing
    inline to Docker. *)

val spec_hash : t -> string
(** A digest over every declared field, including secret values, so that
    rotating a credential is detected as drift. Stable under reordering of the
    [env] and [ports] lists, so cosmetic edits to [bondi.yaml] do not force a
    needless recreate.

    This is a change-detection digest, not a security primitive: it is compared
    against the value stamped on a running container to decide whether that
    container still matches its declaration. The digest is safe to publish as a
    label — it does not reveal the secret values that fed it. *)

val type_label : string * string
(** The label key and value that mark a container as a managed container, as
    opposed to Bondi's own infrastructure or a cron run.

    Exposed because it is the discriminator on both sides of the system: the
    client stamps it when starting a container and filters on it when gathering
    what is already running, and the server discovers managed containers by it
    when reporting status — it has no access to [bondi.yaml] and so cannot
    discover them by name. *)

val labels : t -> (string * string) list
(** Docker labels identifying the container as Bondi-managed and carrying its
    {!spec_hash} for drift detection.

    No Traefik routing labels are emitted: managed containers are reachable only
    from the container network, never from the internet. *)

val run_args : t -> string list
(** The arguments to [docker], starting with ["run"], that start this container
    at its declared spec: the pinned image last, the label set from {!labels},
    plain environment inline, and the secret environment passed by reference to
    {!env_file_path} when {!secret_env_file_contents} returns [Some].

    Returned as separate arguments rather than one string so that the caller
    quotes each one, and built here rather than in the interpreter so that
    deciding what a container's command line contains stays a pure, tested
    decision.

    No secret value ever appears in the result. *)
