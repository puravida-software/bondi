type phase =
  | Docker
  | Network
  | Cron_curl
  | Acme
  | Orchestrator
  | Alloy
  | Managed

(* Named as an operator would say it while reading a failure, not as the
   constructor is spelled: the report is the only place these appear. *)
let name = function
  | Docker -> "Docker"
  | Network -> "network"
  | Cron_curl -> "cron curl"
  | Acme -> "ACME file"
  | Orchestrator -> "orchestrator"
  | Alloy -> "alloy"
  | Managed -> "managed containers"

let unfinished_phases ~failed ~remaining =
  List.fold_left
    (fun kept phase ->
      if phase = failed || List.mem phase kept then kept else phase :: kept)
    [] remaining
  |> List.rev

(* The server is named in this sentence rather than prefixed onto [reason]: the
   reason is the host's own words and is left exactly as the host said them, and
   a report that already names its server — the orchestrator's, which quotes the
   container's logs — would otherwise say so twice. *)
let failure_message ~server ~failed ~remaining ~reason =
  match unfinished_phases ~failed ~remaining with
  | [] ->
      Printf.sprintf
        "%s\n\
         setup stopped part-way through the %s phase on server %s, which was \
         the last one, so no phase was skipped."
        reason (name failed) server
  | _ :: _ as phases ->
      Printf.sprintf
        "%s\n\
         setup stopped part-way through the %s phase on server %s, so these \
         phases did not run: %s."
        reason (name failed) server
        (String.concat ", " (List.map name phases))
