(* Every field of the record is named here rather than reached through field
   access, so a field added to it later does not pass this module silently. *)
let messages (server : Config_file.bondi_server) =
  let { Config_file.version = _; bind_address; api_token } = server in
  let binding =
    match bind_address with
    | None -> []
    | Some address ->
        [
          Printf.sprintf
            "bondi_server.bind_address is set to %s and no longer does \
             anything: the orchestrator serves no HTTP, so there is no socket \
             to bind. Remove it from bondi.yaml."
            address;
        ]
  in
  (* The token's value is not echoed: a message printed to a terminal, a CI log
     and a scrollback is a poorer place for a secret than the file it came
     from. *)
  let token =
    match api_token with
    | None -> []
    | Some _ ->
        [
          "bondi_server.api_token is set and no longer does anything: the \
           orchestrator serves no HTTP, so there is no request to \
           authenticate. Remove it from bondi.yaml, and rotate it if it was \
           ever a real secret -- a credential that sat in a configuration file \
           is compromised whether or not anything still reads it.";
        ]
  in
  binding @ token
