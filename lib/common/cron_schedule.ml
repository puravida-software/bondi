type t = string

type error =
  | Empty
  | Control_character
  | Field_count of int
  | Bad_field of { field : string; reason : string }

let ( let* ) = Result.bind

(* A field's name and its least and greatest values. *)
type field = { name : string; low : int; high : int }

let minute = { name = "minute"; low = 0; high = 59 }
let hour = { name = "hour"; low = 0; high = 23 }
let day_of_month = { name = "day of month"; low = 1; high = 31 }
let month = { name = "month"; low = 1; high = 12 }
let day_of_week = { name = "day of week"; low = 0; high = 7 }
let fields = [ minute; hour; day_of_month; month; day_of_week ]

(* Tab is a control character, but it separates fields, so it is the one let
   through. *)
let is_control c =
  match c with
  | '\t' -> false
  | c -> Char.code c < 0x20 || Char.code c = 0x7f

let is_digit = function
  | '0' .. '9' -> true
  | _ -> false

(* The text split at every space and every tab, empty pieces kept: a run of
   separators leaves empty pieces between its characters, and a separator at
   either end leaves an empty first or last piece. *)
let pieces s =
  String.split_on_char ' ' s |> List.concat_map (String.split_on_char '\t')

let not_empty piece = not (String.equal piece "")

(* The last piece, for asking whether the text ends in a separator. *)
let rec last_piece = function
  | [] -> None
  | [ piece ] -> Some piece
  | _ :: rest -> last_piece rest

let bad field reason = Error (Bad_field { field = field.name; reason })

(* The value of [text] if it is digits only and from [low] to [high]. *)
let bounded ~low ~high text =
  match String.equal text "" || not (String.for_all is_digit text) with
  | true -> None
  | false -> (
      match int_of_string_opt text with
      | Some n when n >= low && n <= high -> Some n
      | Some _
      | None ->
          None)

let number field text =
  match bounded ~low:field.low ~high:field.high text with
  | Some n -> Ok n
  | None ->
      bad field
        (Printf.sprintf "%S is not a number from %d to %d" text field.low
           field.high)

let step field text =
  match bounded ~low:1 ~high:field.high text with
  | Some _ -> Ok ()
  | None ->
      bad field
        (Printf.sprintf "step %S is not a number from 1 to %d" text field.high)

let range field a b =
  let* low = number field a in
  let* high = number field b in
  match low <= high with
  | true -> Ok ()
  | false -> bad field (Printf.sprintf "range %s-%s is not ascending" a b)

(* An item is [*], a number or a range, and [*] or a range may carry a step. *)
let item field text =
  match String.split_on_char '/' text with
  | [ base ] -> (
      match String.split_on_char '-' base with
      | [ "*" ] -> Ok ()
      | [ n ] -> Result.map ignore (number field n)
      | [ a; b ] -> range field a b
      | []
      | _ :: _ :: _ :: _ ->
          bad field (Printf.sprintf "%S is not a number or a range" base))
  | [ base; s ] ->
      let* () =
        match String.split_on_char '-' base with
        | [ "*" ] -> Ok ()
        | [ a; b ] -> range field a b
        | []
        | [ _ ]
        | _ :: _ :: _ :: _ ->
            bad field
              (Printf.sprintf "%S is not * or a range, so it takes no step" base)
      in
      step field s
  | []
  | _ :: _ :: _ :: _ ->
      bad field (Printf.sprintf "%S holds more than one /" text)

let check_field field text =
  List.fold_left
    (fun checked part ->
      let* () = checked in
      match String.equal part "" with
      | true -> bad field "holds an empty item in its list"
      | false -> item field part)
    (Ok ())
    (String.split_on_char ',' text)

(* Each field against its text, in order. Lengths that differ are a wrong field
   count. *)
let rec check_fields fields texts ~count =
  match (fields, texts) with
  | [], [] -> Ok ()
  | field :: fields, text :: texts ->
      let* () = check_field field text in
      check_fields fields texts ~count
  | [], _ :: _
  | _ :: _, [] ->
      Error (Field_count count)

let of_string s =
  let* () =
    match (s, String.exists is_control s) with
    | "", _ -> Error Empty
    | _, true -> Error Control_character
    | _, false -> Ok ()
  in
  let pieces = pieces s in
  let texts = List.filter not_empty pieces in
  let count = List.length texts in
  let* () =
    match count with
    | 5 -> Ok ()
    | _ -> Error (Field_count count)
  in
  let* () =
    match (pieces, last_piece pieces) with
    | "" :: _, _ -> bad minute "has a space or tab before it"
    | _, Some "" -> bad day_of_week "has a space or tab after it"
    | _, (Some _ | None) -> Ok ()
  in
  let* () = check_fields fields texts ~count in
  Ok s

let to_string t = t

let grammar =
  "a schedule is five fields separated by spaces or tabs: minute (0-59), hour \
   (0-23), day of month (1-31), month (1-12) and day of week (0-7, 0 and 7 \
   being Sunday), each a comma-separated list of *, a number or an ascending \
   range a-b, where * or a range may be followed by /step"

let error_to_string = function
  | Empty -> "the schedule is empty: " ^ grammar
  | Control_character ->
      "the schedule holds a control character, which would end the crontab \
       line early: " ^ grammar
  | Field_count 1 -> "the schedule holds 1 field, not five: " ^ grammar
  | Field_count n ->
      Printf.sprintf "the schedule holds %d fields, not five: %s" n grammar
  | Bad_field { field; reason } -> Printf.sprintf "the %s %s" field reason

let to_yojson t = `String t

type json_error = [ `Not_a_string | `Invalid of error ]

let of_yojson = function
  | `String text -> of_string text |> Result.map_error (fun e -> `Invalid e)
  | `Null
  | `Bool _
  | `Int _
  | `Intlit _
  | `Float _
  | `Assoc _
  | `List _ ->
      Error `Not_a_string

let json_error_to_string = function
  | `Not_a_string -> "the schedule is not a string: " ^ grammar
  | `Invalid e -> error_to_string e
