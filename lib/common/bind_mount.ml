type t = { host : string; container : string; read_only : bool }
type path_role = Host | Container

type error =
  | Not_absolute of { role : path_role; path : string }
  | Not_normalised of { role : path_role; path : string }
  | Control_character of { role : path_role; path : string }
  | Container_root
  | Duplicate_container_path of string

let ( let* ) = Result.bind

(* Every segment after the leading "/" is a name: none is empty (a doubled or
   trailing "/"), and none is "." or "..", which would make two spellings of one
   directory, or a path that leaves the directory it names. *)
let is_normalised path =
  let is_name = function
    | ""
    | "."
    | ".." ->
        false
    | _ -> true
  in
  match String.split_on_char '/' path with
  | "" :: segments -> List.for_all is_name segments
  | []
  | _ :: _ ->
      false

let check_form role path =
  match String_utils.has_control_char path with
  | true -> Error (Control_character { role; path })
  | false -> (
      match String_utils.starts_with ~prefix:"/" path with
      | false -> Error (Not_absolute { role; path })
      | true -> (
          match is_normalised path with
          | true -> Ok ()
          | false -> Error (Not_normalised { role; path })))

let check_host = function
  | "/" -> Ok ()
  | path -> check_form Host path

let check_container = function
  | "/" -> Error Container_root
  | path -> check_form Container path

let create ~host ~container ~read_only =
  let* () = check_host host in
  let* () = check_container container in
  Ok { host; container; read_only }

let host t = t.host
let container t = t.container
let read_only t = t.read_only

let role_name = function
  | Host -> "host"
  | Container -> "container"

let error_to_string = function
  | Not_absolute { role; path } ->
      Printf.sprintf "volume %s path %S is not absolute: it must start with /"
        (role_name role) path
  | Not_normalised { role; path } ->
      Printf.sprintf
        "volume %s path %S is not normalised: it must have no \".\" or \"..\" \
         segment, no doubled / and no trailing /"
        (role_name role) path
  | Control_character { role; path } ->
      Printf.sprintf
        "volume %s path %S holds a control character: paths must be printable"
        (role_name role) path
  | Container_root ->
      "volume container path \"/\" would hide the container's whole \
       filesystem: mount at a directory below /"
  | Duplicate_container_path path ->
      Printf.sprintf "volume container path %S is declared more than once" path

let entry_keys = [ "host"; "container"; "read_only" ]

(* A rejected entry, as the message carrying it will show it. Entries come from
   a bondi.yaml or a payload built from one, and paths are not secrets. *)
let describe json = String_utils.bounded ~limit:256 (Yojson.Safe.to_string json)

let no_unknown_key entry fields =
  match
    List.find_opt (fun (key, _) -> not (List.mem key entry_keys)) fields
  with
  | None -> Ok ()
  | Some (key, _) ->
      Error
        (Printf.sprintf
           "volume entry %s has unknown key %S: its keys are host, container \
            and read_only"
           (describe entry) key)

let no_repeated_key entry fields =
  let keys = List.map fst fields in
  match List.length keys = List.length (List.sort_uniq String.compare keys) with
  | true -> Ok ()
  | false ->
      Error (Printf.sprintf "volume entry %s repeats a key" (describe entry))

let field entry fields key ~kind decode =
  match List.assoc_opt key fields with
  | None ->
      Error
        (Printf.sprintf "volume entry %s is missing %s" (describe entry) key)
  | Some value -> (
      match decode value with
      | Some decoded -> Ok decoded
      | None ->
          Error
            (Printf.sprintf "volume entry %s: %s must be %s, got %s"
               (describe entry) key kind (describe value)))

let as_string = function
  | `String value -> Some value
  | `Null
  | `Bool _
  | `Int _
  | `Intlit _
  | `Float _
  | `Assoc _
  | `List _ ->
      None

let as_bool = function
  | `Bool value -> Some value
  | `Null
  | `Int _
  | `Intlit _
  | `Float _
  | `String _
  | `Assoc _
  | `List _ ->
      None

let mount_of_entry entry =
  match entry with
  | `Assoc fields ->
      let* () = no_unknown_key entry fields in
      let* () = no_repeated_key entry fields in
      let* host = field entry fields "host" ~kind:"a string" as_string in
      let* container =
        field entry fields "container" ~kind:"a string" as_string
      in
      let* read_only =
        field entry fields "read_only" ~kind:"true or false" as_bool
      in
      create ~host ~container ~read_only |> Result.map_error error_to_string
  | (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _) as
    other ->
      Error
        (Printf.sprintf
           "volume entry %s must be an object with the keys host, container \
            and read_only"
           (describe other))

let rec first_duplicate_container seen = function
  | [] -> None
  | mount :: rest -> (
      match List.mem mount.container seen with
      | true -> Some mount.container
      | false -> first_duplicate_container (mount.container :: seen) rest)

(* In document order, so that the entry a message names is the first one at
   fault. *)
let rec mounts_of_entries = function
  | [] -> Ok []
  | entry :: rest ->
      let* mount = mount_of_entry entry in
      let* tail = mounts_of_entries rest in
      Ok (mount :: tail)

let list_of_yojson json =
  match json with
  | `List entries -> (
      let* mounts = mounts_of_entries entries in
      match first_duplicate_container [] mounts with
      | None -> Ok mounts
      | Some path -> Error (error_to_string (Duplicate_container_path path)))
  | (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `Assoc _) as
    other ->
      Error
        (Printf.sprintf
           "volumes must be a list of entries with the keys host, container \
            and read_only, got %s"
           (describe other))

let list_to_yojson mounts =
  `List
    (List.map
       (fun { host; container; read_only } ->
         `Assoc
           [
             ("host", `String host);
             ("container", `String container);
             ("read_only", `Bool read_only);
           ])
       mounts)
