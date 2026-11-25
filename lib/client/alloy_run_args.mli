(** The arguments that let Alloy read the host journal and keep its read
    position across a replacement, and that put its HTTP server on the box's
    loopback.

    A cron container can live for less than a second, too briefly for Docker
    discovery to list it, so its lines are read from the host journal instead.
    Setup replaces Alloy on every run, so where Alloy last stopped reading has
    to outlive the container. It is kept in a host directory that every Alloy
    container mounts, and [--storage.path] points at that directory.

    It is a module of its own because two consumers must agree on it: the run
    line setup builds, and the behavioural test that runs the real image with
    the arguments that line carries. A second spelling of a path, a network or a
    listen address would let the test prove a run line that does not ship. *)

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
(** One set of an Alloy container's arguments, split by the program that reads
    them. *)

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

val http_listen_port : int
(** [http_listen_port] is the port setup binds Alloy's HTTP server to, on the
    box's loopback. It is Alloy's own default port. An operator reads Alloy's
    counters there over SSH, without entering the container. *)

val http : listen_port:int -> t
(** [http ~listen_port] is the arguments for an Alloy whose HTTP server listens
    on the host's [127.0.0.1:listen_port] and nowhere else. Setup passes
    [http_listen_port]. The behavioural test passes a port of its own run, since
    several of its Alloys share one host, and nothing else differs.

    The container shares the host's network, so the listen address is the host's
    own loopback. No port is published: publishing would need a wildcard listen
    address inside the container, which every container on Docker's default
    bridge could reach, and on Docker Engine before 28.0.0 a port published to
    localhost is reachable from the box's L2 segment too
    [assumed from documentation: Docker's port-publishing page]. Host networking
    grants Alloy nothing it lacked, since it already holds the Docker socket.
    Under host networking this address is Alloy's only listener.
    [observed -- 2026-11-24, Docker Engine 29.10.0, grafana/alloy:v1.8.0 with
     the generated config: the one host socket present while it ran and absent
     once it stopped was tcp 127.0.0.1 on the given port.] If another process
    holds the port, Alloy exits at start while [docker run -d] still succeeds
    [assumed from Alloy v1.8.0's source: a failed listen exits the process]. *)
