(** What the box must be able to do before setup touches the Alloy it already
    has.

    Alloy is started host-networked and setup then asks its [/-/healthy] with
    the host's [curl], so two facts about the box decide whether a replacement
    can succeed: [curl] resolves, and the port Alloy's HTTP server binds is free
    or already Alloy's own. Both are readable before anything is stopped, and a
    box that fails either would otherwise lose the Alloy it had and only then
    learn it cannot start the next one. Each fact is read by one probe and
    judged here; the caller runs the probe over SSH and brings the answer back.

    This module performs no I/O.

    {2 What the port check does not establish}

    The holder is told to be Alloy by one reading: a container named
    [bondi-alloy] that is running with the host network. A different process
    holding the port while such a container runs elsewhere on it is read as
    Alloy's. That cannot be told apart without [ss -p], which needs root, and
    the cost of the misreading is a replacement that fails its health wait,
    which is the case the wait exists for. *)

(** What the host said about [curl]. *)
type curl_verdict =
  | Curl_present
  | Curl_missing  (** [curl] is not on the host's [PATH]. *)
  | Curl_unreadable of Host_answer.t
      (** The probe printed no verdict, so nothing about [curl] is known. *)

val curl_probe_command : string
(** One remote shell command that prints one marker line and always exits 0, so
    a non-zero exit means the command could not be run, never a verdict. *)

val curl_verdict_of_probe : Host_answer.t -> curl_verdict
(** Reads {!curl_probe_command}'s answer. The trimmed answer is compared with
    each marker exactly; anything else, an empty answer included, is
    {!Curl_unreadable}. *)

val require_curl : port:int -> curl_verdict -> (unit, string) result
(** [Ok ()] for {!Curl_present}. Every other verdict is the sentence setup
    refuses with, and each names [port]: it is the port Alloy would have been
    asked on. *)

(** What the host said about [port]. *)
type port_verdict =
  | Port_free
  | Port_held_by_alloy
      (** Held, and a running [bondi-alloy] container with the host network
          exists: the Alloy setup is about to replace. *)
  | Port_held of { port : int }
      (** Held, and not by a host-networked [bondi-alloy]. *)
  | Port_unreadable of { port : int; answer : Host_answer.t }
      (** The probe printed no verdict, or could not tell: no [ss], or [ss]
          failed. Nothing about the port is known. *)

val port_probe_command : port:int -> string
(** One remote shell command that lists the host's TCP listeners on [port] with
    [ss -Hltn 'sport = :port'] and, if there is one, asks Docker whether
    [bondi-alloy] runs with the host network. It prints one marker line and
    always exits 0. *)

val port_verdict_of_probe : port:int -> Host_answer.t -> port_verdict
(** Reads {!port_probe_command}'s answer, as {!curl_verdict_of_probe} does. *)

val require_port_available : port_verdict -> (unit, string) result
(** [Ok ()] for {!Port_free} and {!Port_held_by_alloy}. Every other verdict is
    the sentence setup refuses with; each names the port and says nothing was
    stopped. *)
