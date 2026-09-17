type phase =
  | Docker
  | Network
  | Cron_docker
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
  | Cron_docker -> "cron docker"
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

type site = Alloy_config_mode | Orchestrator_restart_policy

(* What the run had to say about one site's reading. Two shapes rather than two
   lists: both are lines of one account, they are accumulated together in the
   order a run took them, and a register that holds only what went right is the
   silence this account exists to remove. *)
type finding =
  | Corrected of { found : Host_answer.t; applied : string }
  | Unreadable of { detail : string }

type correction = { site : site; finding : finding }

let restart_policy_corrected ~found ~applied =
  { site = Orchestrator_restart_policy; finding = Corrected { found; applied } }

let config_mode_corrected ~found ~applied =
  { site = Alloy_config_mode; finding = Corrected { found; applied } }

let unreadable_reading ~site ~detail = { site; finding = Unreadable { detail } }

(* The noun an operator reads the found value as. Exhaustive on purpose and this
   is where the enumerability of the sites has its teeth: a site added without
   saying what it reports does not compile, so the account cannot gain a place
   that feeds it nothing. *)
let reading = function
  | Alloy_config_mode -> "mode"
  | Orchestrator_restart_policy -> "restart policy"

(* What each site reads its value off: a path Bondi declares and a container
   Bondi names, both of them this tool's own constants, both read through the
   module that owns them so that the account cannot name a file the run did not
   touch.

   Derived from the site rather than passed in, and that is the guarantee rather
   than a convenience: there is no subject argument, so there is nowhere for a
   caller to hand a path or a container name it read out of a manifest.
   Exhaustive for the same reason [reading] is -- a site that does not say what
   it reads its value off does not compile. *)
let subject = function
  | Alloy_config_mode -> Bondi_common.Defaults.alloy_config_path
  | Orchestrator_restart_policy -> Bondi_common.Builtin_container.orchestrator

(* One shape for both sites, so that two of them cannot describe the same kind of
   disagreement differently -- which is what happened while each site worded its
   own sentence where it stood. The host's value comes before Bondi's because the
   first is the reading and the second is what the run already intended: an
   operator scanning the block is looking for what the box had.

   A reading nobody could take is worded here too, and printed in this block
   rather than where it was taken. It is the same register: a run that could not
   look reads exactly like a run that looked and found agreement, and a line
   about it written mid-transcript is scattered through the output of every other
   phase and lost altogether on the run that stopped after it. It says what could
   not be read and never what was found, so nothing reads it as a value the host
   reported. *)
let correction_line ~server correction =
  match correction.finding with
  | Corrected { found; applied } ->
      Printf.sprintf "%s on server %s was %s %s, applied %s"
        (subject correction.site) server (reading correction.site)
        (Host_answer.to_string found)
        applied
  | Unreadable { detail } ->
      Printf.sprintf
        "could not read the %s of %s on server %s, so this run cannot say what \
         it found: %s"
        (reading correction.site) (subject correction.site) server detail

(* Said rather than omitted: a run that corrected nothing and a run whose account
   was never taken are different facts about a box, and an absent sentence is how
   they came to read alike. It names no site's reading, because the fixtures that
   assert a converged run reported neither of them search this output for exactly
   those words.

   It also claims nothing about why, and that is the whole of it: there are three
   states, not two -- nothing diverged, everything that diverged was corrected,
   and something diverged that could not be corrected. The third is a run that
   failed on a read-back, and it prints this sentence too, so a clause explaining
   the emptiness as agreement would be false two lines under the failure that
   said otherwise. What the account knows is that its list is empty; why is the
   failure's to say. *)
let nothing_diverged ~server =
  Printf.sprintf "setup corrected nothing on server %s" server

let corrected correction =
  match correction.finding with
  | Corrected _ -> true
  | Unreadable _ -> false

(* The sentence is decided by whether anything was corrected and not by whether
   the list is empty. A run that could only say it was unable to look corrected
   nothing, and dropping the sentence there would make the register read as
   though it had. *)
let corrections_report ~server corrections =
  let lines = List.map (correction_line ~server) corrections in
  if List.exists corrected corrections then lines
  else lines @ [ nothing_diverged ~server ]
