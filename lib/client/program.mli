(** Whether a program this client is about to spawn is there to spawn.

    The question is asked before the spawn rather than after it because after it
    the answer is unrecoverable: a local shell that cannot find a command exits
    127, and 127 is also what a remote shell exits when the command it was given
    is missing. A client that read its own missing binary as the host's answer
    would report a fault on the wrong machine, and in one case act on it.

    It is a module of its own, and not a helper inside the module that spawns
    [ssh], because the module that raises an agent asks the same question of two
    further binaries and may not depend on the one that spawns [ssh] — that
    dependency runs the other way. A second copy of the lookup would be a second
    place that decides whether a program is present, which is the kind of
    duplicate this client does not keep. *)

val found_on_path : string -> bool
(** [found_on_path program] is whether [program] can be executed.

    A name containing a [/] is a path and is asked about directly. A bare name
    is looked for in each entry of [PATH] in turn, where an empty entry means
    the current directory, as the shell reads it. Only a regular file this
    process may execute answers [true]: a directory of the right name, a
    dangling symlink, or a file without the execute bit is not a program.

    It answers a question about the moment it is asked, not a promise about the
    moment of the spawn. Nothing here reserves the binary or opens it. *)
