let ( let* ) = Result.bind

type t = {
  name : string;
  registry : string option;
  tag : string option;
  digest : string option;
}

type error = Empty | Malformed of string

(* The grammar's limits, as the Docker Engine states them. *)
let name_length_max = 255
let tag_length_max = 128

let is_lower_alnum = function
  | 'a' .. 'z'
  | '0' .. '9' ->
      true
  | _ -> false

let is_alnum = function
  | 'a' .. 'z'
  | 'A' .. 'Z'
  | '0' .. '9' ->
      true
  | _ -> false

let is_word c = is_alnum c || Char.equal c '_'

let is_upper = function
  | 'A' .. 'Z' -> true
  | _ -> false

let is_lower_hex = function
  | 'a' .. 'f'
  | '0' .. '9' ->
      true
  | _ -> false

let is_digit = function
  | '0' .. '9' -> true
  | _ -> false

let is_ipv6_char c =
  is_digit c
  || Char.equal c ':'
  ||
  match c with
  | 'a' .. 'f'
  | 'A' .. 'F' ->
      true
  | _ -> false

let all p s = String.for_all p s && not (String.equal s "")

(* A path component: lowercase alphanumeric runs joined by [.], [_], [__] or a
   run of [-]. *)
let is_path_component s =
  let n = String.length s in
  let rec run i = i < n && is_lower_alnum s.[i] && alnums (i + 1)
  and alnums i =
    i = n || if is_lower_alnum s.[i] then alnums (i + 1) else separator i
  and separator i =
    match s.[i] with
    | '.' -> run (i + 1)
    | '_' ->
        if i + 1 < n && Char.equal s.[i + 1] '_' then run (i + 2)
        else run (i + 1)
    | '-' -> dashes (i + 1)
    | _ -> false
  and dashes i =
    if i < n && Char.equal s.[i] '-' then dashes (i + 1) else run i
  in
  run 0

let is_path s = List.for_all is_path_component (String.split_on_char '/' s)

(* A host name component: alphanumeric at both ends, [-] allowed between. *)
let is_domain_component s =
  let n = String.length s in
  n > 0
  && is_alnum s.[0]
  && is_alnum s.[n - 1]
  && String.for_all (fun c -> is_alnum c || Char.equal c '-') s

let is_port s = all is_digit s
let is_host s = List.for_all is_domain_component (String.split_on_char '.' s)

(* [host[:port]], where the host is a dot-separated name or a bracketed IPv6
   address. *)
let is_registry_text s =
  let host_and_port ~host ~rest =
    match rest with
    | "" -> host
    | _ ->
        Char.equal rest.[0] ':'
        && is_port (String.sub rest 1 (String.length rest - 1))
        && host
  in
  match String.index_opt s ']' with
  | Some close when String.length s > 0 && Char.equal s.[0] '[' ->
      let inside = String.sub s 1 (close - 1) in
      let rest = String.sub s (close + 1) (String.length s - close - 1) in
      host_and_port ~host:(all is_ipv6_char inside) ~rest
  | Some _
  | None -> (
      match String.index_opt s ':' with
      | None -> is_host s
      | Some colon ->
          host_and_port
            ~host:(is_host (String.sub s 0 colon))
            ~rest:(String.sub s colon (String.length s - colon)))

(* The engine's test for whether a reference's first component names a
   registry: a path component can hold none of these. *)
let names_registry first =
  String.contains first '.'
  || String.contains first ':'
  || String.equal first "localhost"
  || String.exists is_upper first

let is_tag s =
  let n = String.length s in
  n > 0
  && n <= tag_length_max
  && is_word s.[0]
  && String.for_all
       (fun c -> is_word c || Char.equal c '.' || Char.equal c '-')
       s

(* Only the algorithms the engine accepts, each with its exact hex length. *)
let is_digest s =
  match String.index_opt s ':' with
  | None -> false
  | Some colon -> (
      let hex = String.sub s (colon + 1) (String.length s - colon - 1) in
      let length_for = function
        | "sha256" -> Some 64
        | "sha384" -> Some 96
        | "sha512" -> Some 128
        | _ -> None
      in
      match length_for (String.sub s 0 colon) with
      | None -> false
      | Some length -> String.length hex = length && all is_lower_hex hex)

let split_at s i =
  (String.sub s 0 i, String.sub s (i + 1) (String.length s - i - 1))

let of_string s =
  let malformed = Error (Malformed s) in
  let require ok value = if ok then Ok value else malformed in
  match s with
  | "" -> Error Empty
  | _ ->
      let* rest, digest =
        match String.index_opt s '@' with
        | None -> Ok (s, None)
        | Some at ->
            let rest, digest = split_at s at in
            require (is_digest digest) (rest, Some digest)
      in
      (* A [:] is a tag's only when no [/] follows it; one before a [/] is a
         registry's port. *)
      let* name, tag =
        match (String.rindex_opt rest ':', String.rindex_opt rest '/') with
        | Some colon, Some slash when colon < slash -> Ok (rest, None)
        | Some colon, (Some _ | None) ->
            let name, tag = split_at rest colon in
            require (is_tag tag) (name, Some tag)
        | None, (Some _ | None) -> Ok (rest, None)
      in
      let* registry =
        match String.index_opt name '/' with
        | Some slash when names_registry (String.sub name 0 slash) ->
            let registry, path = split_at name slash in
            require (is_registry_text registry && is_path path) (Some registry)
        | Some _
        | None ->
            require (is_path name) None
      in
      require
        (String.length name <= name_length_max)
        { name; registry; tag; digest }

let to_string t =
  let tag =
    match t.tag with
    | Some tag -> ":" ^ tag
    | None -> ""
  in
  let digest =
    match t.digest with
    | Some digest -> "@" ^ digest
    | None -> ""
  in
  t.name ^ tag ^ digest

let of_name_and_tag ~name ~tag =
  let composed = name ^ ":" ^ tag in
  let* reference = of_string composed in
  (* The composed text can parse with a different split, a tag already in the
     name or a digest in the tag, and that is not the reference asked for. *)
  if
    String.equal reference.name name
    && Option.equal String.equal reference.tag (Some tag)
    && Option.is_none reference.digest
  then Ok reference
  else Error (Malformed composed)

let name t = t.name
let registry t = t.registry
let tag t = t.tag
let digest t = t.digest

let pull_tag t =
  match (t.digest, t.tag) with
  | Some digest, (Some _ | None) -> digest
  | None, Some tag -> tag
  | None, None -> "latest"

let image_and_tag t =
  match (t.digest, t.tag) with
  | Some _, (Some _ | None) -> (to_string t, "")
  | None, Some tag -> (t.name, tag)
  | None, None -> (t.name, "")

let to_yojson t = `String (to_string t)

(* Room for the longest reference the grammar admits, about 520 bytes, so a
   rejected one is quoted whole. *)
let describe json =
  String_utils.bounded ~limit:1024 (Yojson.Safe.to_string json)

let of_yojson json =
  match json with
  | `String s -> (
      match of_string s with
      | Ok reference -> Ok reference
      | Error (Empty | Malformed _) ->
          Error ("not a valid image reference: " ^ describe json))
  | `Null
  | `Bool _
  | `Int _
  | `Intlit _
  | `Float _
  | `Assoc _
  | `List _ ->
      Error ("an image reference must be a JSON string, got " ^ describe json)

let grammar =
  "[registry/]path[:tag][@digest], with a lowercase path, and a digest of \
   sha256, sha384 or sha512 in lowercase hex"
