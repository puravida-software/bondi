(** The names of the containers Bondi runs on a host itself: the orchestrator,
    the reverse proxy, and the log-shipping sidecar.

    These are the containers Bondi names. The ones an operator declares are a
    different class and are named elsewhere:
    [Managed_container.container_name_of] derives those from a service name, so
    there is one place they can come from and nothing to keep in step. The three
    here are constants, which is exactly why they need a home. A constant
    spelled twice does not drift over time; it disagrees the moment either copy
    is renamed. Nothing fails to build and no test reddens, because both
    spellings are still valid strings. What fails is the host, on the next run
    that looks for a container under the name the other half of the code no
    longer uses.

    They live here rather than beside any one of their readers because both
    libraries read all three and neither owns them. The client creates,
    inspects, stops and removes them over SSH; the server creates one of them,
    inspects the others to report on them, and writes a crontab line that execs
    into the first. The module that holds that line's grammar is scoped to the
    line and the run file it names — the proxy and the sidecar appear in
    neither, so keeping them there would make that module's name a lie. *)

val orchestrator : string
(** The name the orchestrator container runs under. Every command that starts
    it, waits for it, execs into it, copies a job's files out of it, stops it
    and replaces it names this string, and so does the crontab line the
    orchestrator writes for itself. *)

val traefik : string
(** The name the reverse proxy runs under. The server creates it while
    converging a deploy, and both status paths inspect it by name to report on
    it. *)

val alloy : string
(** The name the log-shipping sidecar runs under. Setup runs, stops and removes
    it by this name, and [docker run] refuses a name that is already taken — so
    a command naming it differently from the one that created it does not fail
    on its own, it fails every later setup on a name conflict. *)
