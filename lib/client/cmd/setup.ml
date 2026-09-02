let ( let* ) = Result.bind

let read_all ic =
  let buffer = Buffer.create 256 in
  (try
     while true do
       let line = input_line ic in
       Buffer.add_string buffer line;
       Buffer.add_char buffer '\n'
     done
   with
  | End_of_file -> ());
  Buffer.contents buffer

(* [input] is written to the command's standard input rather than embedded in
   the command itself, so that a payload carrying credentials never appears in
   argv on either machine. Nothing drains the command's output while the write
   is in flight, so callers must keep [input] small enough to fit the pipe
   buffer; an env file is a few hundred bytes. *)
let run_command_with_input cmd input =
  let in_chan, out_chan, err_chan =
    Unix.open_process_full cmd (Unix.environment ())
  in
  (* Writing to a command that has already exited raises SIGPIPE, which by
     default terminates this process before the exit status below can report
     anything. Ignoring it for the duration of the write is what turns that
     into the Sys_error the handler expects. Restored afterwards so the
     disposition is not changed program-wide. *)
  let previous_sigpipe = Sys.signal Sys.sigpipe Sys.Signal_ignore in
  Fun.protect
    ~finally:(fun () -> Sys.set_signal Sys.sigpipe previous_sigpipe)
    (fun () ->
      (* The command may exit before reading its input, which closes the pipe.
         That is reported by the exit status below, so the write failing is not
         itself an error worth surfacing. *)
      try
        output_string out_chan input;
        flush out_chan
      with
      | Sys_error _ -> ());
  close_out_noerr out_chan;
  let stdout = read_all in_chan in
  let stderr = read_all err_chan in
  match Unix.close_process_full (in_chan, out_chan, err_chan) with
  | Unix.WEXITED 0 -> Ok stdout
  | Unix.WEXITED code ->
      Error (Printf.sprintf "command failed (%d): %s" code (String.trim stderr))
  | Unix.WSIGNALED signal ->
      Error
        (Printf.sprintf "command killed (%d): %s" signal (String.trim stderr))
  | Unix.WSTOPPED signal ->
      Error
        (Printf.sprintf "command stopped (%d): %s" signal (String.trim stderr))

let run_command cmd = run_command_with_input cmd ""

let with_temp_key contents f =
  let path = Filename.temp_file "bondi-key-" ".pem" in
  let decoded = Docker_common.decode_private_key contents in
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () ->
      close_out_noerr oc;
      Sys.remove path)
    (fun () ->
      output_string oc decoded;
      close_out oc;
      Unix.chmod path 0o600;
      f path)

(* Shares Docker_common's option set rather than restating a subset of it.
   This spelling had BatchMode and StrictHostKeyChecking but not ConnectTimeout
   or the keepalives, so setup -- the command that makes by far the most SSH
   calls -- was the one with no bound on a connection that hangs.

   Multiplexing matters most here: setup issues 31 of these, and each one paid a
   full handshake. See Docker_common.multiplex_options. *)
let ssh_command ~user ~host ~key_path cmd =
  let destination = user ^ "@" ^ host in
  Printf.sprintf "ssh -i %s %s %s %s -- %s" (Filename.quote key_path)
    (String.concat " " Docker_common.ssh_options)
    (String.concat " " (Docker_common.multiplex_options ()))
    (Filename.quote destination)
    (Filename.quote cmd)

let remote_run ~user ~host ~key_path cmd =
  run_command (ssh_command ~user ~host ~key_path cmd)

let remote_run_with_input ~user ~host ~key_path ~input cmd =
  run_command_with_input (ssh_command ~user ~host ~key_path cmd) input

let get_docker_version ~user ~host ~key_path =
  remote_run ~user ~host ~key_path "docker --version"

let run_remote_docker ~user ~host ~key_path cmd =
  remote_run ~user ~host ~key_path ("docker " ^ cmd)

(* ------------------------------------------------------------------------- *)
(* Types                                                                     *)
(* ------------------------------------------------------------------------- *)

module Managed_container = Bondi_common.Managed_container

(* The listing that produces this state is a remote command that can fail to run
   at all, so "no container" and "no answer" are separate constructors. Reading
   the second as the first plans a [docker run] against a name the host may
   already be holding, and discards the transport error on the way.

   Running and stopped are one fact here, unlike the orchestrator's: every state
   a container can be in holds its name, and alloy carries no version the plan
   compares against, so a present container is stopped, removed and re-run
   whatever it was doing. *)
type alloy_state = Alloy_absent | Alloy_present | Alloy_undetermined of string

(* The orchestrator container is observed as three distinct facts rather than as
   a [string option] of the running version. A container that exists but is not
   running is neither "nothing there" nor "the right version is up": read as the
   first, the plan starts a container whose name is already taken; read as the
   second, setup skips the restart and leaves the host with nothing serving.
   Both were reachable while presence and version were separate fields. A
   fourth fact is that the listing never ran, which supports none of the three
   and is kept apart from them for the same reason. *)
type orchestrator_state =
  | Orchestrator_absent
  | Orchestrator_not_running
  | Orchestrator_running of { version : string }
  | Orchestrator_undetermined of string

(* Observed state of one managed container. Derived from the container's
   existence and its spec-hash label only, never from whether it is currently
   running: a container performing a scheduled self-restart still exists and
   still carries a matching hash, so it converges to no action. *)
type managed_state =
  | Managed_absent
  | Managed_present of { spec_hash : string }

(* The result of looking for managed containers, as distinct from what was
   found. A failed [docker ps] and a server with no managed containers are not
   the same fact: reading the first as the second makes the plan create
   containers that already exist. *)
type managed_observation =
  | Managed_unobserved of string
  | Managed_observed of (string * managed_state) list

(* What reading the host's Docker version established. The probe is a remote
   command that can fail to run at all, and a command that never ran says
   nothing about the host: read as an absence it makes the plan install Docker,
   which restarts the daemon and every container with it. Absence is the host's
   own report that the command does not exist, never a failure to ask — and
   both reach the client the same way, since [ssh] propagates the remote
   shell's exit 127 and [run_command] turns any non-zero exit into an [Error].
   The two are told apart by what the host said, not by which channel said
   it. *)
