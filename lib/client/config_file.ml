open Ppx_yojson_conv_lib.Yojson_conv

type string_map = (string * string) list

let raise_error msg json =
  raise (Ppx_yojson_conv_lib.Yojson_conv.Of_yojson_error (Failure msg, json))

let int_of_yojson json =
  match json with
  | `Int value -> value
  | `Float value ->
      let truncated = Float.trunc value in
      if Float.equal truncated value then int_of_float value
      else
        raise_error (Printf.sprintf "expected integer, got float %f" value) json
  | `String value -> int_of_string value
  | _ -> raise_error "expected integer" json

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

type server_ssh = {
  user : string;
  private_key_contents : string;
  private_key_pass : string;
}
[@@deriving yojson]

type server = { ip_address : string; ssh : server_ssh option }
[@@deriving yojson]

type user_service = {
  image_name : string;
  port : int;
  registry_user : string option;
  registry_pass : string option;
  env_vars : string_map;
  servers : server list;
}
[@@deriving yojson]

type bondi_server = { version : string } [@@deriving yojson]

type traefik = { domain_name : string; image : string; acme_email : string }
[@@deriving yojson]

type t = {
  user_service : user_service; [@key "service"]
  bondi_server : bondi_server; [@key "bondi_server"]
  traefik : traefik; [@key "traefik"]
}
[@@deriving yojson]

let config_file_name = "bondi.yaml"

let read_file path =
  try
    let ic = open_in path in
    let length = in_channel_length ic in
    let contents = really_input_string ic length in
    close_in ic;
    Ok contents
  with
  | exn -> Error (Printexc.to_string exn)

let env_map () =
  let entries = Unix.environment () |> Array.to_list in
  let parse_entry entry =
    match String.split_on_char '=' entry with
    | [] -> None
    | key :: rest -> Some (key, String.concat "=" rest)
  in
  List.filter_map parse_entry entries

let apply_env_template contents =
  let env = env_map () in
  let data =
    `O (List.map (fun (key, value) -> (key, `String value)) env)
  in
  Mustache.(render (of_string contents) data)

let rec yojson_of_yaml = function
  | `O assoc ->
      `Assoc (List.map (fun (key, value) -> (key, yojson_of_yaml value)) assoc)
  | `A list -> `List (List.map yojson_of_yaml list)
  | `String value -> `String value
  | `Float value -> `Float value
  | `Bool value -> `Bool value
  | `Null -> `Null

let read () =
  match read_file config_file_name with
  | Error message -> Error message
  | Ok contents -> (
      let rendered = apply_env_template contents in
      match Yaml.of_string rendered with
      | Error (`Msg message) -> Error message
      | Ok yaml -> (
          try Ok (t_of_yojson (yojson_of_yaml yaml)) with
          | Ppx_yojson_conv_lib.Yojson_conv.Of_yojson_error (exn, _) ->
              Error (Printexc.to_string exn)
          | exn -> Error (Printexc.to_string exn)))
