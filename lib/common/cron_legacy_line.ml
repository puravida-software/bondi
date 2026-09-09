(* The grammar, in one place: the payload sits in the first single-quoted [-d]
   argument on the line, and the writer that produced these lines escaped every
   single quote in the JSON as '\'' before interpolating it. Both halves of that
   are here, because a reader that finds the closing quote by walking past '\''
   and then hands the bytes back with the escaping still in them returns four
   bytes where the job's own text had one, and what it returns is not JSON. *)
let payload_prefix = "-d '"
let shell_escaped_quote = "'\\''"

(* The text of the argument that opens at [start], up to the quote that closes
   it. An escaped quote is walked past rather than taken as the end, so an
   argument holding one is read whole; a line whose argument never closes has no
   argument rather than one running to the end of the line. *)
let quoted_argument line ~start =
  let length = String.length line in
  let escape_length = String.length shell_escaped_quote in
  let rec find_end index =
    if index >= length then None
    else if line.[index] <> '\'' then find_end (index + 1)
    else if
      index + escape_length <= length
      && String.equal (String.sub line index escape_length) shell_escaped_quote
    then find_end (index + escape_length)
    else Some index
  in
  match find_end start with
  | None -> None
  | Some stop -> Some (String.sub line start (stop - start))

(* Undo the writer's escaping, so what comes out is what the shell would have
   handed to curl rather than the spool file's rendering of it. *)
let unescape_shell_quotes value =
  let buffer = Buffer.create (String.length value) in
  let length = String.length value in
  let escape_length = String.length shell_escaped_quote in
  let rec loop index =
    if index >= length then Buffer.contents buffer
    else if
      index + escape_length <= length
      && String.equal (String.sub value index escape_length) shell_escaped_quote
    then (
      Buffer.add_char buffer '\'';
      loop (index + escape_length))
    else (
      Buffer.add_char buffer value.[index];
      loop (index + 1))
  in
  loop 0

let payload_of line =
  match String_utils.index_of ~needle:payload_prefix line with
  | None -> None
  | Some at -> (
      let start = at + String.length payload_prefix in
      match quoted_argument line ~start with
      | None -> None
      | Some argument -> Some (unescape_shell_quotes argument))

(* A string field of the recovered payload, or nothing at all. A payload that
   does not parse yields no field rather than a fragment of itself: every value
   on that line other than the two fields read here is a secret or a command,
   and there is no rendering of them a caller is allowed to make. *)
let string_field ~field line =
  match payload_of line with
  | None -> None
  | Some payload -> (
      match Yojson.Safe.from_string payload with
      | `Assoc fields -> (
          match List.assoc_opt field fields with
          | Some (`String value) -> Some value
          | Some
              ( `Assoc _ | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _
              | `Null )
          | None ->
              None)
      | `Bool _
      | `Float _
      | `Int _
      | `Intlit _
      | `List _
      | `Null
      | `String _ ->
          None
      | exception Yojson.Json_error _ -> None)

let job_name_of line = string_field ~field:"job" line
let image_of line = string_field ~field:"image" line