type docker_status =
  | Docker_installed of string
  | Docker_not_installed of string
  | Docker_undetermined of string

(* What to do about Docker, decided from the probe the interpreter runs for
   itself. It is a second SSH round trip and a second chance for the connection
   to drop, so the gathered status does not make it safe: the decision is the
   same one, taken again against a fresh reading. *)
type docker_install_verdict =
  | Docker_satisfied of string
  | Docker_install
  | Docker_abort of string

type setup_context = {
  docker_status : docker_status;
  orchestrator : orchestrator_state;
  alloy_state : alloy_state;
  managed : managed_observation;
}

type action =
  | EnsureDocker
  | EnsureAcmeFile
  | EnsureNetwork of string
  | RequireCronCurl
  | StopOrchestrator
  | RemoveOrchestrator
  | RunServer
  | EnsureAlloyConfig
  | RunAlloy
  | StopAlloy
  | RemoveAlloy
  | WriteManagedEnv of Managed_container.t
  | RunManaged of Managed_container.t
  | StopManaged of string
  | RemoveManaged of string
  | CleanManagedConfig of string

(* Which phase of the plan an action belongs to. The phase type and the report
   built from it live in [Setup_phases], which knows nothing about actions; this
   mapping is what [setup] passes in, and it stays here because the compiler can
   only insist that a new action is given a phase where the action type is in
   scope. *)
let phase_of_action : action -> Setup_phases.phase = function
  | EnsureDocker -> Setup_phases.Docker
  | EnsureNetwork _ -> Setup_phases.Network
  | RequireCronCurl -> Setup_phases.Cron_curl
  | EnsureAcmeFile -> Setup_phases.Acme
  | StopOrchestrator
  | RemoveOrchestrator
  | RunServer ->
      Setup_phases.Orchestrator
  | EnsureAlloyConfig
  | RunAlloy
  | StopAlloy
  | RemoveAlloy ->
      Setup_phases.Alloy
  | WriteManagedEnv _
  | RunManaged _
  | StopManaged _
  | RemoveManaged _
  | CleanManagedConfig _ ->
      Setup_phases.Managed

(* ------------------------------------------------------------------------- *)
(* Phase 1: Gather context (read-only)                                       *)
(* ------------------------------------------------------------------------- *)

(* [-a] rather than plain [ps]: since the orchestrator stopped running with
   --rm, a container that died on startup is still on the host, and a plain [ps]
   cannot see it. *)
let orchestrator_ps_command =
  "ps -a --filter name=^/bondi-orchestrator$ --format '{{.State}}\t{{.Image}}'"

(* ------------------------------------------------------------------------- *)
(* Orchestrator run command (pure, testable)                                  *)
(* ------------------------------------------------------------------------- *)

(* The publish address is the security boundary for this API, and nothing else
   is. The orchestrator mounts the host Docker socket, so reaching it is
   equivalent to root on the box; -p 3030:3030 published that to the internet
   on every host bondi has ever set up.

   Default 127.0.0.1. Cron is unaffected -- lib/server/crontab.ml calls
   http://localhost:3030 from the host, which is the published mapping. Remote
   callers use a tunnel:  ssh -N -L 3030:127.0.0.1:3030 root@<box>

   Non-loopback is allowed but not unauthenticated: without api_token the API
   is open, and an open API on a public address is remote root. Refusing here
   is the point -- a warning would be scrolled past and the box would sit
   exposed, which is exactly how this shipped. *)
let orchestrator_bind_address (config : Config_file.t) =
  Option.value config.bondi_server.bind_address ~default:"127.0.0.1"

let orchestrator_run_command (config : Config_file.t) : (string, string) result
    =
  let bind = orchestrator_bind_address config in
  if
    (not (Bondi_common.Net.is_loopback bind))
    && config.bondi_server.api_token = None
  then
    Error
      (Printf.sprintf
         "bondi_server.bind_address is %s, which is reachable from outside \
          this host, and bondi_server.api_token is not set. The orchestrator \
          mounts the host Docker socket, so an unauthenticated public bind is \
          remote root on this machine. Either remove bind_address (defaults to \
          127.0.0.1 and is reached with: ssh -N -L 3030:127.0.0.1:3030 \
          root@<box>), or set api_token."
         bind)
  else
    let volume_mounts, user_flag =
      match config.cron_jobs with
      | Some jobs when jobs <> [] ->
          ( " -v /var/spool/cron/crontabs:/var/spool/cron/crontabs",
            " --user root" )
      | _ -> ("", "")
    in
    let token_env =
      match config.bondi_server.api_token with
      | Some t -> " -e BONDI_API_TOKEN=" ^ Filename.quote t
      | None -> ""
    in
    let image = "mlopez1506/bondi-server:" ^ config.bondi_server.version in
    (* No --rm: a container that dies on startup erases itself under it, leaving
       no container, no logs and no error for either the operator or the
       readiness check. *)
    Ok
      (Printf.sprintf
         "docker run -d --name bondi-orchestrator -p %s:3030:3030 -v \
          /var/run/docker.sock:/var/run/docker.sock%s%s%s --group-add $(stat \
          -c %%g /var/run/docker.sock) --label bondi.managed=true --label \
          bondi.type=infrastructure --label bondi.logs=true %s"
         bind volume_mounts user_flag token_env image)

(* What the host reports its published binding as, so setup can check that what
   it asked for is what it got rather than assuming the run command took. *)
let orchestrator_port_command =
  "docker inspect bondi-orchestrator -f '{{range $p, $c := \
   .HostConfig.PortBindings}}{{range $c}}{{.HostIp}}{{end}}{{end}}'"

let published_binding_matches ~expected output =
  let got = String.trim output in
  (* Docker normalises an empty HostIp to "all interfaces". Treat it as 0.0.0.0
     rather than as agreement with whatever was asked for. *)
  let got = if got = "" then "0.0.0.0" else got in
  if got = expected then Ok () else Error got

