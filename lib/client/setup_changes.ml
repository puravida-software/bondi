type recreate_reason =
  | Config_changed
  | No_digest
  | Image_moved
  | Not_running
  | Mounted_file_missing

type orchestrator_reason =
  | Version of { running : Host_answer.t; wanted : string }
  | Reason of recreate_reason

type corrected_site =
  | Alloy_config_mode
  | Alloy_env_mode
  | Orchestrator_restart_policy
  | Acme_file_permissions

type change =
  | Docker_installed
  | Network_created of string
  | Acme_file_created
  | Orchestrator_created of string
  | Orchestrator_recreated of orchestrator_reason
  | Orchestrator_removed
  | Orchestrator_stopped
  | Alloy_created
  | Alloy_recreated of recreate_reason
  | Alloy_removed
  | Alloy_stopped
  | Alloy_config_removed
  | Journal_provisioned
  | Managed_created of string
  | Managed_recreated of string
  | Managed_removed of string
  | Managed_stopped of string
  | Corrected of corrected_site

let of_correction correction =
  match Setup_phases.corrected_site correction with
  | None -> None
  | Some Setup_phases.Journal_storage -> Some Journal_provisioned
  | Some Setup_phases.Alloy_config_mode -> Some (Corrected Alloy_config_mode)
  | Some Setup_phases.Alloy_env_mode -> Some (Corrected Alloy_env_mode)
  | Some Setup_phases.Orchestrator_restart_policy ->
      Some (Corrected Orchestrator_restart_policy)
  | Some Setup_phases.Acme_file_permissions ->
      Some (Corrected Acme_file_permissions)

(* Every reason is said in parentheses after the word. *)
let recreated ~subject = function
  | Config_changed -> subject ^ " recreated (config changed)"
  | No_digest -> subject ^ " recreated (no config digest)"
  | Image_moved -> subject ^ " recreated (image moved)"
  | Not_running -> subject ^ " recreated (not running)"
  | Mounted_file_missing -> subject ^ " recreated (mounted file missing)"

(* Worded here rather than borrowed from the correction account's subjects:
   those name the file or container in full, and this line is a summary of the
   lines above it, which already do. The journal's correction is said as what
   it achieved, the same as the change it maps to. *)
let corrected_item = function
  | Orchestrator_restart_policy -> "orchestrator restart policy corrected"
  | Alloy_config_mode -> "Alloy config mode corrected"
  | Alloy_env_mode -> "Alloy credentials mode corrected"
  | Acme_file_permissions -> "ACME file permissions corrected"

(* A version change is said as the move itself, since "recreated" adds nothing
   an operator reading "0.25.0 -> 0.30.0" does not already know. *)
let orchestrator_item = function
  | Version { running; wanted } ->
      Printf.sprintf "orchestrator %s \xe2\x86\x92 %s"
        (Host_answer.to_string running)
        wanted
  | Reason reason -> recreated ~subject:"orchestrator" reason

let item = function
  | Docker_installed -> "Docker installed"
  | Network_created network -> Printf.sprintf "network %s created" network
  | Acme_file_created -> "ACME file created"
  | Orchestrator_created version ->
      Printf.sprintf "orchestrator %s created" version
  | Orchestrator_recreated reason -> orchestrator_item reason
  | Orchestrator_removed -> "orchestrator removed"
  | Orchestrator_stopped -> "orchestrator stopped"
  | Alloy_created -> "Alloy created"
  | Alloy_recreated reason -> recreated ~subject:"Alloy" reason
  | Alloy_removed -> "Alloy removed"
  | Alloy_stopped -> "Alloy stopped"
  | Alloy_config_removed -> "Alloy config removed"
  | Journal_provisioned -> "journal made persistent"
  | Managed_created name -> name ^ " created"
  | Managed_recreated name -> name ^ " recreated (config changed)"
  | Managed_removed name -> name ^ " removed"
  | Managed_stopped name -> name ^ " stopped"
  | Corrected site -> corrected_item site

(* The container a removal or a recreation is about. Two exhaustive readings of
   [change] rather than a match over pairs of them, so a constructor added to
   [change] has to say here whether it removes or recreates anything. *)
type container = Orchestrator | Alloy | Managed of string

let removed = function
  | Orchestrator_removed -> Some Orchestrator
  | Alloy_removed -> Some Alloy
  | Managed_removed name -> Some (Managed name)
  | Docker_installed
  | Network_created _
  | Acme_file_created
  | Orchestrator_created _
  | Orchestrator_recreated _
  | Alloy_created
  | Alloy_recreated _
  | Journal_provisioned
  | Managed_created _
  | Managed_recreated _
  | Orchestrator_stopped
  | Alloy_stopped
  | Alloy_config_removed
  | Managed_stopped _
  | Corrected _ ->
      None

let recreated_container = function
  | Orchestrator_recreated _ -> Some Orchestrator
  | Alloy_recreated _ -> Some Alloy
  | Managed_recreated name -> Some (Managed name)
  | Docker_installed
  | Network_created _
  | Acme_file_created
  | Orchestrator_created _
  | Orchestrator_removed
  | Alloy_created
  | Alloy_removed
  | Journal_provisioned
  | Managed_created _
  | Managed_removed _
  | Orchestrator_stopped
  | Alloy_stopped
  | Alloy_config_removed
  | Managed_stopped _
  | Corrected _ ->
      None

(* The container a stop is about, read exhaustively for the reason the two
   above are. *)
let stopped = function
  | Orchestrator_stopped -> Some Orchestrator
  | Alloy_stopped -> Some Alloy
  | Managed_stopped name -> Some (Managed name)
  | Docker_installed
  | Network_created _
  | Acme_file_created
  | Orchestrator_created _
  | Orchestrator_recreated _
  | Orchestrator_removed
  | Alloy_created
  | Alloy_recreated _
  | Alloy_removed
  | Alloy_config_removed
  | Journal_provisioned
  | Managed_created _
  | Managed_recreated _
  | Managed_removed _
  | Corrected _ ->
      None

let settled changes =
  let recreated_later container rest =
    List.exists (fun later -> recreated_container later = Some container) rest
  in
  let removed_later container rest =
    List.exists (fun later -> removed later = Some container) rest
  in
  let rec settle = function
    | [] -> []
    | change :: rest -> (
        match (stopped change, removed change) with
        | Some container, _
          when removed_later container rest || recreated_later container rest ->
            settle rest
        | _, Some container when recreated_later container rest -> settle rest
        | _, _ -> change :: settle rest)
  in
  settle changes

let closing_line ~server = function
  | [] -> Printf.sprintf "setup changed nothing on server %s" server
  | _ :: _ as changes ->
      Printf.sprintf "setup changed on server %s: %s" server
        (String.concat ", " (List.map item changes))
