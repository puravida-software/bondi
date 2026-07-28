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

let ssh_command ~user ~host ~key_path cmd =
  let destination = user ^ "@" ^ host in
  Printf.sprintf
    "ssh -i %s -o BatchMode=yes -o StrictHostKeyChecking=accept-new %s -- %s"
    (Filename.quote key_path)
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

type alloy_state = Alloy_not_running | Alloy_running of { image : string }

(* The orchestrator container is observed as three distinct facts rather than as
   a [string option] of the running version. A container that exists but is not
   running is neither "nothing there" nor "the right version is up": read as the
   first, the plan starts a container whose name is already taken; read as the
   second, setup skips the restart and leaves the host with nothing serving.
   Both were reachable while presence and version were separate fields. *)
type orchestrator_state =
  | Orchestrator_absent
  | Orchestrator_not_running
  | Orchestrator_running of { version : string }

(* Observed state of one managed container. Derived from the container's
   existence and its spec-hash label only, never from whether it is currently
   running: a container performing a scheduled self-restart still exists and
   still carries a matching hash, so it converges to no action (FR-5). *)
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

type setup_context = {
  docker_status : [ `Installed of string | `NotInstalled of string ];
  acme_file_exists : bool;
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

(* ------------------------------------------------------------------------- *)
(* Phase 1: Gather context (read-only)                                       *)
(* ------------------------------------------------------------------------- *)

(* [-a] rather than plain [ps]: since the orchestrator stopped running with
   --rm, a container that died on startup is still on the host, and a plain [ps]
   cannot see it. *)
let orchestrator_ps_command =
  "ps -a --filter name=^/bondi-orchestrator$ --format '{{.State}}\t{{.Image}}'"

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

(* Managed containers are discovered by label rather than by name: the declared
   set is not known to the server, and [-a] is what lets a self-restarting
   container be observed rather than read as absent (FR-5). *)
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

let gather_context ~user ~host ~key_path : (setup_context, string) result =
  let docker_status =
    match get_docker_version ~user ~host ~key_path with
    | Ok version_output ->
        if
          Bondi_common.String_utils.contains ~needle:"command not found"
            version_output
        then `NotInstalled (String.trim version_output)
        else `Installed (String.trim version_output)
    | Error err -> `NotInstalled err
  in
  let acme_file = "/etc/traefik/acme/acme.json" in
  let acme_file_exists =
    match remote_run ~user ~host ~key_path ("test -f " ^ acme_file) with
    | Ok _ -> true
    | Error _ -> false
  in
  let orchestrator =
    match docker_status with
    | `NotInstalled _ -> Orchestrator_absent
    | `Installed _ -> (
        match
          run_remote_docker ~user ~host ~key_path orchestrator_ps_command
        with
        | Ok output -> orchestrator_state_of_ps_output output
        | Error _ -> Orchestrator_absent)
  in
  let alloy_state =
    match docker_status with
    | `NotInstalled _ -> Alloy_not_running
    | `Installed _ -> (
        match
          run_remote_docker ~user ~host ~key_path
            "ps --filter name=^/bondi-alloy$ --format '{{.Image}}'"
        with
        | Ok output -> (
            let image =
              output
              |> String.split_on_char '\n'
              |> List.find_opt (fun line -> String.trim line <> "")
              |> Option.map String.trim
            in
            match image with
            | Some img when img <> "" -> Alloy_running { image = img }
            | _ -> Alloy_not_running)
        | Error _ -> Alloy_not_running)
  in
  let managed =
    match docker_status with
    (* No Docker means no containers, which is an observation rather than a
       failure to observe: a first setup must still plan the declared ones. *)
    | `NotInstalled _ -> Managed_observed []
    | `Installed _ -> (
        match run_remote_docker ~user ~host ~key_path managed_ps_command with
        | Ok output -> Managed_observed (managed_of_ps_output output)
        | Error err -> Managed_unobserved err)
  in
  Ok { docker_status; acme_file_exists; orchestrator; alloy_state; managed }

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
  | Orchestrator_not_running -> [ RemoveOrchestrator; RunServer ]
  | Orchestrator_running { version } ->
      if version = config.bondi_server.version && not (has_cron_jobs config)
      then []
      else [ StopOrchestrator; RemoveOrchestrator; RunServer ]

let alloy_desired_image (alloy : Config_file.alloy) =
  Option.value alloy.image ~default:Bondi_common.Defaults.alloy_image

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
  let alloy =
    match (config.alloy, ctx.alloy_state) with
    (* Alloy removed from config but still running *)
    | None, Alloy_running _ -> [ StopAlloy; RemoveAlloy ]
    | Some _, Alloy_running _ ->
        [ StopAlloy; RemoveAlloy; EnsureAlloyConfig; RunAlloy ]
    (* Alloy configured but not running *)
    | Some _, Alloy_not_running -> [ EnsureAlloyConfig; RunAlloy ]
    | None, Alloy_not_running -> []
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
  let rec run = function
    | [] -> Ok ()
    | EnsureDocker :: rest -> (
        match
          match get_docker_version ~user ~host ~key_path with
          | Ok version_output ->
              if
                Bondi_common.String_utils.contains ~needle:"command not found"
                  version_output
              then Error "docker not installed"
              else (
                print_endline
                  (Printf.sprintf "Docker is already installed on server %s: %s"
                     ip_address
                     (String.trim version_output));
                Ok ())
          | Error err ->
              print_endline
                (Printf.sprintf
                   "Docker not found on server %s\n\
                    Error: %s\n\
                    Installing Docker..."
                   ip_address err);
              let install_cmd =
                "curl -fsSL https://get.docker.com -o get-docker.sh && sudo sh \
                 get-docker.sh"
              in
              let* output = remote_run ~user ~host ~key_path install_cmd in
              print_endline
                (Printf.sprintf "Docker installed on server %s: %s" ip_address
                   (String.trim output));
              Ok ()
        with
        | Error err -> Error err
        | Ok () -> run rest)
    | EnsureAcmeFile :: rest ->
        let acme_dir = "/etc/traefik/acme" in
        let acme_file = acme_dir ^ "/acme.json" in
        let* () =
          match remote_run ~user ~host ~key_path ("test -f " ^ acme_file) with
          | Ok _ ->
              let cmd =
                Printf.sprintf "sudo chown root:root %s && sudo chmod 600 %s"
                  acme_file acme_file
              in
              let* _ = remote_run ~user ~host ~key_path cmd in
              print_endline
                (Printf.sprintf "ACME file permissions updated on server %s: %s"
                   ip_address acme_file);
              Ok ()
          | Error _ ->
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
        run rest
    | EnsureNetwork network_name :: rest ->
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
        run rest
    | RequireCronCurl :: rest ->
        (* The version comparison is a pure decision in [Curl_version]; this arm
           only obtains the host's answer and reports the verdict. A curl that
           cannot be run at all is indistinguishable here from one too old, and
           both are rejections, so the SSH error text is passed through as the
           output to be judged. *)
        let output =
          match remote_run ~user ~host ~key_path "curl --version" with
          | Ok output -> output
          | Error err -> err
        in
        let* () =
          Curl_version.supports_fail_with_body output
          |> Result.map_error (fun msg ->
              Printf.sprintf "server %s: %s" ip_address msg)
        in
        print_endline
          (Printf.sprintf "curl on server %s supports the crontab command: %s"
             ip_address
             (String.trim
                (match String.split_on_char '\n' output with
                | [] -> output
                | line :: _ -> line)));
        run rest
    | StopOrchestrator :: rest ->
        let* _ =
          run_remote_docker ~user ~host ~key_path "stop bondi-orchestrator"
        in
        print_endline
          (Printf.sprintf "Stopped bondi-orchestrator container on server %s"
             ip_address);
        run rest
    | RemoveOrchestrator :: rest ->
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
        run rest
    | RunServer :: rest ->
        let volume_mounts, user_flag =
          match config.cron_jobs with
          | Some jobs when jobs <> [] ->
              ( " -v /var/spool/cron/crontabs:/var/spool/cron/crontabs",
                " --user root" )
          | _ -> ("", "")
        in
        let image = "mlopez1506/bondi-server:" ^ config.bondi_server.version in
        (* No --rm: a container that dies on startup erases itself under it,
           leaving no container, no logs and no error for either the operator or
           the readiness check below. *)
        let run_cmd =
          "docker run -d --name bondi-orchestrator -p 3030:3030 -v \
           /var/run/docker.sock:/var/run/docker.sock" ^ volume_mounts
          ^ user_flag
          ^ " --group-add $(stat -c %g /var/run/docker.sock) --label \
             bondi.managed=true --label bondi.type=infrastructure --label \
             bondi.logs=true " ^ image
        in
        let* _ = remote_run ~user ~host ~key_path run_cmd in
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
        run rest
    | EnsureAlloyConfig :: rest -> (
        match config.alloy with
        | None -> run rest
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
            run rest)
    | RunAlloy :: rest -> (
        match config.alloy with
        | None -> run rest
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
            run rest)
    | StopAlloy :: rest ->
        let* _ = run_remote_docker ~user ~host ~key_path "stop bondi-alloy" in
        print_endline
          (Printf.sprintf "Stopped bondi-alloy container on server %s"
             ip_address);
        run rest
    | RemoveAlloy :: rest ->
        let* _ = run_remote_docker ~user ~host ~key_path "rm bondi-alloy" in
        let* _ =
          remote_run ~user ~host ~key_path "sudo rm -rf /etc/bondi/alloy"
        in
        print_endline
          (Printf.sprintf
             "Removed bondi-alloy container and config on server %s" ip_address);
        run rest
    | WriteManagedEnv spec :: rest ->
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
        run rest
    | RunManaged spec :: rest ->
        let args = Managed_container.run_args spec |> List.map Filename.quote in
        let* output =
          run_remote_docker ~user ~host ~key_path (String.concat " " args)
        in
        print_endline
          (Printf.sprintf "%s container started on server %s: %s"
             (Managed_container.container_name spec)
             ip_address (String.trim output));
        run rest
    | StopManaged name :: rest ->
        let container = Managed_container.container_name_of name in
        let* _ =
          run_remote_docker ~user ~host ~key_path
            ("stop " ^ Filename.quote container)
        in
        print_endline
          (Printf.sprintf "Stopped %s container on server %s" container
             ip_address);
        run rest
    | RemoveManaged name :: rest ->
        let container = Managed_container.container_name_of name in
        let* _ =
          run_remote_docker ~user ~host ~key_path
            ("rm " ^ Filename.quote container)
        in
        print_endline
          (Printf.sprintf "Removed %s container on server %s" container
             ip_address);
        run rest
    | CleanManagedConfig name :: rest ->
        let dir = Managed_container.config_dir_of name in
        let* _ =
          remote_run ~user ~host ~key_path ("sudo rm -rf " ^ Filename.quote dir)
        in
        print_endline
          (Printf.sprintf "Removed config directory on server %s: %s" ip_address
             dir);
        run rest
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
          let* actions = plan_for_config config context in
          (* Log skip/restart reason when a container is already there *)
          (match context.orchestrator with
          | Orchestrator_absent -> ()
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

let run () =
  match Config_file.read () with
  | Error message ->
      prerr_endline ("Error reading configuration: " ^ message);
      exit 1
  | Ok config ->
      let servers = Config_file.servers config in
      if servers = [] then (
        prerr_endline
          "Error: no servers configured. Add servers to bondi.yaml or \
           configure a service with servers.";
        exit 1);
      print_endline "Setting up the servers...";
      let results = List.map (setup_server config) servers in
      let errors =
        List.filter_map
          (function
            | Error msg -> Some msg
            | Ok () -> None)
          results
      in
      if errors <> [] then (
        List.iter (fun msg -> prerr_endline ("Error: " ^ msg)) errors;
        exit 1)

let cmd =
  let term = Cmdliner.Term.(const run $ const ()) in
  let info = Cmdliner.Cmd.info "setup" ~doc:"Set up Bondi for a project." in
  Cmdliner.Cmd.v info term
