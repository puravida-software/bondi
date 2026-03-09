type string_map = (string * string) list

let assoc_of_list to_value list =
  `Assoc (List.map (fun (key, value) -> (key, to_value value)) list)

let list_of_assoc ?field of_value json =
  match json with
  | `Assoc entries ->
      Ok (List.map (fun (key, value) -> (key, of_value value)) entries)
  | `Null -> Ok []
  | _ ->
      Error
        (match field with
        | None -> "expected object"
        | Some name -> "expected object for " ^ name)

let string_map_of_yojson json =
  match json with
  | `Assoc entries ->
      let rec parse = function
        | [] -> Ok []
        | (key, `String v) :: rest ->
            Result.map (fun tl -> (key, v) :: tl) (parse rest)
        | (key, _) :: _ ->
            Error
              (Printf.sprintf "expected string value for key %s in string_map"
                 key)
      in
      parse entries
  | `Null -> Ok []
  | _ -> Error "expected object for string_map"

let string_map_to_yojson map = assoc_of_list (fun value -> `String value) map
