(* The document is read with the two accessors below rather than with a JSON
   query library, because what the scan needs from it is narrow: a member by
   name, and the entries of a list. Both enumerate every constructor the type
   has, so a value shape that stops being handled is a compile error rather
   than a key silently reported as absent. *)
let member key (json : Yojson.Safe.t) =
  match json with
  | `Assoc assoc -> List.assoc_opt key assoc
  | `Null
  | `Bool _
  | `Int _
  | `Intlit _
  | `Float _
  | `String _
  | `List _ ->
      None

let entries (json : Yojson.Safe.t) =
  match json with
  | `List items -> items
  | `Null
  | `Bool _
  | `Int _
  | `Intlit _
  | `Float _
  | `String _
  | `Assoc _ ->
      []

(* A key counts as declared when it is present, whatever it is set to. The
   value is not what stops the manifest parsing -- the member is -- so a key
   written with no value at all is refused for the same reason and with the same
   message as one written with a value. *)
let declared key json =
  match member key json with
  | None -> false
  | Some _ -> true

let bind_address_advice =
  "it is no longer read. The orchestrator serves nothing over the network, so \
   there is no socket to bind. Remove the line."

(* The value is not echoed back: a message printed to a terminal, a CI log and
   a scrollback is a poorer place for a secret than the file it came from. What
   the message owes the operator is the instruction to rotate, which is the one
   thing removing the line does not do for them. *)
let api_token_advice =
  "it is no longer read. The orchestrator serves nothing over the network, so \
   there is no request to authenticate. Remove the line, and rotate the value \
   if it was ever a real secret -- a credential that sat in a configuration \
   file is compromised whether or not anything still reads it."

let server_port_advice =
  "it is no longer read. Nothing dials a server directly any more, so there is \
   no port for it to name. Remove the line. This is not the port under \
   service, which is the port your own container listens on and is read on \
   every deploy."

let retired_in_bondi_server json =
  match member "bondi_server" json with
  | None -> []
  | Some bondi_server ->
      [ ("bind_address", bind_address_advice); ("api_token", api_token_advice) ]
      |> List.filter_map (fun (key, advice) ->
          if declared key bondi_server then Some ("bondi_server." ^ key, advice)
          else None)

let retired_in_server ~path server =
  if declared "port" server then [ (path ^ ".port", server_port_advice) ]
  else []

(* A server block reaches the record from two places -- the service's list and
   each cron job's single server -- and it is the same record in both, so a port
   declared under either stops the same manifest from parsing. The index is
   carried into the path so the operator is sent to an entry rather than to a
   list. *)
let retired_in_service json =
  match member "service" json with
  | None -> []
  | Some service -> (
      match member "servers" service with
      | None -> []
      | Some servers ->
          entries servers
          |> List.mapi (fun index server ->
              retired_in_server
                ~path:(Printf.sprintf "service.servers[%d]" index)
                server)
          |> List.concat)

let retired_in_cron_jobs json =
  match member "cron_jobs" json with
  | None -> []
  | Some cron_jobs ->
      entries cron_jobs
      |> List.mapi (fun index job ->
          match member "server" job with
          | None -> []
          | Some server ->
              retired_in_server
                ~path:(Printf.sprintf "cron_jobs[%d].server" index)
                server)
      |> List.concat

let message declared_keys =
  let line (path, advice) = Printf.sprintf "%s: %s" path advice in
  String.concat "\n"
    ("bondi.yaml declares settings Bondi no longer reads, and a manifest that \
      declares one does not parse at all. Remove them and run again."
    :: List.map line declared_keys)

let check json =
  match
    retired_in_bondi_server json
    @ retired_in_service json
    @ retired_in_cron_jobs json
  with
  | [] -> Ok ()
  | declared_keys -> Error (message declared_keys)
