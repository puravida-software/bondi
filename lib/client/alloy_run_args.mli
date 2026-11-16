(** The arguments that let Alloy read the host journal and keep its read
    position across a replacement.

    A cron container can live for less than a second, too briefly for Docker
    discovery to list it, so its lines are read from the host journal instead.
    Setup replaces Alloy on every run, so where Alloy last stopped reading has
    to outlive the container. It is kept in a host directory that every Alloy
    container mounts, and [--storage.path] points at that directory.

    It is a module of its own because two consumers must agree on it: the run
    line setup builds, and the behavioural test that runs the real image with
    the arguments that line carries. A second spelling of a path would let the
    test prove a run line that does not ship. *)

val journal_path : string
(** [journal_path] is where the host's persistent journal lives. It is mounted
    read-only at the same path inside Alloy. A box where journald stores nothing
    here gives Alloy a journal source that reads nothing. *)

val state_dir : string
(** [state_dir] is the host directory that holds Alloy's state, including its
    journal read position. It is also the path the directory is mounted at
    inside the container, and the path [--storage.path] names, so all three name
    the same place. *)

type t = {
  docker_options : string list;
      (** Options to [docker run]. They go before the image. *)
  alloy_options : string list;
      (** Options to Alloy's [run] command. They go after [run]. *)
}
(** One Alloy container's journal and state arguments, split by the program that
    reads them. *)

val journal : host_state_dir:string -> t
(** [journal ~host_state_dir] is the arguments for an Alloy whose state lives in
    [host_state_dir] on the host. Setup passes [state_dir]. The behavioural test
    passes a directory of its own run, and nothing else differs.

    Both mounts use [--mount], which refuses a source that does not exist rather
    than creating it as an empty directory. A missing journal therefore fails
    the run instead of starting an Alloy that reads nothing, and the state
    directory must exist before the run.
    [observed -- 2026-11-12, Docker Engine 29.9.3: a missing bind source exits
     125 with "bind source path does not exist".] [host_state_dir] must not
    contain a comma, which [--mount] reads as a field separator. *)
