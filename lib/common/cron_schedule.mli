(** A cron schedule: the five time fields of a crontab line.

    Bondi writes each cron job's schedule into root's crontab on the box, so a
    schedule is parsed before it is written, on the client when [bondi.yaml] is
    read and on the server when the deploy payload arrives. A value this module
    accepts holds exactly five fields and nothing that could start a second
    crontab line.

    A schedule is five fields separated by one or more spaces or tabs, with
    nothing before the first field or after the last. The fields are, in order,
    minute (0-59), hour (0-23), day of month (1-31), month (1-12) and day of
    week (0-7, where both 0 and 7 are Sunday). A field is a comma-separated list
    of one or more items, and an item is one of:
    - [*], every value of the field;
    - a number [n] inside the field's range;
    - a range [a-b] of two numbers inside the field's range, with [a <= b];
    - [*] or a range followed by [/s], every [s]th value of it, where [s] is
      from 1 to the field's maximum.

    Those are the forms and ranges that two cron daemons document with the same
    meaning: the [crontab(5)] page of Debian bookworm's [cron] package, version
    3.0pl1-162, and the [crontab(5)] page of [cronie] 1.7.1, as Ubuntu noble
    ships it. Debian's page admits 0 for day of month and for month, which names
    no calendar day, so it is refused. Month and day names, [@] nicknames, [~]
    random ranges and a step after a bare number are each read by only one of
    the two daemons, so they are refused too. The edges of the grammar were also
    installed and run on both daemons (Debian cron 3.0pl1-162 and Fedora cronie
    1.7.2), and both read each accepted form as documented. *)

type t
(** A schedule in the grammar above. *)

(** Why a schedule was refused. *)
type error =
  | Empty  (** The schedule is the empty string. *)
  | Control_character
      (** The schedule holds a byte from 0x00 to 0x1F, other than tab, or 0x7F.
          A newline would end the crontab line early. *)
  | Field_count of int
      (** The schedule holds this many fields rather than five. *)
  | Bad_field of { field : string; reason : string }
      (** The named field (["minute"], ["hour"], ["day of month"], ["month"] or
          ["day of week"]) is not in the grammar, for [reason]. *)

val of_string : string -> (t, error) result
(** [of_string s] accepts [s] if it is a schedule in the grammar above. *)

val to_string : t -> string
(** The schedule as it was written, byte for byte, separators included. *)

val error_to_string : error -> string
(** Why the schedule was refused. A bad field is named with the item at fault;
    the other refusals end with {!grammar}. The whole schedule is never quoted,
    so the caller names the job. *)

val grammar : string
(** One sentence stating what a schedule is, for a refusal to quote. *)

val to_yojson : t -> Yojson.Safe.t
(** The schedule as a JSON string, as written. *)

type json_error = [ `Not_a_string | `Invalid of error ]
(** Why a JSON value is not a schedule: it is not a string, or it is a string
    {!of_string} refused. *)

val of_yojson : Yojson.Safe.t -> (t, json_error) result
(** [of_yojson json] reads a schedule from a JSON string through {!of_string}.
    The one reader every decoder shares; each adds only the name of the job it
    is reading. *)

val json_error_to_string : json_error -> string
(** Why the value was refused, without the job, as {!error_to_string} does. A
    value that is not a string is quoted and followed by {!grammar}. *)