let orchestrator_version_of_image image =
  let prefix = "mlopez1506/bondi-server:" in
  if Bondi_common.String_utils.starts_with ~prefix image then
    String.sub image (String.length prefix)
      (String.length image - String.length prefix)
  else
    (* A fork or a locally built image is still the orchestrator by name. The
       whole image is reported so the version-mismatch message names something
       the operator can recognise. *)
    image

let orchestrator_state_of_ps_output output =
  let line =
    output
    |> String.split_on_char '\n'
    |> List.find_opt (fun line -> String.trim line <> "")
  in
  match line with
  | None -> Orchestrator_absent
  | Some line -> (
      match String.split_on_char '\t' (String.trim line) with
      | [ state; image ] -> (
          match String.trim state with
          | "running" ->
              Orchestrator_running
                { version = orchestrator_version_of_image (String.trim image) }
          (* "created", "restarting", "paused", "exited", "removing" and "dead".
             None of them is serving, and every one of them holds the container
             name, so all converge to the same plan: remove it, then run. *)
          | _ -> Orchestrator_not_running)
      (* A line that does not parse still means a container by that name exists.
         Replacing it is the safe reading; treating it as absent would plan a
         run that collides with it. *)
      | []
      | [ _ ]
      | _ :: _ :: _ :: _ ->
          Orchestrator_not_running)

let orchestrator_state_of_probe = function
  | Ok output -> orchestrator_state_of_ps_output output
  | Error err -> Orchestrator_undetermined err

let alloy_ps_command =
  "ps -a --filter name=^/bondi-alloy$ --format '{{.State}}\t{{.Image}}'"

(* The listing is filtered to the one name, so any line at all is that
   container — including one that does not parse, and one in "created",
   "restarting", "paused", "exited", "removing" or "dead". The columns are read
   by nothing here: what the plan needs to know is whether the name is taken.
   The state column is kept in the command because it is what an operator reads
   out of the SSH log when a run is being diagnosed. *)
let alloy_state_of_ps_output output =
  match
    output
    |> String.split_on_char '\n'
    |> List.find_opt (fun line -> String.trim line <> "")
  with
  | None -> Alloy_absent
  | Some _ -> Alloy_present

let alloy_state_of_probe = function
  | Ok output -> alloy_state_of_ps_output output
  | Error err -> Alloy_undetermined err

(* Managed containers are discovered by label rather than by name: the declared
   set is not known to the server, and [-a] is what lets a self-restarting
   container be observed rather than read as absent. *)
let managed_ps_command =
  let label_key, label_value = Managed_container.type_label in
  Printf.sprintf
    "ps -a --filter label=%s=%s --format '{{.Label \"bondi.name\"}}\t{{.Label \
     \"bondi.spec-hash\"}}'"
    label_key label_value

let managed_of_ps_output output =
  output
  |> String.split_on_char '\n'
  |> List.filter_map (fun line ->
      match String.split_on_char '\t' (String.trim line) with
      | [ name; spec_hash ] ->
          let name = String.trim name in
          (* The name is read from a label Bondi did not necessarily write, and
             it becomes the config directory that withdrawal deletes
             recursively. One that [create] would have rejected cannot have
             come from a Bondi-declared container, so it is not observed at
             all. *)
          if not (Managed_container.is_valid_name name) then None
          else Some (name, Managed_present { spec_hash = String.trim spec_hash })
      | []
      | [ _ ]
      | _ :: _ :: _ :: _ ->
          None)

let docker_status_of_probe = function
  | Ok version_output ->
      if
        Bondi_common.String_utils.contains ~needle:"command not found"
          version_output
      then Docker_not_installed (String.trim version_output)
      else Docker_installed (String.trim version_output)
  (* The shell reports a missing command by exiting non-zero, which is the same
     channel a dropped connection arrives on. An error carrying the shell's own
     words is the host answering, and it is the only error that may lead to an
     install. *)
  | Error err
    when Bondi_common.String_utils.contains ~needle:"command not found" err ->
      Docker_not_installed (String.trim err)
  | Error err -> Docker_undetermined err

(* Installing Docker is the one action here that changes a host nobody asked to
   change: it restarts the daemon, and with it every container carrying a
   restart policy. Only the host's own report that the command does not exist
   is a reason to do that; a probe that could not be run at all is a reason to
   stop and say so. *)
let docker_install_verdict_of_probe probe =
  match docker_status_of_probe probe with
  | Docker_installed version -> Docker_satisfied version
  | Docker_not_installed _ -> Docker_install
  | Docker_undetermined message ->
      Docker_abort
        (Printf.sprintf
           "could not read the Docker version, so Docker will not be \
            installed: %s"
           message)

(* What reading the host's curl established. The crontab command uses
   --fail-with-body and an older curl rejects it as unknown, so the version is
   read once at setup time rather than discovered by a job at 3am — but that
   reading is a version string, and a command that never ran has no version
   string in it. Folding the transport's own error into curl's output tells the
   operator that the host reported "command failed (255): Connection closed by …"
   but 7.76.0 is required, which is a failure to ask dressed as a fact about
   curl. Absence is different: the host's own report that the command does not
   exist arrives on the same channel and is an answer, so the two are told apart
   by what the host said rather than by which channel said it. *)
type cron_curl_verdict =
  | Cron_curl_reported of string
  | Cron_curl_undetermined of string

let cron_curl_verdict_of_probe = function
  | Ok output -> Cron_curl_reported output
  | Error err
    when Bondi_common.String_utils.contains ~needle:"command not found" err ->
      Cron_curl_reported err
  | Error err -> Cron_curl_undetermined err

(* What reading the ACME file established. [test -f] reports an absent file by
   exiting non-zero, which is the channel a dropped connection arrives on too,
   so the host's answer and the failure to get one were the same value. The
   probe below always exits 0 and says which on standard output, leaving the
   exit status to mean "the command could be run on that host" — the same
   separation every other probe in this file draws. *)
