type env_value = Plain of string | Secret of string
type port = { host : int; container : int }
type restart_policy = No | On_failure | Always | Unless_stopped

type t = {
  name : string;
  image : string;
  tag : string;
  restart : restart_policy;
  network : string option;
  ports : port list;
  env : (string * env_value) list;
}

type error =
  | Empty_name
  | Invalid_name of string
  | Empty_image
  | Empty_tag
  | Invalid_restart_policy of string
  | Invalid_port of string
  | Duplicate_env_key of string
  | Invalid_env_key of string
  | Invalid_env_value of string

let error_to_string = function
  | Empty_name -> "managed container name must not be empty"
  | Invalid_name value ->
      Printf.sprintf
        "invalid managed container name: %S, expected an alphanumeric first \
         character followed by alphanumerics, underscore, dot or hyphen"
        value
  | Empty_image -> "managed container image must not be empty"
  | Empty_tag -> "managed container tag must not be empty"
  | Invalid_restart_policy value ->
      Printf.sprintf
        "invalid managed container restart policy: %S, expected one of \"no\", \
         \"on-failure\", \"always\", \"unless-stopped\""
        value
  | Invalid_port value ->
      Printf.sprintf
        "invalid managed container port: %S, expected \"<host>:<container>\" \
         with both between 1 and 65535"
        value
  | Duplicate_env_key key ->
      Printf.sprintf
        "managed container declares the environment key %S more than once" key
  | Invalid_env_key key ->
      Printf.sprintf
        "invalid managed container environment key: %S, expected a non-empty \
         name containing no \"=\" and no control characters"
        key
  (* Named by key rather than by value: the rejected value may be the
     credential, and this message reaches stderr. *)
  | Invalid_env_value key ->
      Printf.sprintf
        "invalid value for managed container environment key %S: values may \
         not contain control characters"
        key

let is_alphanumeric = function
  | 'a' .. 'z'
  | 'A' .. 'Z'
  | '0' .. '9' ->
      true
  | _ -> false

let is_name_char c =
  is_alphanumeric c
  ||
  match c with
  | '_'
  | '.'
  | '-' ->
      true
  | _ -> false

(* The name is used both as a Docker container name and as a single path
   segment under /etc/bondi. Requiring an alphanumeric first character rejects
   "." and ".." outright, and the character set admits no separator, so a name
   can neither traverse out of its directory nor resolve to one. *)
let validate_name value =
  if String.length value = 0 then Error Empty_name
  else if is_alphanumeric value.[0] && String.for_all is_name_char value then
    Ok value
  else Error (Invalid_name value)

let validate_non_empty error value =
  if String.length value = 0 then Error error else Ok value

let rec first_duplicate_key seen = function
  | [] -> None
  | (key, _) :: rest ->
      if List.mem key seen then Some key
      else first_duplicate_key (key :: seen) rest

let is_control c = Char.code c < 0x20 || Char.code c = 0x7f

(* The secret env file is one KEY=VALUE per line and Docker's --env-file parser
   does no unquoting, so a control character in either half declares variables
   the operator did not write. Rejecting here rather than escaping at render
   time is deliberate: there is no escape Docker would decode. *)
let validate_env_entry (key, value) =
  let raw_value =
    match value with
    | Plain s
    | Secret s ->
        s
  in
  if
    String.length key = 0
    || String.contains key '='
    || String.exists is_control key
  then Error (Invalid_env_key key)
  else if String.exists is_control raw_value then Error (Invalid_env_value key)
  else Ok ()

let rec validate_env_entries = function
  | [] -> Ok ()
  | entry :: rest -> (
      match validate_env_entry entry with
      | Error _ as err -> err
      | Ok () -> validate_env_entries rest)

let validate_env env =
  match validate_env_entries env with
  | Error e -> Error e
  | Ok () -> (
      match first_duplicate_key [] env with
      | Some key -> Error (Duplicate_env_key key)
      | None -> Ok env)

let create ~name ~image ~tag ~restart ~network ~ports ~env =
  let ( let* ) = Result.bind in
  let* name = validate_name name in
  let* image = validate_non_empty Empty_image image in
  let* tag = validate_non_empty Empty_tag tag in
  let* env = validate_env env in
  Ok { name; image; tag; restart; network; ports; env }

let restart_policy_of_string = function
  | "no" -> Ok No
  | "on-failure" -> Ok On_failure
  | "always" -> Ok Always
  | "unless-stopped" -> Ok Unless_stopped
  | value -> Error (Invalid_restart_policy value)

let is_valid_port number = number >= 1 && number <= 65535

