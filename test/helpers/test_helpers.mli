(** Assertion and fixture helpers shared by every test executable.

    Each of these was written privately in a test file first and then written
    again in the next one; a substring check is small enough that copying it
    reads as cheaper than sharing it, and eight copies later the cost is that a
    weak assertion cannot be strengthened in one place. The same holds of a
    fixture that has to spell a shape some module under test writes: one
    definition with two readers is the whole point, and two definitions is the
    drift each copy was written to prevent. *)

val contains : needle:string -> string -> bool
(** [contains ~needle hay] is whether [needle] occurs anywhere in [hay].

    A raw substring test. Prefer {!contains_word} for any needle that is a
    prefix of another word the same code can render. *)

val contains_word : word:string -> string -> bool
(** [contains_word ~word hay] is whether [word] occurs in [hay] delimited by
    whitespace or by either end of the value.

    The check {!contains} cannot make. Rendered output is full of words that
    contain other words — ["healthy"] inside ["unhealthy"], ["read"] inside
    ["unreadable"] — so an undelimited assertion on the shorter one passes
    against output rendering the longer, which is exactly the inversion the
    assertion was written to catch. *)

val exec_line : string -> string
(** [exec_line job] is a crontab line firing [job] in the shape the
    orchestrator's own writer emits.

    Built from {!Bondi_common.Cron_exec_line}'s marker and run-file path rather
    than spelled out here, so a reader that stopped recognising what the writer
    emits cannot leave a test naming jobs the box itself could not name. Both
    the crontab suite and the readiness suite read the same shape, and reading
    it from one definition is what keeps them from drifting apart while both
    stay green. *)

val bind_mount :
  host:string -> container:string -> read_only:bool -> Bondi_common.Bind_mount.t
(** [bind_mount ~host ~container ~read_only] is the mount those fields describe,
    failing the test when {!Bondi_common.Bind_mount.create} refuses them, so a
    suite that needs a valid mount as a fixture does not restate the match. It
    lives here, not in the server helpers, because the client suites need it too
    and only this library is reachable from both. *)

val mount_fields : Bondi_common.Bind_mount.t -> string * string * bool
(** [mount_fields mount] is [(host, container, read_only)], the shape suites
    compare mounts by. *)

val with_temp_dir : string -> (string -> 'a) -> 'a
(** [with_temp_dir prefix f] runs [f] on a freshly made directory whose name
    starts with [prefix], and removes the directory and everything in it when
    [f] returns or raises, so a suite that needs somewhere to write leaves
    nothing behind in the temporary directory. *)
