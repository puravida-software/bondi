(** Reading Traefik's ACME file on a host, and what each reading calls for.

    The file is asked about with one command whose standard output says what the
    host found, and the exit status says only whether the command could be run.
    A reading that could not be taken is its own state and is never read as the
    file being absent: acting on it blind would write against a file the host
    may already have had. *)

val present_marker : string
(** The marker the probe prints when the file is there, followed on the same
    line by the owner and mode. *)

val absent_marker : string
(** The marker the probe prints when the host positively said the file does not
    exist. A probe that could not answer prints neither. *)

val declared : string
(** The owner, group and mode Bondi declares for the file, in the shape the
    probe prints them ([root:root 600]), so one comparison reads both. *)

val probe_command : path:string -> string
(** The shell command that reads [path]. It runs under [sudo], like the writes,
    so a parent the login user cannot search does not read as an absent file,
    and it prints {!absent_marker} only on a positive answer. *)

type state =
  | As_declared
  | Differs of { observed : Host_answer.t }
      (** the owner and mode the host reported, as it printed them *)
  | Absent
  | Undetermined of string
      (** the probe failed, or its answer said neither present nor absent *)

val state_of_probe : expected:string -> (string, string) result -> state
(** [state_of_probe ~expected answer] reads the host's answer to
    {!probe_command}. A marker is matched as a whole line, so a banner on
    another line neither answers nor shifts the reading. The present marker with
    nothing after it, an answer with no marker and an empty answer are all
    {!Undetermined}. *)

val permissions_command : path:string -> string
(** The two writes that set the declared owner and mode on [path]. *)

val create_command : path:string -> string
(** Creates [path] and its directory, then sets the declared owner and mode. *)

type course =
  | Keep
  | Correct of { command : string; found : Host_answer.t }
  | Create of { command : string }
  | Refuse of string

val course : path:string -> state -> course
(** What a reading calls for: leave a file at the declared posture alone,
    correct one at another owner or mode, create an absent one, and refuse a
    reading that could not be taken rather than act on it blind. *)

val confirmed : path:string -> server:string -> state -> (unit, string) result
(** What a reading taken after a write means: [Ok ()] only for a file now at
    {!declared}. Anything else is an error naming what the host reports, because
    a command exiting zero is not the host having applied it. *)

val confirmation :
  path:string ->
  server:string ->
  found:Host_answer.t ->
  state ->
  (Setup_phases.correction, string) result
(** {!confirmed} for a correction: on success, the correction naming what the
    host [found] and what was applied. *)
