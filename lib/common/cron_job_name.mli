(** The names a cron job cannot take, and the clashes in a set of jobs.

    A cron job runs in a container named after the job, so its name shares one
    namespace with every other container on the box. A job that takes a name
    already in use either fails to start or, worse, removes the container that
    holds the name when its run cleans up. The client refuses such a job when it
    reads [bondi.yaml], and the server refuses it again when a deploy arrives,
    and both read this module so the two checks cannot disagree.

    A name is held by one of five classes, each taken from where Bondi names
    that container:
    - a built-in container: {!Builtin_container.orchestrator},
      {!Builtin_container.traefik} and {!Builtin_container.alloy};
    - the declared service, under its own name ({!Router_name.to_string});
    - the service's blue-green candidate, [<service>-new], the name a new
      release starts under before it takes over;
    - a managed container, under its container name, which
      {!Managed_container.container_name_of} derives as [bondi-<name>];
    - another cron job. *)

(** What holds a name a cron job asked for. Each case carries the name as the
    container runs under it. *)
type holder =
  | Builtin of string  (** One of Bondi's own containers. *)
  | Service of string  (** The declared service. *)
  | Blue_green_candidate of string
      (** The service's candidate container, [<service>-new]. *)
  | Managed of string  (** A managed container, by its container name. *)
  | Cron_job of string  (** Another cron job of the same name. *)

type collision = { job : string; holder : holder }
(** A cron job named [job] whose name [holder] already holds. *)

val reserved :
  service:Router_name.t option -> managed:string list -> holder list
(** [reserved ~service ~managed] is every name a cron job cannot take apart from
    the other jobs' names: the three built-in containers, then the service and
    its candidate when there is a service, then each managed container name in
    [managed], in that order. With no service, no candidate name is reserved. *)

val collisions :
  service:Router_name.t option ->
  managed:string list ->
  string list ->
  collision list
(** [collisions ~service ~managed jobs] is every clash among [jobs], in job
    order. A job collides with each {!reserved} holder of its name, and, if an
    earlier job in [jobs] has the same name, once with {!Cron_job}: two jobs
    named [x] report one collision, on the second. The empty list means every
    job's name is free. *)

val collision_to_string : collision -> string
(** One sentence naming the job and what holds its name, by class and name. *)

val refusal : collision list -> string option
(** [refusal collisions] is the one sentence refusing a set of jobs for the
    names they cannot take, naming every collision with {!collision_to_string},
    or [None] when [collisions] is empty. The client and the server both phrase
    their refusal with this. *)

val is_safe_path_name : string -> bool
(** A job's name is also a directory under the cron root, so it must be safe to
    place in a path: it begins with a letter or a digit and holds only letters,
    digits, [.], [_] and [-]. This is {!Managed_container.is_valid_name}'s rule,
    which the server's [Cron_secrets] also applies before it writes. *)

val unsafe_path_refusal : string list -> string option
(** [unsafe_path_refusal names] is the one sentence refusing every name in
    [names] that fails {!is_safe_path_name}, quoted, or [None] when all pass. *)
