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

type site =
  | Alloy_config_mode
  | Alloy_env_mode
  | Orchestrator_restart_policy
  | Journal_storage
  | Acme_file_permissions

(* What the run had to say about one site's reading. Two shapes rather than two
   lists: both are lines of one account, they are accumulated together in the
   order a run took them, and a register that holds only what went right is the
   silence this account exists to remove. *)
type found = Host_said of Host_answer.t | Journal_was_volatile

type finding =
  | Corrected of { found : found; applied : string }
  | Unreadable of { detail : string }

type correction = { site : site; finding : finding }

let restart_policy_corrected ~found ~applied =
  {
    site = Orchestrator_restart_policy;
    finding = Corrected { found = Host_said found; applied };
  }

let config_mode_corrected ~found ~applied =
  {
    site = Alloy_config_mode;
    finding = Corrected { found = Host_said found; applied };
  }

let env_mode_corrected ~found ~applied =
  {
    site = Alloy_env_mode;
    finding = Corrected { found = Host_said found; applied };
  }

let acme_permissions_corrected ~found ~applied =
  {
    site = Acme_file_permissions;
    finding = Corrected { found = Host_said found; applied };
  }

let journal_storage_provisioned =
  {
    site = Journal_storage;
    finding = Corrected { found = Journal_was_volatile; applied = "persistent" };
  }

let unreadable_reading ~site ~detail = { site; finding = Unreadable { detail } }

let corrected_site correction =
  match correction.finding with
  | Corrected _ -> Some correction.site
  | Unreadable _ -> None

(* The noun an operator reads the found value as. Exhaustive on purpose and this
   is where the enumerability of the sites has its teeth: a site added without
   saying what it reports does not compile, so the account cannot gain a place
   that feeds it nothing. *)
let reading = function
  | Alloy_config_mode
  | Alloy_env_mode ->
      "mode"
  | Orchestrator_restart_policy -> "restart policy"
  | Journal_storage -> "storage"
  | Acme_file_permissions -> "owner and mode"

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
  | Alloy_env_mode -> Bondi_common.Defaults.alloy_env_path
  | Orchestrator_restart_policy -> Bondi_common.Builtin_container.orchestrator
  | Journal_storage -> Alloy_run_args.journal_path
  | Acme_file_permissions -> Bondi_common.Defaults.acme_file_path

(* One shape for every site, so that two of them cannot describe the same kind of
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
      let found =
        match found with
        | Host_said answer -> Host_answer.to_string answer
        | Journal_was_volatile -> "volatile"
      in
      Printf.sprintf "%s on server %s was %s %s, applied %s"
        (subject correction.site) server (reading correction.site) found applied
  | Unreadable { detail } ->
      Printf.sprintf
        "could not read the %s of %s on server %s, so this run cannot say what \
         it found: %s"
        (reading correction.site) (subject correction.site) server detail

(* Only the lines. What a run says about itself as a whole -- that it changed
   something, and what, or that it changed nothing -- is the closing line that
   follows these, and it is worded over every change the run made, of which a
   correction is one kind. A sentence here about the corrections alone would say
   "nothing" on a run that had just replaced two containers. *)
let corrections_report ~server corrections =
  List.map (correction_line ~server) corrections