let acme_file_present_marker = "BONDI_ACME_PRESENT"
let acme_file_absent_marker = "BONDI_ACME_ABSENT"

let acme_probe_command ~path =
  Printf.sprintf "if [ -f %s ]; then echo %s; else echo %s; fi"
    (Filename.quote path) acme_file_present_marker acme_file_absent_marker

type acme_file_state =
  | Acme_file_present
  | Acme_file_absent
  | Acme_file_undetermined of string

let acme_file_state_of_probe = function
  | Error message -> Acme_file_undetermined message
  | Ok output ->
      let said marker =
        Bondi_common.String_utils.contains ~needle:marker output
      in
      if said acme_file_present_marker then Acme_file_present
      else if said acme_file_absent_marker then Acme_file_absent
      else
        Acme_file_undetermined
          (Printf.sprintf "the host answered without saying which: %s"
             (String.trim output))

let gather_context ~user ~host ~key_path : (setup_context, string) result =
  let docker_status =
    docker_status_of_probe (get_docker_version ~user ~host ~key_path)
  in
  let orchestrator =
    match docker_status with
    | Docker_not_installed _ -> Orchestrator_absent
    | Docker_undetermined message -> Orchestrator_undetermined message
    | Docker_installed _ ->
        orchestrator_state_of_probe
          (run_remote_docker ~user ~host ~key_path orchestrator_ps_command)
  in
  let alloy_state =
    match docker_status with
    | Docker_not_installed _ -> Alloy_absent
    | Docker_undetermined message -> Alloy_undetermined message
    | Docker_installed _ ->
        alloy_state_of_probe
          (run_remote_docker ~user ~host ~key_path alloy_ps_command)
  in
  let managed =
    match docker_status with
    (* No Docker means no containers, which is an observation rather than a
       failure to observe: a first setup must still plan the declared ones. *)
    | Docker_not_installed _ -> Managed_observed []
    (* An unread Docker is a failure to observe. No listing was run, so an
       empty one is a claim about the host that nothing supports. *)
    | Docker_undetermined message -> Managed_unobserved message
    | Docker_installed _ -> (
        match run_remote_docker ~user ~host ~key_path managed_ps_command with
        | Ok output -> Managed_observed (managed_of_ps_output output)
        | Error err -> Managed_unobserved err)
  in
  Ok { docker_status; orchestrator; alloy_state; managed }

(* ------------------------------------------------------------------------- *)
(* Phase 2: Plan (pure)                                                      *)
(* ------------------------------------------------------------------------- *)

let has_user_services (config : Config_file.t) =
  Option.is_some config.user_service

let has_cron_jobs (config : Config_file.t) : bool =
  match config.cron_jobs with
  | Some (_ :: _) -> true
  | Some []
  | None ->
      false

(* Converge on "the declared version is serving". Every state that is not that
   ends in [RunServer], and every state that leaves a container behind removes
   it first: [docker run] refuses a name that is already taken, and without the
   removal an orchestrator that died on startup would make the next [bondi
   setup] — the command an operator reaches for to recover — fail too. *)
let orchestrator_actions (config : Config_file.t) (ctx : setup_context) :
    action list =
  match ctx.orchestrator with
  | Orchestrator_absent -> [ RunServer ]
  (* Nothing is planned against a listing that never ran; [plan_for_config] is
     where that becomes an error rather than a silent no-op. *)
  | Orchestrator_undetermined _ -> []
  | Orchestrator_not_running -> [ RemoveOrchestrator; RunServer ]
  | Orchestrator_running { version } ->
      if version = config.bondi_server.version && not (has_cron_jobs config)
      then []
      else [ StopOrchestrator; RemoveOrchestrator; RunServer ]

let managed_state_of observed name =
  match List.assoc_opt name observed with
  | None -> Managed_absent
  | Some state -> state

(* A declared container converges to running at its declared spec. Drift is any
   difference in the spec digest, which covers every declared field, so an
   edited port or rotated credential recreates the container just as a new tag
   does. *)
let managed_convergence_for observed spec =
  let name = Managed_container.name spec in
  let start = [ WriteManagedEnv spec; RunManaged spec ] in
  match managed_state_of observed name with
  | Managed_absent -> start
  | Managed_present { spec_hash } ->
      if spec_hash = Managed_container.spec_hash spec then []
      else [ StopManaged name; RemoveManaged name ] @ start

(* A container withdrawn from configuration converges to stopped, removed, and
   its config directory — which holds its secrets — deleted. *)
let managed_removals ~(specs : Managed_container.t list) observed =
  let declared = List.map Managed_container.name specs in
  observed
  |> List.filter (fun (name, _state) -> not (List.mem name declared))
  |> List.concat_map (fun (name, _state) ->
      [ StopManaged name; RemoveManaged name; CleanManagedConfig name ])

