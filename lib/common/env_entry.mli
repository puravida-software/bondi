(** One [KEY=VALUE] entry of an environment file Bondi writes.

    A managed container's env file and a cron job's secrets file are both one
    [KEY=VALUE] per line, read by a parser that does no unquoting. A control
    character in either half is not data but a second record, so an entry is
    checked before it is written, by the client and by the server alike, and
    refused rather than escaped: there is no escape the reader would decode.

    A key is accepted when it is not empty and holds neither [=] nor a byte from
    0x00 to 0x1F or 0x7F. A value is accepted when it holds no such byte; it may
    be empty and may hold [=]. *)

(** Why an entry was refused. Neither case carries the value, which is often a
    credential. *)
type error =
  | Invalid_key of string
      (** The key is empty, holds [=], or holds a control character. *)
  | Invalid_value of { key : string }
      (** The value under this key holds a control character. *)

val check : key:string -> value:string -> (unit, error) result
(** [check ~key ~value] accepts the entry if both halves follow the rule above.
    The key is judged first, so an entry wrong in both is an {!Invalid_key}. *)

val job_refusal : (string * (string * string) list) list -> string option
(** [job_refusal jobs] is the one sentence refusing the secret entries of the
    named jobs, or [None] when every entry passes {!check}. [jobs] pairs each
    job's name with its [(key, value)] entries. Each offender is named by job
    and key, in job then entry order, and never by value, which is a credential.
    The client and the server both phrase their refusal with this, so the two
    cannot differ. *)
