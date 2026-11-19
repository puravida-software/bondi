type t = { ready : bool }

(* How much of a rejected answer the reason carries. A document the server
   writes names at most a handful of probes, each with a short reason, and fits
   well inside this; what does not fit is an answer from something that is not
   the server, and the head of it is enough to say what that was. A judgement
   rather than a measurement. The answer is flattened first because the reason
   is printed on one line of a terminal, and an answer arrives on as many lines
   as its writer chose. *)
let quoted_limit = 1024

let quote text =
  String_utils.bounded ~limit:quoted_limit (String_utils.single_line text)

let refused reason text =
  Error (Printf.sprintf "%s; the answer was: %s" reason (quote text))

let ready_of = function
  | `Bool ready -> Ok ready
  | _ -> Error "ready is not a boolean"

let probes_of = function
  | `List _ -> Ok ()
  | _ -> Error "probes is not a list"

(* Exactly two keys, in either order, because JSON does not order an object's
   keys. A missing key, an extra one and a repeated one all fall to the last
   arm: each is a document the server does not write, and a repeated [ready]
   would otherwise mean choosing which of two flags to believe. *)
let fields_of = function
  | [ ("ready", ready); ("probes", probes) ]
  | [ ("probes", probes); ("ready", ready) ] ->
      Result.bind (probes_of probes) (fun () -> ready_of ready)
  | fields ->
      Error
        (Printf.sprintf
           "expected the keys ready and probes and no others, found: %s"
           (String.concat ", " (List.map fst fields)))

let of_string text =
  (* [from_string] raises on text that is not JSON, which is what a box answers
     when something other than the server wrote to stdout. Only that exception
     is turned into a refusal; anything else is not a fact about the answer. *)
  match Yojson.Safe.from_string text with
  | exception Yojson.Json_error detail ->
      refused ("the answer is not JSON (" ^ detail ^ ")") text
  | `Assoc fields -> (
      match fields_of fields with
      | Ok ready -> Ok { ready }
      | Error reason -> refused reason text)
  | _ -> refused "the answer is not a JSON object" text

let ready document = document.ready