let port_of_string value =
  match String.split_on_char ':' value with
  | [ host; container ] -> (
      match (int_of_string_opt host, int_of_string_opt container) with
      | Some host, Some container ->
          if is_valid_port host && is_valid_port container then
            Ok { host; container }
          else Error (Invalid_port value)
      | Some _, None
      | None, Some _
      | None, None ->
          Error (Invalid_port value))
  | _ -> Error (Invalid_port value)

let ports_of_strings values =
  let ( let* ) = Result.bind in
  let collect acc value =
    let* ports = acc in
    let* port = port_of_string value in
    Ok (port :: ports)
  in
  List.fold_left collect (Ok []) values |> Result.map List.rev

let name t = t.name
let image t = t.image
let tag t = t.tag
let restart t = t.restart
let network t = t.network
let ports t = t.ports
let is_valid_name value = Result.is_ok (validate_name value)
let container_name_of name = "bondi-" ^ name
let config_dir_of name = "/etc/bondi/" ^ name
let container_name t = container_name_of t.name
let config_dir t = config_dir_of t.name
let env_file_path t = config_dir t ^ "/env"

let secrets_of t =
  List.filter_map
    (fun (key, value) ->
      match value with
      | Secret s -> Some (key, s)
      | Plain _ -> None)
    t.env

let plain_env t =
  List.filter_map
    (fun (key, value) ->
      match value with
      | Plain s -> Some (key, s)
      | Secret _ -> None)
    t.env

let secret_env_file_contents t =
  match secrets_of t with
  | [] -> None
  | entries ->
      Some
        (String.concat ""
           (List.map
              (fun (key, value) -> Printf.sprintf "%s=%s\n" key value)
              entries))

let restart_policy_to_string = function
  | No -> "no"
  | On_failure -> "on-failure"
  | Always -> "always"
  | Unless_stopped -> "unless-stopped"

let canonical_env_value = function
  | Plain s -> Printf.sprintf "plain:%S" s
  | Secret s -> Printf.sprintf "secret:%S" s

let compare_ports a b =
  match Int.compare a.host b.host with
  | 0 -> Int.compare a.container b.container
  | ordering -> ordering

(* Canonical rendering of every declared field, used only as digest input.
   Values are emitted with %S so that separators occurring inside a value
   cannot forge a field boundary, and env and ports are sorted so that
   reordering bondi.yaml does not read as drift. *)
let canonical_spec t =
  let buf = Buffer.create 256 in
  let field key value =
    Buffer.add_string buf (Printf.sprintf "%s=%s\n" key value)
  in
  field "name" (Printf.sprintf "%S" t.name);
  field "image" (Printf.sprintf "%S" t.image);
  field "tag" (Printf.sprintf "%S" t.tag);
  field "restart" (Printf.sprintf "%S" (restart_policy_to_string t.restart));
  field "network"
    (match t.network with
    | None -> "none"
    | Some network -> Printf.sprintf "%S" network);
  List.iter
    (fun port -> field "port" (Printf.sprintf "%d:%d" port.host port.container))
    (List.sort compare_ports t.ports);
  List.iter
    (fun (key, value) ->
      field "env" (Printf.sprintf "%S=%s" key (canonical_env_value value)))
    (List.sort (fun (a, _) (b, _) -> String.compare a b) t.env);
  Buffer.contents buf

let spec_hash t = Digest.to_hex (Digest.string (canonical_spec t))
let type_label = ("bondi.type", "managed")

let labels t =
  [
    ("bondi.managed", "true");
    type_label;
    ("bondi.name", t.name);
    ("bondi.spec-hash", spec_hash t);
  ]

(* The image goes last: Docker reads anything after it as the container's own
   command. Secrets are referenced by file rather than passed with -e, so no
   credential reaches the command line. *)
let run_args t =
  List.concat
    [
      [
        "run";
        "-d";
        "--name";
        container_name t;
        "--restart";
        restart_policy_to_string t.restart;
      ];
      (match t.network with
      | None -> []
      | Some network -> [ "--network"; network ]);
      List.concat_map
        (fun port -> [ "-p"; Printf.sprintf "%d:%d" port.host port.container ])
        t.ports;
      (match secret_env_file_contents t with
      | None -> []
      | Some _ -> [ "--env-file"; env_file_path t ]);
      List.concat_map
        (fun (key, value) -> [ "-e"; key ^ "=" ^ value ])
        (plain_env t);
      List.concat_map
        (fun (key, value) -> [ "--label"; key ^ "=" ^ value ])
        (labels t);
      [ t.image ^ ":" ^ t.tag ];
    ]
