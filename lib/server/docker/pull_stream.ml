let ( let* ) = Result.bind

(* The most of an undecodable line a failure carries: enough to tell a cut-off
   progress line from something that is not the engine's stream at all, and
   short enough for a log line. *)
let rejected_line_limit = 512
let bounded = Bondi_common.String_utils.bounded ~limit:rejected_line_limit

let string_member key fields =
  match List.assoc_opt key fields with
  | Some (`String value) -> Some value
  | Some (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `Assoc _ | `List _)
  | None ->
      None

(* The detail's message is the documented field; [error] is its deprecated
   copy, read only when the detail carries no message. *)
let error_message fields =
  let detail_message =
    match List.assoc_opt "errorDetail" fields with
    | Some (`Assoc detail) -> string_member "message" detail
    | Some
        (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _)
    | None ->
        None
  in
  match (detail_message, string_member "error" fields) with
  | Some message, _
  | None, Some message ->
      message
  | None, None -> "the engine reported an error and gave no message"

let line_verdict line =
  match Yojson.Safe.from_string line with
  | exception Yojson.Json_error _ ->
      Error ("the pull's stream has a line that is not JSON: " ^ bounded line)
  | `Assoc fields ->
      if List.mem_assoc "error" fields || List.mem_assoc "errorDetail" fields
      then Error ("the pull failed: " ^ error_message fields)
      else Ok ()
  | `Null
  | `Bool _
  | `Int _
  | `Intlit _
  | `Float _
  | `String _
  | `List _ ->
      Error
        ("the pull's stream has a line that is not a JSON object: "
        ^ bounded line)

(* The engine ends a pull it carried through with a [Status: ...] line, for a
   fresh pull and for an image already present alike. *)
let is_terminal_status line =
  match Yojson.Safe.from_string line with
  | `Assoc fields -> (
      match string_member "status" fields with
      | Some status -> String.starts_with ~prefix:"Status:" status
      | None -> false)
  | _
  | (exception Yojson.Json_error _) ->
      false

let verdict body =
  (* The engine ends each line with [\r\n]; trimming also drops the blank
     remainder after the last one. *)
  let lines =
    String.split_on_char '\n' body
    |> List.map String.trim
    |> List.filter (fun line -> line <> "")
  in
  let* () =
    List.fold_left
      (fun acc line ->
        let* () = acc in
        line_verdict line)
      (Ok ()) lines
  in
  match List.rev lines with
  | last :: _ when is_terminal_status last -> Ok ()
  | _ :: _
  | [] ->
      Error
        "the pull's stream ended without its terminal Status line, so it was \
         cut off"
