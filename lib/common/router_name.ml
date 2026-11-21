let is_letter_or_digit = function
  | 'a' .. 'z'
  | 'A' .. 'Z'
  | '0' .. '9' ->
      true
  | _ -> false

let is_later_character c =
  match c with
  | '_'
  | '-' ->
      true
  | c -> is_letter_or_digit c

let in_grammar name =
  String.length name >= 2
  && is_letter_or_digit name.[0]
  && String.for_all is_later_character name

type t = string

let acme_challenge_name = "acme-http"
let reserved = [ acme_challenge_name ]

let of_string ~field name =
  match (in_grammar name, String.equal name (String.lowercase_ascii name)) with
  | true, true -> (
      match List.mem name reserved with
      | true ->
          Error
            (Printf.sprintf
               "%s %S is reserved: Bondi's own Traefik container defines a \
                router, middleware and service of that name, and a service of \
                the same name would collide with them"
               field name)
      | false -> Ok name)
  | true, false ->
      Error
        (Printf.sprintf
           "%s %S cannot name a Traefik router: it holds an uppercase letter, \
            and Traefik label keys are case-insensitive, so names that differ \
            only by case would collide"
           field name)
  | false, _ ->
      Error
        (Printf.sprintf
           "%s %S cannot name a Traefik router: a router name is a lowercase \
            letter or digit followed by one or more lowercase letters, digits, \
            _ or -"
           field name)

let to_string t = t
let to_yojson t = `String t

let of_yojson ~field = function
  | `String name -> of_string ~field name
  | (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `Assoc _ | `List _) as
    other ->
      Error
        (Printf.sprintf "%s must be a string, got %s" field
           (Yojson.Safe.to_string other))

let grammar =
  "a lowercase letter or digit followed by one or more lowercase letters, \
   digits, _ or -, and is not one Bondi's own Traefik container defines"
