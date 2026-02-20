type string_map = (string * string) list

let raise_error msg json =
  raise (Ppx_yojson_conv_lib.Yojson_conv.Of_yojson_error (Failure msg, json))

let assoc_of_list to_value list =
  `Assoc (List.map (fun (key, value) -> (key, to_value value)) list)

let list_of_assoc ?field of_value json =
  match json with
  | `Assoc entries ->
      List.map (fun (key, value) -> (key, of_value value)) entries
  | `Null -> []
  | _ ->
      let msg =
        match field with
        | None -> "expected object"
        | Some name -> "expected object for " ^ name
      in
      raise_error msg json

let string_map_of_yojson ?field json =
  list_of_assoc ?field
    (fun value ->
      match value with
      | `String v -> v
      | _ -> raise_error "expected string values in object" json)
    json

let yojson_of_string_map map = assoc_of_list (fun value -> `String value) map
