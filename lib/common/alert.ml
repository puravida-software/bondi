type severity = Success | Failure | Critical
type outcome = Exited of int | Start_failed of string
type severity_map = (int * severity) list

type severity_map_error =
  | Unknown_severity of string
  | Duplicate_code of int
  | Malformed of string * Yojson.Safe.t

let severity_map_error_to_string = function
  | Unknown_severity key ->
      Printf.sprintf
        "unknown severity %S; expected one of \"success\", \"failure\", \
         \"critical\""
        key
  | Duplicate_code code ->
      Printf.sprintf "exit code %d is mapped to more than one severity" code
  | Malformed (context, value) ->
      Printf.sprintf "malformed alert severity map at %s: %s" context
        (Yojson.Safe.to_string value)

let default_severity_map = []

let severity_of_wire = function
  | "success" -> Some Success
  | "failure" -> Some Failure
  | "critical" -> Some Critical
  | _ -> None

(* Fold each declared severity's code list into the accumulated map, rejecting a
   code already claimed by another severity. Codes are integers by contract (the
   config layer types them so and the encoder emits them so); an entry outside
   that shape — a non-integer code, a non-list value, or a non-object map — is
   reported as [Malformed], carrying the offending JSON so the operator sees what
   was rejected. *)
let severity_map_of_yojson json =
  let ( let* ) = Result.bind in
  let add_code severity seen code =
    match List.assoc_opt code seen with
    | Some _ -> Error (Duplicate_code code)
    | None -> Ok ((code, severity) :: seen)
  in
  let parse_entry seen (key, value) =
    let* severity =
      match severity_of_wire key with
      | Some severity -> Ok severity
      | None -> Error (Unknown_severity key)
    in
    let* codes =
      match value with
      | `List items ->
          List.fold_right
            (fun item acc ->
              let* tail = acc in
              match item with
              | `Int code -> Ok (code :: tail)
              | _ -> Error (Malformed (key, item)))
            items (Ok [])
      | `Null -> Ok []
      | _ -> Error (Malformed (key, value))
    in
    List.fold_left
      (fun acc code ->
        let* seen = acc in
        add_code severity seen code)
      (Ok seen) codes
  in
  match json with
  | `Null -> Ok default_severity_map
  | `Assoc fields ->
      List.fold_left
        (fun acc entry ->
          let* seen = acc in
          parse_entry seen entry)
        (Ok default_severity_map) fields
  | _ -> Error (Malformed ("severity map", json))

let severity_to_wire = function
  | Success -> "success"
  | Failure -> "failure"
  | Critical -> "critical"

let severity_map_to_yojson map =
  let codes_for severity =
    List.filter_map
      (fun (code, mapped) ->
        if mapped = severity then Some (`Int code) else None)
      (List.rev map)
  in
  let entry severity =
    match codes_for severity with
    | [] -> None
    | codes -> Some (severity_to_wire severity, `List codes)
  in
  `Assoc (List.filter_map entry [ Success; Failure; Critical ])

let severity_of_exit_code map code =
  match List.assoc_opt code map with
  | Some severity -> severity
  | None -> if code = 0 then Success else Failure

let severity_of_outcome map = function
  | Start_failed _ -> Failure
  | Exited code -> severity_of_exit_code map code

type sink = { url : string; host : [ `host ] Domain_name.t }
type sink_error = Empty_url | Not_https of string | Invalid_url of string

let sink_error_to_string = function
  | Empty_url -> "alert sink url must not be empty"
  | Not_https url -> Printf.sprintf "alert sink url must use https: %S" url
  | Invalid_url url -> Printf.sprintf "invalid alert sink url: %S" url

let sink_of_string url =
  if String.length url = 0 then Error Empty_url
  else
    let uri = Uri.of_string url in
    match Uri.scheme uri with
    | Some "https" -> (
        match Uri.host uri with
        | Some host when String.length host > 0 -> (
            (* Parse the host to a validated hostname once, here at the boundary,
               so the delivery path carries a proven value and never re-parses or
               falls back to an unverifiable TLS handshake. *)
            match Result.bind (Domain_name.of_string host) Domain_name.host with
            | Ok host -> Ok { url; host }
            | Error _ -> Error (Invalid_url url))
        | Some _
        | None ->
            Error (Invalid_url url))
    | Some _ -> Error (Not_https url)
    | None -> Error (Invalid_url url)

let sink_url sink = sink.url
let sink_host sink = Domain_name.to_string sink.host
let sink_host_domain sink = sink.host

type sinks = { critical : sink list; failure : sink list }

let sink_list_of_yojson field json =
  match json with
  | `List items ->
      List.fold_right
        (fun item acc ->
          match acc with
          | Error _ as e -> e
          | Ok tl -> (
              match item with
              | `String s -> (
                  match sink_of_string s with
                  | Ok sink -> Ok (sink :: tl)
                  | Error e -> Error (field ^ ": " ^ sink_error_to_string e))
              | _ -> Error (field ^ " sinks must be url strings")))
        items (Ok [])
  | `Null -> Ok []
  | _ -> Error (field ^ " must be a list of urls")

let sinks_of_yojson json =
  let ( let* ) = Result.bind in
  match json with
  | `Assoc fields ->
      let get key =
        match List.assoc_opt key fields with
        | Some value -> value
        | None -> `Null
      in
      let* critical = sink_list_of_yojson "critical" (get "critical") in
      let* failure = sink_list_of_yojson "failure" (get "failure") in
      Ok { critical; failure }
  | `Null -> Ok { critical = []; failure = [] }
  | _ -> Error "alert sinks must be an object"

let sinks_to_yojson { critical; failure } =
  let urls sinks = `List (List.map (fun sink -> `String sink.url) sinks) in
  `Assoc [ ("critical", urls critical); ("failure", urls failure) ]

type payload = {
  job : string;
  severity : severity;
  exit_code : int option;
  timestamp : float;
}

let payload_to_yojson payload =
  `Assoc
    [
      ("job", `String payload.job);
      ("severity", `String (severity_to_wire payload.severity));
      ( "exit_code",
        match payload.exit_code with
        | Some code -> `Int code
        | None -> `Null );
      ("timestamp", `Float payload.timestamp);
    ]

type dispatch = { targets : sink list; payload : payload }

let plan map outcome sinks ~job ~timestamp =
  let severity = severity_of_outcome map outcome in
  let targets =
    match severity with
    | Success -> []
    | Failure -> sinks.failure
    | Critical -> sinks.critical
  in
  match targets with
  | [] -> None
  | _ :: _ ->
      let exit_code =
        match outcome with
        | Exited code -> Some code
        | Start_failed _ -> None
      in
      Some { targets; payload = { job; severity; exit_code; timestamp } }