let plan (config : Config_file.t) ~(specs : Managed_container.t list)
    (ctx : setup_context) : action list =
  (* ACME only when we have user services (Traefik will be used) *)
  let acme = if has_user_services config then [ EnsureAcmeFile ] else [] in
  (* Server setup - skip entirely if already up-to-date *)
  let server = orchestrator_actions config ctx in
  (* Every state that leaves a container behind removes it first, stopped ones
     included: [docker run] refuses a name that is already taken, so a stopped
     bondi-alloy makes every later setup fail on a name conflict — and because
     alloy precedes the managed containers here, nothing after it converges
     either. The stop stays ahead of the removal because [RemoveAlloy]'s [docker
     rm] refuses a paused or restarting container just as it refuses a running
     one, and both are states a non-running container can be in. *)
  let alloy =
    match (config.alloy, ctx.alloy_state) with
    | Some _, Alloy_present ->
        [ StopAlloy; RemoveAlloy; EnsureAlloyConfig; RunAlloy ]
    | Some _, Alloy_absent -> [ EnsureAlloyConfig; RunAlloy ]
    (* Withdrawn from configuration. A stopped container has to go too, or the
       name stays taken and the wedge outlives the withdrawal. *)
    | None, Alloy_present -> [ StopAlloy; RemoveAlloy ]
    | None, Alloy_absent -> []
    (* Nothing is planned against a listing that never ran, whether alloy is
       declared or not. With it declared [plan_for_config] turns this into an
       error; without it there was nothing to converge anyway, so the run
       carries on to the phases that follow. *)
    | Some _, Alloy_undetermined _
    | None, Alloy_undetermined _ ->
        []
  in
  let managed =
    match ctx.managed with
    (* Nothing is planned against an observation that failed; [plan_for_config]
       is where that becomes an error rather than a silent no-op. *)
    | Managed_unobserved _ -> []
    | Managed_observed observed ->
        List.concat_map (managed_convergence_for observed) specs
        @ managed_removals ~specs observed
  in
  (* A host that runs no cron jobs never sees a bondi crontab line, so it owes
     no curl version. One that does gets checked here, before the orchestrator
     starts: the emitted command uses --fail-with-body, and an older curl
     rejects it as unknown, which would fail every scheduled job at its next
     tick instead of failing this command once. *)
  let cron_curl =
    match config.cron_jobs with
    | Some (_ :: _) -> [ RequireCronCurl ]
    | Some []
    | None ->
        []
  in
  List.concat
    [
      (* Docker first, then the shared network before anything joins it *)
      [ EnsureDocker; EnsureNetwork Bondi_common.Defaults.network_name ];
      cron_curl;
      acme;
      server;
      alloy;
      managed;
    ]

(* [plan] is pure and total over already-validated specs; this is the one place
   the declared containers are read out of the configuration, so an invalid
   declaration surfaces here rather than inside the plan. *)
let plan_for_config (config : Config_file.t) (ctx : setup_context) =
  let* specs = Config_file.managed_containers config in
  let* () =
    match ctx.docker_status with
    (* Installing Docker restarts the daemon, and with it every container
       carrying a restart policy. That is only ever worth doing against a host
       that positively said it has no Docker; a probe that could not be run is
       a reason to stop and report, not to converge. *)
    | Docker_undetermined message ->
        Error
          (Printf.sprintf
             "could not read the Docker version on the server, so setup will \
              not act on whether it is installed: %s"
             message)
    | Docker_installed _
    | Docker_not_installed _ ->
        Ok ()
  in
  let* () =
    match ctx.orchestrator with
    (* A listing that never ran cannot say the host holds no orchestrator, and
       the plan's answer to an absent one is to run a container under a name
       that may already be taken. Each probe reports itself: one shared "a probe
       failed" would leave the operator guessing which reading to go and check
       by hand. *)
    | Orchestrator_undetermined message ->
        Error
          (Printf.sprintf
             "could not list the bondi-orchestrator container on the server, \
              so setup will not act on whether it is running: %s"
             message)
    | Orchestrator_absent
    | Orchestrator_not_running
    | Orchestrator_running _ ->
        Ok ()
  in
  let* () =
    match (ctx.alloy_state, config.alloy) with
    (* An alloy the configuration does not declare converges to nothing whether
       the listing answered or not, so refusing here would block every phase
       after it over a reading nothing was going to be planned from. Declared,
       it is the reading the run depends on. *)
    | Alloy_undetermined message, Some _ ->
        Error
          (Printf.sprintf
             "could not list the bondi-alloy container on the server, so setup \
              will not act on whether it is running: %s"
             message)
    | Alloy_undetermined _, None
    | (Alloy_absent | Alloy_present), _ ->
        Ok ()
  in
  match (ctx.managed, specs) with
  (* Converging a declared container against an observation that never happened
     would plan a run for one that may already exist. With nothing declared
     there is nothing to converge, so the failed lookup is immaterial. *)
  | Managed_unobserved message, _ :: _ ->
      Error
        (Printf.sprintf
           "could not list managed containers on the server, so the declared \
            ones cannot be converged: %s"
           message)
  | Managed_unobserved _, []
  | Managed_observed _, _ ->
      Ok (plan config ~specs ctx)

(* ------------------------------------------------------------------------- *)
(* Alloy River config generation (delegates to Bondi_common.Alloy_river)     *)
(* ------------------------------------------------------------------------- *)

let excluded_containers_from_config (config : Config_file.t) =
  match config.user_service with
  | Some svc when svc.logs = Some false -> [ svc.name ]
  | _ -> []

let alloy_river_config (config : Config_file.t) (alloy : Config_file.alloy) :
    Bondi_common.Alloy_river.config =
  let collect =
    match alloy.collect with
    | Some "services_only" -> Bondi_common.Alloy_river.Services_only
    | Some "all"
    | None ->
        Bondi_common.Alloy_river.All
    | Some _ ->
        (* validate_alloy_collect rejects invalid values during config parsing,
           so this branch is unreachable. Default to All defensively. *)
        Bondi_common.Alloy_river.All
  in
  let labels =
    match alloy.labels with
    | Some l -> l
    | None -> []
  in
  {
    grafana_cloud_endpoint = alloy.grafana_cloud.endpoint;
    grafana_cloud_instance_id = alloy.grafana_cloud.instance_id;
    grafana_cloud_api_key = alloy.grafana_cloud.api_key;
    collect;
    labels;
    excluded_containers = excluded_containers_from_config config;
  }

(* ------------------------------------------------------------------------- *)
(* Phase 3: Interpreter                                                      *)
(* ------------------------------------------------------------------------- *)

