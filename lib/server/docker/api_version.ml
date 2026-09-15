type t = { major : int; minor : int }

let of_string : string -> (t, string) result =
 fun s ->
  let body =
    match String.length s > 0 && (s.[0] = 'v' || s.[0] = 'V') with
    | true -> String.sub s 1 (String.length s - 1)
    | false -> s
  in
  match String.split_on_char '.' body with
  | [ major; minor ] -> (
      match (int_of_string_opt major, int_of_string_opt minor) with
      | Some major, Some minor when major >= 0 && minor >= 0 ->
          Ok { major; minor }
      | _ ->
          Error
            (Printf.sprintf "not a Docker API version, major.minor expected: %S"
               s))
  | _ ->
      Error
        (Printf.sprintf "not a Docker API version, major.minor expected: %S" s)

let to_string : t -> string = fun t -> Printf.sprintf "%d.%d" t.major t.minor
let to_path_segment : t -> string = fun t -> "v" ^ to_string t

let compare : t -> t -> int =
 fun a b ->
  match Int.compare a.major b.major with
  | 0 -> Int.compare a.minor b.minor
  | ordering -> ordering

type window = { minimum : t; maximum : t }

let window : minimum:t -> maximum:t -> (window, string) result =
 fun ~minimum ~maximum ->
  match compare minimum maximum <= 0 with
  | true -> Ok { minimum; maximum }
  | false ->
      Error
        (Printf.sprintf
           "daemon reports a minimum API version above its maximum: %s > %s"
           (to_string minimum) (to_string maximum))

let choose : preferred:t -> window -> t =
 fun ~preferred window ->
  match
    (compare preferred window.minimum < 0, compare preferred window.maximum > 0)
  with
  | true, _ -> window.minimum
  | _, true -> window.maximum
  | false, false -> preferred
