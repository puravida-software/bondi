(** The Docker Engine API version a request is made against.

    Every Engine request path is prefixed with this version, and a daemon
    rejects one outside its own [MinAPIVersion, ApiVersion] window with a 400
    and no other symptom. The window moves in both directions as engines are
    upgraded: an old engine caps the top, a new engine raises the floor. A
    constant compiled into Bondi cannot sit inside the intersection for every
    engine in the estate indefinitely — it only has to be wrong once, on one
    box, for every deploy and every status call against that box to fail.

    So the version is not chosen by Bondi alone. It is chosen from what the
    daemon says it accepts, which is what {!choose} does. This module is pure:
    asking the daemon is {!Bondi_server.Docker.Client.negotiate}'s job. *)

type t
(** A Docker Engine API version: a major and a minor, such as [1.44]. *)

val of_string : string -> (t, string) result
(** [of_string s] reads a version written either bare ([1.44]) or with the
    prefix a request path uses ([v1.44]). Anything else — an empty string, a
    major with no minor, a third component, a non-numeric part — is an error
    naming what was rejected. *)

val to_string : t -> string
(** [to_string t] is the bare form, [1.44]. This is what a daemon reports and
    what a diagnostic should show. *)

val to_path_segment : t -> string
(** [to_path_segment t] is the form a request path takes, [v1.44]. *)

val compare : t -> t -> int
(** [compare a b] orders by major then minor, numerically. Lexicographic
    comparison of the written form is wrong here and quietly so: it orders [1.9]
    above [1.41]. *)

type window
(** The inclusive range of API versions a daemon accepts, as it reports them. A
    [window] cannot be inverted — see {!val-window}. *)

val window : minimum:t -> maximum:t -> (window, string) result
(** [window ~minimum ~maximum] is the range a daemon advertises, or an error
    when [minimum] exceeds [maximum]. A daemon reporting an inverted window is
    not something to clamp against; it is something to refuse, because the
    result would satisfy neither bound. *)

val choose : preferred:t -> window -> t
(** [choose ~preferred w] is the version to make requests with: [preferred] when
    the daemon accepts it, and otherwise the nearest bound of [w] that it does.
    Total by construction — a [window] is non-empty, so some version in it is
    always acceptable. *)
