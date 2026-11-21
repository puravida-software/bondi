(** The ACME directory URL that Traefik's certificate resolver orders from.

    When it is set, a Bondi-created Traefik orders its certificates from this
    server. When it is absent, Bondi sends Traefik no certificate-server flag,
    and Traefik's own default applies, which is Let's Encrypt production.

    An ACME directory is served over HTTPS, so only an absolute URL whose text
    starts with [https://] and names a host is accepted. That covers Let's
    Encrypt production and staging, and a local Pebble. A typo is refused when
    the value is read, rather than becoming a resolver that never orders. *)

type t
(** A URL that was accepted. *)

val of_string : string -> (t, string) result
(** Accept an absolute [https://] URL with a non-empty host and no whitespace or
    control byte. The scheme is matched as written, so [HTTPS://] is refused.
    Nothing is trimmed or normalised. The refusal quotes the rejected text and
    restates the rule. *)

val to_string : t -> string
(** The URL, exactly as it was accepted. *)

val to_yojson : t -> Yojson.Safe.t
(** Encode as a JSON string holding {!to_string}. *)

val of_yojson : Yojson.Safe.t -> (t, string) result
(** Decode a JSON string through {!of_string}. A value that is not a string, or
    a string that is refused, is refused, and the message carries the rejected
    JSON. *)

val grammar : string
(** One sentence stating what a URL must be, for a refusal that must not quote
    the rejected value. *)
