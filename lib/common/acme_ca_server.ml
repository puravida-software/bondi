type t = string

let https_prefix = "https://"

(* The scheme is checked on the text by name, as written, and the host through
   [Uri], so [https://] alone and [https:///dir] name no host and are refused. *)
let names_a_host s =
  match Uri.host (Uri.of_string s) with
  | Some host -> String.length host > 0
  | None -> false

(* The value becomes one command-line flag of the Traefik container, so a space
   or a control byte, newline included, is refused: [Uri] would percent-encode
   some of them and read a host out of a value that is not one URL. *)
let has_blank_or_control s =
  String.exists (fun c -> Char.code c <= 0x20 || Char.code c = 0x7f) s

let of_string s =
  match
    String.starts_with ~prefix:https_prefix s
    && (not (has_blank_or_control s))
    && names_a_host s
  with
  | true -> Ok s
  | false ->
      Error
        (Printf.sprintf
           "%S is not an ACME directory URL: it must be an absolute https:// \
            URL that names a host and holds no whitespace or control character"
           s)

let to_string t = t
let to_yojson t = `String (to_string t)

(* Room for any URL a manifest plausibly holds, so a rejected one is quoted
   whole. *)
let describe json =
  String_utils.bounded ~limit:1024 (Yojson.Safe.to_string json)

let of_yojson json =
  match json with
  | `String s -> (
      match of_string s with
      | Ok server -> Ok server
      | Error (_ : string) ->
          Error ("not a valid ACME directory URL: " ^ describe json))
  | `Null
  | `Bool _
  | `Int _
  | `Intlit _
  | `Float _
  | `Assoc _
  | `List _ ->
      Error ("an ACME directory URL must be a JSON string, got " ^ describe json)

let grammar =
  "an absolute https:// URL that names a host, with no whitespace or control \
   byte"