let interpret ~user ~host ~key_path ~ip_address (config : Config_file.t)
    (actions : action list) : (unit, string) result =
  (* One action, applied. No arm here knows what follows it: the plan stops at
     the first failure, and saying what that leaves undone is [run]'s job
     below. *)
  let step : action -> (unit, string) result = function
    | EnsureDocker -> (
        (* The version is read again here rather than taken from the gathered
           context: this is a separate SSH round trip, and a host can change
           under a long setup run. What the reading may lead to is decided in
           [docker_install_verdict_of_probe]; this arm only carries it out. *)
        match
          docker_install_verdict_of_probe
            (get_docker_version ~user ~host ~key_path)
        with
        (* Bare: [run] below names the server once, for every arm. *)
        | Docker_abort message -> Error message
        | Docker_satisfied version ->
            print_endline
              (Printf.sprintf "Docker is already installed on server %s: %s"
                 ip_address version);
            Ok ()
        | Docker_install ->
            print_endline
              (Printf.sprintf
                 "Docker not found on server %s\nInstalling Docker..."
                 ip_address);
            let install_cmd =
              "curl -fsSL https://get.docker.com -o get-docker.sh && sudo sh \
               get-docker.sh"
            in
            let* output = remote_run ~user ~host ~key_path install_cmd in
            print_endline
              (Printf.sprintf "Docker installed on server %s: %s" ip_address
                 (String.trim output));
            Ok ())
    | EnsureAcmeFile ->
        let acme_dir = "/etc/traefik/acme" in
        let acme_file = acme_dir ^ "/acme.json" in
        (* What the reading may lead to is decided above; this arm only obtains
           the host's answer and carries it out. *)
        let* () =
          match
            acme_file_state_of_probe
              (remote_run ~user ~host ~key_path
                 (acme_probe_command ~path:acme_file))
          with
          | Acme_file_undetermined message ->
              Error
                (Printf.sprintf
                   "could not read whether %s exists on the server, so setup \
                    will not act on whether it does: %s"
                   acme_file message)
          | Acme_file_present ->
              let cmd =
                Printf.sprintf "sudo chown root:root %s && sudo chmod 600 %s"
                  acme_file acme_file
              in
              let* _ = remote_run ~user ~host ~key_path cmd in
              print_endline
                (Printf.sprintf "ACME file permissions updated on server %s: %s"
                   ip_address acme_file);
              Ok ()
          | Acme_file_absent ->
              let cmd =
                Printf.sprintf
                  "sudo mkdir -p %s && sudo touch %s && sudo chown root:root \
                   %s && sudo chmod 600 %s"
                  acme_dir acme_file acme_file acme_file
              in
              let* output = remote_run ~user ~host ~key_path cmd in
              print_endline
                (Printf.sprintf "ACME file created on server %s: %s" ip_address
                   (String.trim output));
              Ok ()
        in
        Ok ()
    | EnsureNetwork network_name ->
        let cmd =
          Printf.sprintf
            "docker network inspect %s > /dev/null 2>&1 || docker network \
             create %s"
            (Filename.quote network_name)
            (Filename.quote network_name)
        in
        let* _ = remote_run ~user ~host ~key_path cmd in
        print_endline
          (Printf.sprintf "Network %s is present on server %s" network_name
             ip_address);
        Ok ()
    | RequireCronCurl ->
        (* The version comparison is a pure decision in [Curl_version] and what
           counts as curl having answered is one in [cron_curl_verdict_of_probe];
           this arm only obtains the host's reply and carries the verdict out. *)
        let* output =
          match
            cron_curl_verdict_of_probe
              (remote_run ~user ~host ~key_path "curl --version")
          with
          | Cron_curl_reported output -> Ok output
          | Cron_curl_undetermined message ->
              Error
                (Printf.sprintf
                   "could not read the curl version on the server, so setup \
                    will not act on whether it can run the crontab command: %s"
                   message)
        in
        let* () = Curl_version.supports_fail_with_body output in
        print_endline
          (Printf.sprintf "curl on server %s supports the crontab command: %s"
             ip_address
             (String.trim
                (match String.split_on_char '\n' output with
                | [] -> output
                | line :: _ -> line)));
        Ok ()
    | StopOrchestrator ->
        let* _ =
          run_remote_docker ~user ~host ~key_path "stop bondi-orchestrator"
        in
        print_endline
          (Printf.sprintf "Stopped bondi-orchestrator container on server %s"
             ip_address);
        Ok ()
    | RemoveOrchestrator ->
        (* Asserts the outcome rather than the command's exit status: an
           orchestrator started by an older Bondi ran with --rm, so [docker
           stop] has already deleted it and [docker rm] would report "no such
           container" on a host that is in exactly the state wanted. What
           matters is that no container holds the name afterwards. *)
        let cmd =
          "docker rm --force bondi-orchestrator > /dev/null 2>&1; docker ps -a \
           --filter name=^/bondi-orchestrator$ --format '{{.Names}}' | grep -q \
           . && { echo 'bondi-orchestrator could not be removed' >&2; exit 1; \
           } || true"
        in
        let* _ = remote_run ~user ~host ~key_path cmd in
        print_endline
          (Printf.sprintf "Removed bondi-orchestrator container on server %s"
             ip_address);
        Ok ()
    | RunServer ->
        let image = "mlopez1506/bondi-server:" ^ config.bondi_server.version in
        let* run_cmd = orchestrator_run_command config in
        let* _ = remote_run ~user ~host ~key_path run_cmd in
        (* Assert the posture rather than assume the run command took. This is
           the step whose absence let an undeclared loopback binding be reverted
           silently on 2026-08-29: the container came back healthy on 0.0.0.0
           and nothing said the exposure had changed. A readiness probe answers
           "is it up", which is a different question. *)
        let expected = orchestrator_bind_address config in
        let* published =
          remote_run ~user ~host ~key_path orchestrator_port_command
        in
        let* () =
          match published_binding_matches ~expected published with
          | Ok () -> Ok ()
          | Error got ->
              Error
                (Printf.sprintf
                   "orchestrator published on %s but bondi.yaml asks for %s -- \
                    refusing to report success on a posture that was not \
                    applied"
                   got expected)
        in
        (* [docker run -d] reports that the container was created, which is not
           the same fact as the server being up. The verdict is a pure decision
           in [Orchestrator_probe]; this arm obtains the host's answer, and
           fetches the container's own account of the failure only when there is
           one to explain. *)
        let probe =
          remote_run ~user ~host ~key_path
            (Orchestrator_probe.probe_command
               ~port:Bondi_common.Defaults.server_port
               ~attempts:Orchestrator_probe.readiness_attempts)
        in
        let* () =
          Orchestrator_probe.verdict probe
          |> Result.map_error (fun reason ->
              let diagnostics =
                match
                  remote_run ~user ~host ~key_path
                    Orchestrator_probe.diagnostics_command
                with
                | Ok output -> String.trim output
                | Error message -> message
              in
              Orchestrator_probe.failure_message ~ip_address ~image ~reason
                ~diagnostics)
        in
        print_endline
          (Printf.sprintf "bondi-orchestrator is serving on server %s: %s"
             ip_address image);
        Ok ()
    | EnsureAlloyConfig -> (
        match config.alloy with
        | None -> Ok ()
        | Some alloy ->
            let river_config =
              Bondi_common.Alloy_river.generate
                (alloy_river_config config alloy)
            in
            let config_dir = "/etc/bondi/alloy" in
            let config_path = config_dir ^ "/config.alloy" in
            let* _ =
              remote_run ~user ~host ~key_path
                (Printf.sprintf "sudo mkdir -p %s" config_dir)
            in
            let* _ =
              remote_run ~user ~host ~key_path
                (Printf.sprintf
                   "cat > %s << '__BONDI_ALLOY_CFG_EOF__'\n\
                    %s__BONDI_ALLOY_CFG_EOF__"
                   config_path river_config)
            in
            print_endline
              (Printf.sprintf "Alloy config written on server %s: %s" ip_address
                 config_path);
            Ok ())
    | RunAlloy -> (
        match config.alloy with
        | None -> Ok ()
        | Some alloy ->
            let image =
              Option.value alloy.image
                ~default:Bondi_common.Defaults.alloy_image
            in
            let run_cmd =
              Printf.sprintf
                "docker run -d --name bondi-alloy --restart unless-stopped -v \
                 /var/run/docker.sock:/var/run/docker.sock:ro -v \
                 /etc/bondi/alloy/config.alloy:/etc/bondi/alloy/config.alloy:ro \
                 --label bondi.managed=true --label bondi.type=infrastructure \
                 --label bondi.logs=false -e GRAFANA_CLOUD_INSTANCE_ID=%s -e \
                 GRAFANA_CLOUD_API_KEY=%s %s run /etc/bondi/alloy/config.alloy"
                (Filename.quote alloy.grafana_cloud.instance_id)
                (Filename.quote alloy.grafana_cloud.api_key)
                image
            in
            let* output = remote_run ~user ~host ~key_path run_cmd in
            print_endline
              (Printf.sprintf "bondi-alloy container started on server %s: %s"
                 ip_address (String.trim output));
            Ok ())
    | StopAlloy ->
        let* _ = run_remote_docker ~user ~host ~key_path "stop bondi-alloy" in
        print_endline
          (Printf.sprintf "Stopped bondi-alloy container on server %s"
             ip_address);
        Ok ()
    | RemoveAlloy ->
        let* _ = run_remote_docker ~user ~host ~key_path "rm bondi-alloy" in
        let* _ =
          remote_run ~user ~host ~key_path "sudo rm -rf /etc/bondi/alloy"
        in
        print_endline
          (Printf.sprintf
             "Removed bondi-alloy container and config on server %s" ip_address);
        Ok ()
    | WriteManagedEnv spec ->
        let env_path = Managed_container.env_file_path spec in
        (* umask 077 makes the file mode 600 as it is created, rather than
           creating it readable and narrowing it afterwards, and the contents
           arrive on stdin so they never reach argv. The file is written even
           when the spec declares no secrets, so that a credential withdrawn
           from the configuration is truncated rather than left behind. *)
        let write_cmd =
          Printf.sprintf "sudo sh -c %s"
            (Filename.quote
               (Printf.sprintf "umask 077; mkdir -p %s; cat > %s"
                  (Filename.quote (Managed_container.config_dir spec))
                  (Filename.quote env_path)))
        in
        let input =
          Option.value
            (Managed_container.secret_env_file_contents spec)
            ~default:""
        in
        let* _ = remote_run_with_input ~user ~host ~key_path ~input write_cmd in
        print_endline
          (Printf.sprintf "Wrote secret environment file on server %s: %s"
             ip_address env_path);
        Ok ()
    | RunManaged spec ->
        let args = Managed_container.run_args spec |> List.map Filename.quote in
        let* output =
          run_remote_docker ~user ~host ~key_path (String.concat " " args)
        in
        print_endline
          (Printf.sprintf "%s container started on server %s: %s"
             (Managed_container.container_name spec)
             ip_address (String.trim output));
        Ok ()
    | StopManaged name ->
        let container = Managed_container.container_name_of name in
        let* _ =
          run_remote_docker ~user ~host ~key_path
            ("stop " ^ Filename.quote container)
        in
        print_endline
          (Printf.sprintf "Stopped %s container on server %s" container
             ip_address);
        Ok ()
    | RemoveManaged name ->
        let container = Managed_container.container_name_of name in
        let* _ =
          run_remote_docker ~user ~host ~key_path
            ("rm " ^ Filename.quote container)
        in
        print_endline
          (Printf.sprintf "Removed %s container on server %s" container
             ip_address);
        Ok ()
    | CleanManagedConfig name ->
        let dir = Managed_container.config_dir_of name in
        let* _ =
          remote_run ~user ~host ~key_path ("sudo rm -rf " ^ Filename.quote dir)
        in
        print_endline
          (Printf.sprintf "Removed config directory on server %s: %s" ip_address
             dir);
        Ok ()
  in
  (* [plan]'s concatenation is docker, network, cron curl, ACME, orchestrator,
     alloy, managed — so an action that fails half way down it leaves every
     phase below unapplied, and the host part-way through a setup. Reporting
     only the action that failed is what let a run that stranded the declared
     containers read as a single small failure about alloy. The wording is a
     decision and belongs with the phases; this arm only supplies the facts.
     Naming the server is part of that wording, which is why no [step] arm above
     prefixes its own error: attribution belongs to whatever reports the
     failure, and every failure passes through here. *)
  let rec run = function
    | [] -> Ok ()
    | action :: rest -> (
        match step action with
        | Ok () -> run rest
        | Error reason ->
            Error
              (Setup_phases.failure_message ~server:ip_address
                 ~failed:(phase_of_action action)
                 ~remaining:(List.map phase_of_action rest)
                 ~reason))
  in
  run actions

(* ------------------------------------------------------------------------- *)
(* Entry point                                                               *)
(* ------------------------------------------------------------------------- *)

let setup_server config server =
  let open Config_file in
  let { ip_address; ssh; _ } = server in
  print_endline ("Processing server: " ^ ip_address);
  match ssh with
  | None ->
      prerr_endline ("Missing ssh configuration for server " ^ ip_address);
      Error "missing ssh configuration"
  | Some ssh_config ->
      with_temp_key ssh_config.private_key_contents (fun key_path ->
          let user = ssh_config.user in
          let host = ip_address in
          let* context = gather_context ~user ~host ~key_path in
          (* [plan_for_config] refuses a reading it could not take, and it does
             not know which host it was taken from. Every failure the
             interpreter reports names its server, and [run] below prints them
             all at the end of a multi-server run, far from the "Processing
             server" line that would otherwise have to identify them. *)
          let* actions =
            plan_for_config config context
            |> Result.map_error (fun message ->
                Printf.sprintf "server %s: %s" ip_address message)
          in
          (* Log skip/restart reason when a container is already there *)
          (match context.orchestrator with
          | Orchestrator_absent -> ()
          (* Nothing to report: [plan_for_config] above has already refused a
             listing that never ran, so this line is never reached with one. *)
          | Orchestrator_undetermined _ -> ()
          | Orchestrator_not_running ->
              print_endline
                (Printf.sprintf
                   "bondi-orchestrator on server %s exists but is not running, \
                    replacing it..."
                   ip_address)
          | Orchestrator_running { version = running } ->
              if not (List.mem RunServer actions) then
                print_endline
                  (Printf.sprintf
                     "bondi-orchestrator container is already running on \
                      server %s: %s, skipping..."
                     ip_address running)
              else
                let reason =
                  if running <> config.bondi_server.version then
                    Printf.sprintf "version mismatch: running %s, want %s"
                      running config.bondi_server.version
                  else "adding cron job support"
                in
                print_endline
                  (Printf.sprintf
                     "bondi-orchestrator on server %s: %s, stopping to \
                      restart..."
                     ip_address reason));
          interpret ~user ~host ~key_path ~ip_address config actions)

(* What one server's run produced: whether it converged, and what the host holds
   afterwards. They are separate because a run that stopped part-way is exactly
   when the second is worth reading, so neither may stand in for the other — the
   plan's account of what it executed is the thing that was never a report of
   the box. *)
type server_outcome = {
  converged : (unit, string) result;
  report : Status_report.server_report;
}

(* The report is taken after the run, whatever the run returned. Its reads are
   its own SSH connections and its own HTTP request, so none of them can change
   what [setup_server] decided, and a read that failed becomes a cell rather
   than an early return. *)
let setup_and_report ~fetch config (server : Config_file.server) =
  let converged = setup_server config server in
  let reading = Status_gather.gather ~fetch server in
  (* The wait is scoped by the reading rather than by the configuration: what
     declares a healthcheck is a fact about the containers on the box, and a
     declared component the host does not have is not something to wait for —
     it is already the report's own row. Taking the reading first is what makes
     the wait about the box as this run left it. *)
  let waits =
    Status_gather.health_waits
      ~timeout_seconds:Container_health.wait_timeout_seconds server
      reading.docker
  in
  {
    converged;
    report =
      Status_gather.report_of_reading ~config ~address:server.ip_address ~waits
        reading;
  }

let run () =
  match Config_file.read () with
  | Error message ->
      prerr_endline ("Error reading configuration: " ^ message);
      exit 1
  | Ok config -> (
      let servers = Config_file.servers config in
      if servers = [] then (
        prerr_endline
          "Error: no servers configured. Add servers to bondi.yaml or \
           configure a service with servers.";
        exit 1);
      print_endline "Setting up the servers...";
      let service_name =
        match config.user_service with
        | Some service -> Some service.name
        | None -> None
      in
      let outcomes =
        List.map
          (setup_and_report
             ~fetch:(Status.orchestrator_reading_standalone ~service_name)
             config)
          servers
      in
      let errors =
        List.filter_map
          (fun outcome ->
            match outcome.converged with
            | Error msg -> Some msg
            | Ok () -> None)
          outcomes
      in
      List.iter (fun msg -> prerr_endline ("Error: " ^ msg)) errors;
      (* The failure above says which phases did not run; this says what is on
         the box now. Both are printed, and this one last, because it is the
         reading the operator acts on — and it is printed on the successful path
         for the same reason, since a run that converged is not evidence that
         what it converged is up. *)
      print_newline ();
      print_string
        (Status_report.render_table
           (List.map (fun outcome -> outcome.report) outcomes));
      (* A component that declares a healthcheck and has not passed it is a run
         that may not claim success, and the table above is where it is named:
         a second wording for the same fact on standard error would say it
         twice in two registers, which is the duplication one report exists to
         remove. *)
      let health_failed =
        List.exists
          (fun outcome -> Status_report.exit_failure outcome.report.rows)
          outcomes
      in
      (* Every [exit] stays out here, where no handler is in scope to turn one
         into a value. *)
      match (errors, health_failed) with
      | [], false -> ()
      | [], true
      | _ :: _, false
      | _ :: _, true ->
          exit 1)

let cmd =
  let term = Cmdliner.Term.(const run $ const ()) in
  let info = Cmdliner.Cmd.info "setup" ~doc:"Set up Bondi for a project." in
  Cmdliner.Cmd.v info term
