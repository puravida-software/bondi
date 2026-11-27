(* The create's own output, the new network's id, is discarded, so a marker is
   the only thing a successful run prints. *)
let present_marker = "BONDI_NETWORK_PRESENT"
let created_marker = "BONDI_NETWORK_CREATED"

let ensure_command ~network =
  Printf.sprintf
    "if docker network inspect %s > /dev/null 2>&1; then echo %s; else docker \
     network create %s > /dev/null && echo %s; fi"
    (Filename.quote network) present_marker (Filename.quote network)
    created_marker

type answer = Present | Created | Unrecognised of string

let answer_of_output output =
  let trimmed = String.trim output in
  if String.equal trimmed present_marker then Present
  else if String.equal trimmed created_marker then Created
  else Unrecognised trimmed

let account ~server ~network = function
  | Error message -> Error message
  | Ok output -> (
      match answer_of_output output with
      | Present ->
          Ok
            ( Printf.sprintf "Network %s is present on server %s" network server,
              [] )
      | Created ->
          Ok
            ( Printf.sprintf "Network %s created on server %s" network server,
              [ Setup_changes.Network_created network ] )
      | Unrecognised said ->
          Error
            (Printf.sprintf
               "could not tell whether network %s was there or was created, so \
                setup will not report either: the host answered %s"
               network
               (match said with
               | "" -> "nothing"
               | said -> Host_answer.to_string (Host_answer.of_host_output said)))
      )
