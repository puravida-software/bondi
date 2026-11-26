(** The fields of a payload that carry a value owned by a common module, read
    with that module's codec.

    Each reader refuses a bad value with a message that names the field and
    states the owning module's grammar, and never quotes the value: a refusal's
    message never carries a value from the payload (see
    [Handler_error.message]), and a rejected reference may hold a pasted
    credential. {!cron_schedule_of_yojson} is the exception, and says why. The
    codecs that [deploy] and [run] share live here so neither reaches into the
    other's strategy for a message. *)

module Image_reference = Bondi_common.Image_reference

val image_reference_refusal : field:string -> string
(** The refusal for an image reference that does not parse. *)

val require_tag_or_digest :
  Image_reference.t -> (Image_reference.t, string) result
(** The reference, when it pins the image it names by a tag or a digest. One
    that names neither is refused: pulling it pulls [latest], which is not the
    image the operator declared. The refusal names the repository. *)

val service_name_of_yojson :
  Yojson.Safe.t -> (Bondi_common.Router_name.t, string) result

val service_image_of_yojson :
  Yojson.Safe.t -> (Image_reference.t, string) result
(** Also refuses a reference with neither a tag nor a digest. *)

val traefik_image_of_yojson :
  Yojson.Safe.t -> (Image_reference.t, string) result
(** Accepts an untagged reference, which pulls [latest]. *)

val cron_image_of_yojson : Yojson.Safe.t -> (Image_reference.t, string) result

val cron_schedule_of_yojson :
  job:string -> Yojson.Safe.t -> (Bondi_common.Cron_schedule.t, string) result
(** [cron_schedule_of_yojson ~job json] reads the schedule of the cron job named
    [job]. The refusal names the field and the job, since one payload can carry
    several jobs, and gives {!Bondi_common.Cron_schedule.error_to_string}'s
    reason. This is the one reader whose refusal carries payload values: the
    job's name, and for a bad field the item at fault, never the whole schedule.
    Neither is a place a credential is written. *)

val traefik_acme_ca_server_of_yojson :
  Yojson.Safe.t -> (Bondi_common.Acme_ca_server.t, string) result
