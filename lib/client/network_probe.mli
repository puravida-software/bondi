(** Ensuring the Docker network on a host, asked and answered in one command. *)

val present_marker : string
(** Printed when the network was already there. *)

val created_marker : string
(** Printed when this run created it. *)

val ensure_command : network:string -> string
(** Inspects [network] and creates it only when the inspect did not find it,
    printing the marker that says which. A create that fails exits non-zero with
    Docker's words, which is the runner's failure and not an answer. *)

val account :
  server:string ->
  network:string ->
  (string, string) result ->
  (string * Setup_changes.change list, string) result
(** [account ~server ~network answer] is the line to print and the changes the
    run made. A network that was there is a check and changes nothing; one this
    run created is a change. A failed command, or an answer carrying neither
    marker, is an error: the run will not report either. *)
