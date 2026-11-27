let ( let* ) = Result.bind

(* How long any one command this file runs on a box may take before it is given
   up on. One number rather than one per call, for two reasons. The calls are
   all made over a single session opened per server, and a call inside a session
   is held to the session's bound -- so a shorter number on the quick probes
   would be a number with no effect. And the number the session is opened with
   has to cover the slowest thing setup asks a box to do: installing Docker out
   of the distribution's package manager, or running an image the box has yet to
   pull. Fifteen minutes is that, on a box with a slow link; a probe that comes
   back in under a second is not made worse by being allowed more. *)
let host_command_seconds = 900

(* ------------------------------------------------------------------------- *)
(* Types                                                                     *)
(* ------------------------------------------------------------------------- *)

module Builtin_container = Bondi_common.Builtin_container
module Managed_container = Bondi_common.Managed_container

(* The listing that produces this state is a remote command that can fail to run
   at all, so "no container" and "no answer" are separate constructors. Reading
   the second as the first plans a [docker run] against a name the host may
   already be holding, and discards the transport error on the way.

   Running and stopped are separate facts because only a running container can
   be left alone: one whose recorded configuration digest matches what this
   setup would create is kept if its image has not moved either. A stopped one
   is replaced whatever it carries, since it holds the name and ships nothing. *)
type alloy_state =
  | Alloy_absent
  | Alloy_not_running
  | Alloy_running of { spec_hash : string option }
  | Alloy_undetermined of string

(* The orchestrator container is observed as three distinct facts rather than as
   a [string option] of the running version. A container that exists but is not
   running is neither "nothing there" nor "the right version is up": read as the
   first, the plan starts a container whose name is already taken; read as the
   second, setup skips the restart and leaves the host with nothing ready.
   Both were reachable while presence and version were separate fields. A
   fourth fact is that the listing never ran, which supports none of the three
   and is kept apart from them for the same reason.

   A running container carries the configuration digest it was created with,
   [None] for one created before setup recorded any. [None] never matches, so
   such a container is replaced once and carries a digest from then on. *)
type orchestrator_state =
  | Orchestrator_absent
  | Orchestrator_not_running
  | Orchestrator_running of {
      version : string option;
      spec_hash : string option;
    }
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
   shell's exit 127 and [Remote_exec.command_output_text] turns any non-zero
   exit into an [Error].
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
  crontab : Crontab_listing.t;
}

(* The actions that start a container carry the change they make, as
   [reports]. Why a container is started is something only the plan knows -- it
   is the plan that compared the listing against the configuration -- so it is
   decided there and carried here, and the interpreter adds it to the run's
   account once the action has succeeded, deciding nothing. A removal always
   reports the removal; when the run that follows it succeeds, the replacement
   it was the first half of says so instead (see {!reported_change}). *)
type action =
  | EnsureDocker
  | EnsureAcmeFile
  | EnsureNetwork of string
  | RequireCronDocker
  | RequireCronCurl
  | PreserveCronPayloads of { crontab : Crontab_listing.t }
  | PullOrchestrator
  | CheckOrchestratorImage of image_check
  | StopOrchestrator
  | RemoveOrchestrator
  | RunServer of { reports : Setup_changes.change }
  | AwaitOrchestratorReady
  | EnsureJournalStorage
  | EnsureAlloyState
  | RequireAlloyCurl
  | RequireAlloyPort
  | PullAlloy
  | CheckAlloyImage of image_check
  | CorrectAlloyConfigMode
  | EnsureAlloyConfig
  | WriteAlloyEnv
  | RunAlloy of { reports : Setup_changes.change }
  | AwaitAlloyHealthy
  | StopAlloy
  | RemoveAlloy
  | CleanAlloyConfig
  | WriteManagedEnv of Managed_container.t
  | RunManaged of { spec : Managed_container.t; reports : Setup_changes.change }
  | StopManaged of string
  | RemoveManaged of string
  | CleanManagedConfig of string

(* A container whose recorded configuration matches is kept only if its image
   has not moved behind the tag either, and that is known only once the pull has
   run. So the plan names both outcomes and the check picks one: [kept] runs
   when the container runs the image its reference names now, [replacement]
   when the reference names another. The replacement is the very list the plan
   builds for a container whose configuration differs, so a moved image and a
   changed configuration cannot be replaced two different ways. *)
and image_check = { kept : action list; replacement : action list }

(* Which phase of the plan an action belongs to. The phase type and the report
   built from it live in [Setup_phases], which knows nothing about actions; this
   mapping is what [setup] passes in, and it stays here because the compiler can
   only insist that a new action is given a phase where the action type is in
   scope. *)
let phase_of_action : action -> Setup_phases.phase = function
  | EnsureDocker -> Setup_phases.Docker
  | EnsureNetwork _ -> Setup_phases.Network
  | RequireCronDocker -> Setup_phases.Cron_docker
  | RequireCronCurl -> Setup_phases.Cron_curl
  | EnsureAcmeFile -> Setup_phases.Acme
  | PreserveCronPayloads _
  | PullOrchestrator
  | CheckOrchestratorImage _
  | StopOrchestrator
  | RemoveOrchestrator
  | RunServer _
  | AwaitOrchestratorReady ->
      Setup_phases.Orchestrator
  | EnsureJournalStorage
  | EnsureAlloyState
  | RequireAlloyCurl
  | RequireAlloyPort
  | PullAlloy
  | CheckAlloyImage _
  | CorrectAlloyConfigMode
  | EnsureAlloyConfig
  | WriteAlloyEnv
  | RunAlloy _
  | AwaitAlloyHealthy
  | StopAlloy
  | RemoveAlloy
  | CleanAlloyConfig ->
      Setup_phases.Alloy
  | WriteManagedEnv _
  | RunManaged _
  | StopManaged _
  | RemoveManaged _
  | CleanManagedConfig _ ->
      Setup_phases.Managed

(* What an action changed once it has succeeded, which is the change the plan
   gave it for a start and the removal itself for a removal: the container is
   gone from the box from that moment, whether or not what was meant to follow
   it ever runs. A stop is reported the same way: when the removal after it
   fails, the container is left stopped, and that is a change. A removal
   followed by a successful start of the same container is a replacement, and
   [Setup_changes.settled] folds the stop, the removal and the start into the
   start's item, so a run reads "removed" only when nothing came back and
   "stopped" only when nothing followed the stop. Every other
   action reports nothing of its own: a check changes nothing, and the arms
   whose change depends on what the host answers -- the Docker install --
   report it themselves. *)
let reported_change : action -> Setup_changes.change option = function
  | RunServer { reports }
  | RunAlloy { reports }
  | RunManaged { reports; _ } ->
      Some reports
  | RemoveOrchestrator -> Some Setup_changes.Orchestrator_removed
  | RemoveAlloy -> Some Setup_changes.Alloy_removed
  | RemoveManaged name -> Some (Setup_changes.Managed_removed name)
  | StopOrchestrator -> Some Setup_changes.Orchestrator_stopped
  | StopAlloy -> Some Setup_changes.Alloy_stopped
  | StopManaged name -> Some (Setup_changes.Managed_stopped name)
  | EnsureDocker
  | EnsureAcmeFile
  | EnsureNetwork _
  | RequireCronDocker
  | RequireCronCurl
  | PreserveCronPayloads _
  | PullOrchestrator
  | CheckOrchestratorImage _
  | AwaitOrchestratorReady
  | EnsureJournalStorage
  | EnsureAlloyState
  | RequireAlloyCurl
  | RequireAlloyPort
  | PullAlloy
  | CheckAlloyImage _
  | CorrectAlloyConfigMode
  | EnsureAlloyConfig
  | WriteAlloyEnv
  | AwaitAlloyHealthy
  | CleanAlloyConfig
  | WriteManagedEnv _
  | CleanManagedConfig _ ->
      None

(* The changes one applied action made, in the order it made them: the
   corrections it made (those its arm made and those its follow-up made, such as
   an image check's kept list) first, then what the arm reported from the host's
   answer, then the change the plan gave the action. The closing line lists
   changes in this order, so it is the order the run made them in. *)
let changes_of_action ~corrections ~reported_by_arm action =
  List.filter_map Setup_changes.of_correction corrections
  @ reported_by_arm
  @ Option.to_list (reported_change action)

(* The whole sentence an operator is left with when an action fails: the host's
   own words, then the phase the run stopped in and the phases it never
   reached. It is a named value rather than a step inside the interpreter's
   fold because the composition is the thing that has to hold -- the
   orchestrator's report quotes the container's account, and the phase report
   wraps it; either one dropping the other is a change no test of either alone
   would see. *)
let action_failure_report ~server ~failed ~remaining ~reason =
  Setup_phases.failure_message ~server ~failed:(phase_of_action failed)
    ~remaining:(List.map phase_of_action remaining)
    ~reason

(* ------------------------------------------------------------------------- *)
(* Phase 1: Gather context (read-only)                                       *)
(* ------------------------------------------------------------------------- *)

(* ------------------------------------------------------------------------- *)
(* Orchestrator run command (pure, testable)                                  *)
(* ------------------------------------------------------------------------- *)

(* The orchestrator publishes no port. It serves nothing over the network: every
   Bondi command reaches it by running its subcommands inside its container over
   SSH, and cron reaches it the same way, through `docker exec` from the host's
   crontab. A published port would be a socket nobody listens on, and the
   address it was published on used to be this container's whole security
   boundary -- the socket it mounts is equivalent to root on the box.

   `bondi_server.bind_address` and `bondi_server.api_token` are still parsed, so
   that a box declaring either can still be read, and neither reaches this
   command. Declaring one is reported to the operator where the configuration is
   acted on; see Deprecations. *)
(* One rendering, read twice. [restart] and [spec_label] are the two flags the
   spec hash does not cover: the label cannot carry a digest of itself, and the
   restart policy is converged on the running container by [docker update]
   rather than by recreating it. The hash is taken over this same rendering with
   both left out, so a field added to the command is a field the hash covers,
   with no second template to forget it in. *)
(* The image the run command names, composed from the one spelling of the
   repository; [Builtin_image.orchestrator] has already refused a version that
   does not make a reference before any plan exists. *)
let orchestrator_image (config : Config_file.t) =
  Builtin_image.orchestrator_repository ^ ":" ^ config.bondi_server.version

let render_orchestrator_run ~restart ~spec_label ~cron_payload_needed
    (config : Config_file.t) : string =
  let volume_mounts, user_flag =
    (* The payload directory is mounted from the host because a job's
       definition has to outlive the container. A version bump stops, removes
       and re-runs the orchestrator by design, and in the writable layer that
       deletes every job's run.json while its exec line stays in the crontab —
       every job on the box then fails at its next fire. Both sides name the
       same path so the mount and Cron_secrets agree on where a job's files are.

       Whether this host needs the directory is [cron_payload_needed]'s answer,
       and it is the same answer that plans the copy out of the old container.
       Read from the configuration here and from the host's crontab there, the
       two disagreed on exactly the box the copy exists for: the files landed on
       a host the replacement container could not see, and the listing — which
       reads the host — reported every job as holding its own. *)
    if cron_payload_needed then
      ( " -v /var/spool/cron/crontabs:/var/spool/cron/crontabs -v \
         /etc/bondi/cron:/etc/bondi/cron",
        " --user root" )
    else ("", "")
  in
  let image = orchestrator_image config in
  (* No --rm: a container that dies on startup erases itself under it, leaving
     no container, no logs and no error for either the operator or the readiness
     check. *)
  Printf.sprintf
    "docker run -d --name %s%s -v \
     /var/run/docker.sock:/var/run/docker.sock%s%s --group-add $(stat -c %%g \
     /var/run/docker.sock) --label bondi.managed=true --label \
     bondi.type=infrastructure --label bondi.logs=true%s %s"
    Builtin_container.orchestrator restart volume_mounts user_flag spec_label
    image

let restart_flag = " --restart " ^ Bondi_common.Defaults.bondi_restart_policy

(* What a running orchestrator's label is compared against: the digest of the
   command this setup would create it with. *)
let orchestrator_spec_hash ~cron_payload_needed config =
  Builtin_spec.hash
    ~run_command:
      (render_orchestrator_run ~restart:"" ~spec_label:"" ~cron_payload_needed
         config)
    ~files:[]

let orchestrator_run_command ~cron_payload_needed config =
  render_orchestrator_run ~restart:restart_flag
    ~spec_label:
      (Builtin_spec.label_flag
         (orchestrator_spec_hash ~cron_payload_needed config))
    ~cron_payload_needed config

(* What the host reports the orchestrator's applied restart policy as. Docker's
   default is `no`, so a container created before this flag existed, one whose
   flag the daemon dropped, and one a human cleared by hand all read the same
   from here -- and on 2026-09-02 all three containers Bondi starts on its own
   initiative were found at `no` on a live box with a pending kernel reboot.
   Creation is therefore not the only moment the policy can be checked. *)
let orchestrator_restart_command =
  Printf.sprintf "docker inspect %s -f '{{.HostConfig.RestartPolicy.Name}}'"
    Builtin_container.orchestrator

(* docker update writes HostConfig.RestartPolicy.Name on the running container:
   same pid, same StartedAt, no signal -- measured 2026-09-02 against Docker
   29.x. That is what makes correcting the policy cheap enough to do on every
   run rather than only when the container happens to need recreating for some
   other reason; recreating it would drop TLS for every site on the box to
   change a flag. *)
let orchestrator_restart_update_command ~policy =
  Printf.sprintf "docker update --restart=%s %s" policy
    Builtin_container.orchestrator

let declared_restart_matches ~expected output =
  let got = String.trim output in
  (* A container carrying no policy prints `no`, not an empty name -- observed
     2026-09-02. So empty output never means "no policy": it means nothing was
     read at all, which a removed container, an unreadable answer and an ssh
     stub with no arm for this command all produce. Naming it as an absence
     keeps the failure message from reporting a policy the host never stated,
     and keeps silence from reading as agreement. *)
  let got = if got = "" then "(none reported)" else got in
  if got = expected then Ok () else Error got

(* Whether to correct the policy is a decision, so it lives here rather than in
   the ssh arm that acts on it, and it is expressed in terms of the same matcher
   that asserts the re-read -- one rule, applied before and after the write.
   Both constructors carry everything the caller needs, so the caller matches
   rather than deciding again. *)
type restart_convergence =
  | Restart_policy_already_applied
  | Restart_policy_needs_update of {
      observed : Host_answer.t;
      command : string;
    }
  | Restart_policy_unreadable

let orchestrator_restart_convergence ~expected observed =
  (* Read from the raw output rather than from the matcher's rendering of it:
     the distinction between "nothing was read" and "the host reported a policy
     that differs" is what decides whether a container exists to correct, and it
     must not depend on a display string. A removed container, an unreadable
     answer and an ssh stub with no arm all print empty. *)
  if String.trim observed = "" then Restart_policy_unreadable
  else
    match declared_restart_matches ~expected observed with
    | Ok () -> Restart_policy_already_applied
    | Error got ->
        Restart_policy_needs_update
          {
            observed = Host_answer.of_host_output got;
            command = orchestrator_restart_update_command ~policy:expected;
          }

(* What the restart-policy site has to say about a reading, decided here rather
   than in the arm that acts on it -- the same split the verdict above already
   is, and the reason the arm can be a sequence of round trips with nothing to
   choose. A list rather than an option because it is what the account
   accumulates, and because a site that grew a second thing to say would extend
   this and not its caller.

   Only a difference is a correction. Agreement is a box that needed nothing, and
   a policy that could not be read is a container the host never reported: that
   arm fails the run, and a correction claimed on it would report a write that
   never happened. *)
let restart_policy_corrections ~expected = function
  | Restart_policy_already_applied
  | Restart_policy_unreadable ->
      []
  | Restart_policy_needs_update { observed; command = _ } ->
      [
        Setup_phases.restart_policy_corrected ~found:observed ~applied:expected;
      ]

(* One reading the orchestrator phase takes off the box after it has started
   the container, and the order the phase takes them in.

   A list rather than two calls written one after the other in the arm that
   runs them: the order is the property -- a reading taken before the container
   is running answers for a container that has not started, and a second
   reading is not free, because the check writes to the container's log stream
   and, where cron is configured, touches the spool the host's cron daemon
   watches. The log stream is read last for the same kind of reason: the line
   it looks for is one the check writes, so a read taken ahead of the check
   answers for a stream the check had not written to yet. Held as a value, that
   order is something a test can read; spelled inline, it is something only a
   host can disagree with. *)
type orchestrator_reading = Wait_running | Take_check | Read_log_stream

let orchestrator_readings = [ Wait_running; Take_check; Read_log_stream ]

(* Whether cron is converged on this host is the caller's to say, and it is
   answered from the parsed configuration and the crontab reading setup has
   already taken, rather than from anything the container reports about itself:
   a container cannot soundly infer either, and the host's crontab is the thing
   being converged rather than the thing being asked. It is the same value that
   decides the cron mounts, so the box the reading asks about its spool is
   exactly the box that was given one.

   How much of the log stream is read back is not a number this phase chooses.
   It is the bound the diagnostics read already asks for, spelled once in
   [Orchestrator_probe] and read from there: a second spelling here is a number
   that can drift from the one an operator is shown without anything saying
   so. *)
let orchestrator_reading_command ~cron_configured = function
  | Wait_running ->
      Orchestrator_probe.running_command
        ~container_name:Builtin_container.orchestrator
        ~attempts:Orchestrator_probe.running_attempts
  | Take_check ->
      Orchestrator_probe.check_command
        ~container_name:Builtin_container.orchestrator ~cron_configured
  | Read_log_stream ->
      Orchestrator_probe.log_stream_command
        ~container_name:Builtin_container.orchestrator
        ~lines:Orchestrator_probe.log_lines

(* What one reading's outcome means, decided here so that the arm which runs it
   only carries the decision out.

   The wait has no verdict function of its own: it is written so that its exit
   status is its whole answer -- zero once the container reads as running, and
   non-zero with a sentence on standard error otherwise -- and the transport
   brings that sentence back with the failure. So the reading is the status,
   and what an operator is told is the transport's own account of it, which
   already separates a command the host ran and refused from a host that was
   never reached at all.

   The check's three outcomes collapse to two here, and only here: a box that
   named its faults and a box that answered nothing are the same thing to a
   phase that must stop either way, but they are different sentences, and each
   arrives carrying its own. Collapsing them any earlier would be collapsing
   the sentence too. *)
let orchestrator_reading_verdict reading reading_output =
  match reading with
  | Wait_running -> (
      match reading_output with
      | Ok _ -> Ok ()
      | Error failure ->
          Error
            (Remote_exec.explain
               ~subject:
                 "the wait for the orchestrator container to reach a running \
                  state"
               failure))
  | Take_check -> (
      match Orchestrator_probe.verdict_of_output reading_output with
      | Orchestrator_probe.Ready -> Ok ()
      | Orchestrator_probe.Not_ready reason
      | Orchestrator_probe.Unreachable reason ->
          Error reason)
  | Read_log_stream -> (
      (* A stream that came back without the line and a stream that could not
         be read are kept apart here, because they send an operator to
         different places: the first to a container that is running and can no
         longer be seen -- the sink reported that it took the bytes, so what is
         broken is downstream of it -- and the second to the transport, the key
         or the container name. Both stop the phase all the same: neither is
         evidence that a line the server wrote arrived, and reporting success
         without that evidence is what lets a deployment delete its own
         observability quietly. *)
      match Orchestrator_probe.log_stream_of_output reading_output with
      | Orchestrator_probe.Carrying -> Ok ()
      | Orchestrator_probe.Silent ->
          Error
            "the box answered, and the line it writes to its diagnostic sink \
             was not in the container's recent log output -- the sink took the \
             bytes and the stream an operator and a log shipper read is not \
             carrying them"
      | Orchestrator_probe.Unreadable reason -> Error reason)

(* The mode Bondi declares for the River config file, as one named value so that
   the command that writes it and the expectation the read-back is checked
   against cannot drift apart: a file written at one mode and asserted against
   another fails every run, and two values that drift together fail none.

   0640 rather than 0600: the file holds no credentials -- the generated
   configuration reads them through sys.env references, which is what
   Alloy_river's interface says it emits -- so this is posture rather than
   secrecy, and 0640 is already what two of the three boxes were narrowed to out
   of band. Declaring the same value makes a converging setup leave those boxes
   where they are instead of undoing the fix in the other direction. *)
let alloy_config_declared_mode = "0640"

(* Read through [Defaults] rather than spelled here: the account of what a run
   corrected names this file too, and it is built in a module that cannot see
   this one. Two spellings would let the report name a file the run never
   touched. *)
let alloy_config_dir = Bondi_common.Defaults.alloy_config_dir
let alloy_config_path = Bondi_common.Defaults.alloy_config_path

(* The file the Grafana Cloud credentials live in on the host. It sits inside
   [alloy_config_dir] deliberately: both [RemoveAlloy] and [CleanAlloyConfig]
   delete that directory whole, so an alloy withdrawn from the configuration
   takes its credentials off the host whether or not a container was left to
   observe. Moving this to a sibling path would leave a withdrawn credential
   behind with nothing failing. *)
let alloy_env_path = Bondi_common.Defaults.alloy_env_path

(* Creates the River config file at the declared mode and takes its contents
   from standard input, so they never reach argv.

   The old file is removed rather than truncated. Measured 2026-09-03 on Linux
   7.2.1 with GNU bash 5.3.15 and coreutils 9.11: a file already at 0644,
   written by `sh -c 'umask 027; cat > f'`, is left at 0644. A redirect onto an
   existing file consults no umask because it creates no file -- which is how a
   box narrowed by hand stayed narrow and a box at 0644 stayed wide, with the
   mode decided by whichever shell got there first rather than by Bondi.

   Removing first is also what stops the write from following a symlink planted
   at the path, which the chmod would otherwise apply to the symlink's target.

   umask 077 covers the instant between the file's creation and the chmod: a
   chmod that did not run leaves the file tighter than declared rather than at
   the host's umask. It is set after the mkdir so that the directory keeps the
   0755 it has today -- the Alloy container bind-mounts the file through it.

   The steps are chained with && rather than `;` because `sh -c` exits with the
   status of the last command it ran. Under `;` that is the chmod, which
   succeeds on a file cat created and then failed to fill -- so a connection
   dropped mid-transfer would leave a partial file, report success, and pass the
   mode read-back, because the mode really was applied. *)
let alloy_config_write_command ~mode =
  Printf.sprintf "sudo sh -c %s"
    (Filename.quote
       (Printf.sprintf
          "mkdir -p %s && rm -f %s && umask 077 && cat > %s && chmod %s %s"
          (Filename.quote alloy_config_dir)
          (Filename.quote alloy_config_path)
          (Filename.quote alloy_config_path)
          mode
          (Filename.quote alloy_config_path)))

(* The mode Bondi declares for the credentials file, as one named value for the
   reason [alloy_config_declared_mode] gives: the command that writes it and any
   expectation it is later checked against must be one value, not two spellings
   that agree today. It is written at the width `stat -c %04a` reports, so a
   read-back compares equal strings -- `600` never equals `0600`, and `chmod`
   reads the two identically.

   0600 rather than the config file's 0640: this file holds the Grafana Cloud
   key itself. *)
let alloy_env_declared_mode = "0600"

(* Creates the Grafana Cloud credentials file at the declared mode and takes its
   contents from standard input, so the key reaches no argv, no process listing
   on the host, and no container's arguments.

   The old file is removed rather than truncated for the reason
   [alloy_config_write_command] records -- a redirect onto an existing file
   creates nothing, so it consults no umask, and the mode stays whatever the
   file already had. On a credentials file that is the difference between 0600
   and whatever a previous hand left, and removing first is also what stops the
   write from following a symlink planted at the path, which the chmod would
   otherwise apply to the symlink's target.

   umask 077 covers the instant between the file's creation and the chmod. The
   file is created inside [alloy_config_dir] so that RemoveAlloy's recursive
   delete carries it off when alloy is withdrawn.

   The steps are chained with && for the reason [alloy_config_write_command]
   records, and it bites harder here: a truncated GRAFANA_CLOUD_API_KEY reported
   as a success is an Alloy that starts, reports itself healthy and ships
   nothing, which is what {!Bondi_common.Alloy_river.env_file_contents} names as
   the failure with no symptom at the point it is introduced. *)
let alloy_env_write_command ~mode =
  Printf.sprintf "sudo sh -c %s"
    (Filename.quote
       (Printf.sprintf
          "mkdir -p %s && rm -f %s && umask 077 && cat > %s && chmod %s %s"
          (Filename.quote alloy_config_dir)
          (Filename.quote alloy_env_path)
          (Filename.quote alloy_env_path)
          mode
          (Filename.quote alloy_env_path)))

(* What the host reports the config file's mode as, so setup can check that what
   it asked for is what it got rather than assuming the write took.

   `stat` exits non-zero on a file it cannot read, and that is the same channel a
   dropped connection arrives on, so the two would be one value. The probe says
   which on standard output and always exits zero, leaving the exit status to
   mean "the command could be run on that host" -- the separation
   Acme_file.probe_command already draws.

   %04a rather than %a: `stat -c %a` prints 640 for a file at 0640, and the
   declared mode is written with four digits. Rendering at the width the
   declaration uses is what lets one constant feed both the write and the
   comparison. *)
let alloy_config_mode_unreadable_marker = "BONDI_ALLOY_MODE_UNREADABLE"

let alloy_file_mode_command ~path =
  Printf.sprintf "sudo stat -c %%04a %s 2>/dev/null || echo %s"
    (Filename.quote path) alloy_config_mode_unreadable_marker

let alloy_config_mode_command = alloy_file_mode_command ~path:alloy_config_path

(* What the pre-write reading answers when there is no file there at all. *)
let alloy_config_mode_absent_marker = "BONDI_ALLOY_MODE_ABSENT"

(* What the host reports the config file's mode as *before* setup writes it, so a
   run can say what it found and not only what it asked for. The write recreates
   the file, so by the time the read-back above runs the mode the host had is
   gone and the answer can only ever be the one just requested.

   A reading taken before the write has an answer the read-back has no use for:
   the file is not there yet. That is the ordinary case on a first setup, it is
   not a divergence, and it is not the same fact as a stat the host refused --
   one is a creation and the other is a run that cannot say whether it converged.
   Collapsing the two onto the unreadable marker reports every first setup as a
   failure to read.

   The existence test runs under the same sudo the stat does. Asked as the login
   user it would answer "absent" for a file sitting in a directory that user
   cannot traverse, which is the dangerous direction of the two: it would report
   a creation where the truth is a refusal.

   Always exits zero, on all three answers, for the reason
   [alloy_config_mode_command] gives. *)
let alloy_file_pre_write_mode_command ~path =
  Printf.sprintf "sudo sh -c %s"
    (Filename.quote
       (Printf.sprintf
          "if [ -e %s ]; then stat -c %%04a %s 2>/dev/null || echo %s; else \
           echo %s; fi"
          (Filename.quote path) (Filename.quote path)
          alloy_config_mode_unreadable_marker alloy_config_mode_absent_marker))

let alloy_config_pre_write_mode_command =
  alloy_file_pre_write_mode_command ~path:alloy_config_path

(* The same reading of the credentials file. The two files a kept alloy reads
   are read the same way and by the same command, so the one that holds the key
   is not the one nobody asked about. *)
let alloy_env_pre_write_mode_command =
  alloy_file_pre_write_mode_command ~path:alloy_env_path

(* Why the mode could not be read, as data rather than as a sentence. The two
   cases are genuinely different -- a host that said nothing has no answer to
   quote, a host that answered the marker does -- and the caller that words the
   failure is the one that knows which file and which server it is talking
   about, so it words it once. orchestrator_restart_convergence above draws the
   same line for the same reason. *)
type alloy_mode_unreadable =
  | Alloy_mode_not_reported
  | Alloy_mode_read_refused of { observed : Host_answer.t }
  | Alloy_mode_command_failed of { message : Host_answer.t }
      (** The command never ran to an answer: the runner's own failure, an ssh
          call that did not complete. Not the host's refusal and not silence --
          what the runner said is the only thing there is to quote. *)

(* What a bare `stat` of the file established. Unreadable is not a difference and
   not a match: there is nothing to compare against, so reporting it as a wrong
   mode states something about the host the host never said, and reading it as
   agreement is the silent success the read-back exists to prevent.

   Three answers and not four. A file that is not there is not among them,
   because this is what the command that reads the mode -- either of them -- can
   say, and neither has an arm that reports an absence: the read-back's `stat`
   simply fails, which is the refusal above. The absence is the pre-write
   command's own answer and it lives in the type that command produces, so the
   read-back has no arm for a state its own probe cannot reach. *)
type alloy_mode_reading =
  | Alloy_mode_applied
  | Alloy_mode_differs of { observed : Host_answer.t }
  | Alloy_mode_unreadable of alloy_mode_unreadable

(* What the reading taken before the write established: everything a stat can
   say, and the one thing only this reading can -- that there is no file yet. A
   type of its own rather than a fourth constructor on the reading above, so that
   the read-back matches on three arms and the state it cannot produce is not
   representable in what it sees. An arm for an impossible answer is an arm no
   test can reach and no operator can ever read. *)
type alloy_pre_write_reading =
  | Alloy_pre_write_absent
  | Alloy_pre_write_read of alloy_mode_reading

let alloy_config_mode_of_probe ~expected output =
  (* single_line rather than trim: what a host writes on standard output is free
     text and arrives on however many lines the host chose -- a sudo warning
     ahead of the reading is the ordinary case. Flattening it here rather than
     at each place that renders it is what stops the tail of a two-line answer
     from landing in the middle of a caller's sentence, and it is the same
     reshaping status_report applies to every other message off a host. *)
  let got = Bondi_common.String_utils.single_line output in
  (* Empty output is what an ssh stub with no arm for the command, a command
     whose output never arrived and a host that answered nothing all produce.
     None of them is a mode, and none of them leaves anything to quote. *)
  if got = "" then Alloy_mode_unreadable Alloy_mode_not_reported
  else if
    Bondi_common.String_utils.contains
      ~needle:alloy_config_mode_unreadable_marker got
  then
    Alloy_mode_unreadable
      (Alloy_mode_read_refused { observed = Host_answer.of_host_output got })
  else if got = expected then Alloy_mode_applied
  else Alloy_mode_differs { observed = Host_answer.of_host_output got }

(* The absence is tested here and the rest is the reading above, which is the
   split the two commands already are: only this one has an arm that can print
   the absent marker.

   Neither marker is a substring of the other, so no answer can match both and
   the order they are tried in -- absent here, unreadable in the shared reading
   -- decides nothing. Were one a prefix of the other, the shorter would be found
   inside the longer and that order would silently become the whole rule. *)
let alloy_config_pre_write_mode_of_probe ~expected output =
  if
    Bondi_common.String_utils.contains ~needle:alloy_config_mode_absent_marker
      (Bondi_common.String_utils.single_line output)
  then Alloy_pre_write_absent
  else Alloy_pre_write_read (alloy_config_mode_of_probe ~expected output)

(* The reading a command's outcome amounts to. An ssh call that failed is not a
   host that answered nothing: the runner's own message is what there is to
   quote, so it is carried as itself rather than turned into the empty string
   and read as silence. Taken only to report, so it is still a reading and never
   an [Error] that ends the run. *)
let alloy_pre_write_reading_of_run ~expected = function
  | Ok output -> alloy_config_pre_write_mode_of_probe ~expected output
  | Error message ->
      Alloy_pre_write_read
        (Alloy_mode_unreadable
           (Alloy_mode_command_failed
              { message = Host_answer.of_host_output message }))

(* Why a mode could not be read, worded once for both readings that can fail to
   get one. Two sites asking one host about one file must not describe the same
   refusal differently, and the difference between a host that said nothing and a
   host that answered the marker is the only thing either of them has to add. *)
let alloy_mode_unreadable_detail = function
  | Alloy_mode_not_reported -> "the host reported nothing"
  | Alloy_mode_read_refused { observed } ->
      Printf.sprintf "the host could not read it and answered %s"
        (Host_answer.to_string observed)
  | Alloy_mode_command_failed { message } ->
      Printf.sprintf "the command could not be run: %s"
        (Host_answer.to_string message)

(* What the reading taken before the write means for the run's account, decided
   here rather than in the arm that carries it out -- the split
   [alloy_config_mode_of_probe] above and [restart_policy_corrections] already
   are, and the reason the arm can be a sequence of round trips with nothing to
   choose.

   One list and not a pair. The reading has two kinds of thing to say, but they
   are two entries in one account and not two registers: a mode the host had and
   this run replaced is a correction, a mode the host would not report is not --
   nothing was replaced, and claiming one would report a write against a value
   nobody read -- but it is not silence either, because a run that could not look
   reads exactly like a run that looked and found agreement. Both go through
   [Setup_phases], which words them, names the server and bounds what the host
   said, and both are printed in the block at the end rather than where they were
   taken. A file that is not there is neither: a creation has nothing to diverge
   from, and reporting every first setup as a correction would make the account
   noise on the boxes that need it least.

   Lines, never a verdict. Nothing here fails a run: the mode was read for the
   account's sake, and refusing on a reading taken only to report would block the
   command that repairs the host. *)
let alloy_pre_write_account ~site ~corrected ~expected = function
  | Alloy_pre_write_absent -> []
  | Alloy_pre_write_read Alloy_mode_applied -> []
  | Alloy_pre_write_read (Alloy_mode_differs { observed }) ->
      [ corrected ~found:observed ~applied:expected ]
  | Alloy_pre_write_read (Alloy_mode_unreadable reason) ->
      [
        Setup_phases.unreadable_reading ~site
          ~detail:(alloy_mode_unreadable_detail reason);
      ]

let alloy_config_pre_write_account =
  alloy_pre_write_account ~site:Setup_phases.Alloy_config_mode
    ~corrected:Setup_phases.config_mode_corrected

let alloy_env_pre_write_account =
  alloy_pre_write_account ~site:Setup_phases.Alloy_env_mode
    ~corrected:Setup_phases.env_mode_corrected

(* Brings a file a kept alloy reads to its declared mode, in place. The file is
   not rewritten: its contents are what the running container was created
   against, which is what keeping it means. The directory is created by root at
   0755 and the files are written by root, so a path only root could have
   replaced is chmodded as it stands. *)
let alloy_file_chmod_command ~mode ~path =
  Printf.sprintf "sudo chmod %s %s" mode (Filename.quote path)

(* Alloy created: its files, the run that reads them, and the wait for it to
   answer healthy. [docker run -d] succeeds once the container exists, and an
   Alloy that cannot bind its HTTP port exits after that, so the run alone says
   nothing about whether Alloy came up. The wait sits right after the run, in
   the one list every path that starts Alloy uses, so no such path can start one
   without asking. [reports] is what the run says it did: created, or replaced
   and why. *)
let alloy_start ~reports =
  [ EnsureAlloyConfig; WriteAlloyEnv; RunAlloy { reports }; AwaitAlloyHealthy ]

(* Alloy torn down and created again. [RemoveAlloy] deletes the config
   directory, so the River configuration and the credentials file are written
   after it and before the run that reads them. One list for every route to a
   replacement, for the reason [orchestrator_replacement] gives, differing only
   in the reason the run reports.

   The port check is the first action, ahead of the stop, on every path to a
   replacement: a box whose port something else holds would lose the Alloy it
   had and fail to start the next. A first install, which stops nothing, carries
   it too, ahead of its run. *)
let alloy_replacement reason =
  RequireAlloyPort
  :: StopAlloy
  :: RemoveAlloy
  :: alloy_start ~reports:(Setup_changes.Alloy_recreated reason)

(* What the two readings taken ahead of a kept alloy call for.

   A file that is not there, either of them, is a replacement: both are bind
   mount sources, so a container kept over a missing one runs until the daemon
   next restarts it and fails then, while the run reports success -- which the
   unconditional rewrite never allowed. The replacement writes both files again,
   so it is the whole of [alloy_replacement] and not a write of the one that is
   missing, and it is carried here, with the reason it reports, so that the
   interpreter that reads these files runs what this decided rather than
   choosing a list itself.

   Otherwise a chmod for each file the host reported at another mode, and
   nothing for a file at the declared mode. One the host would not stat is not a
   mode to correct -- the account says it could not look, and a chmod would be
   issued blind. *)
type alloy_kept_files_course =
  | Alloy_files_replace of action list
      (** The replacement to run next, reporting the missing file as its reason.
      *)
  | Alloy_files_chmod of (string * string) list
      (** Each file to correct as its path and the mode to bring it to. *)

let alloy_kept_files_course ~config ~env =
  let chmod_if_differs ~mode ~path = function
    | Alloy_mode_differs _ -> [ (path, mode) ]
    | Alloy_mode_applied
    | Alloy_mode_unreadable _ ->
        []
  in
  match (config, env) with
  | Alloy_pre_write_absent, (Alloy_pre_write_absent | Alloy_pre_write_read _)
  | Alloy_pre_write_read _, Alloy_pre_write_absent ->
      Alloy_files_replace (alloy_replacement Setup_changes.Mounted_file_missing)
  | Alloy_pre_write_read config, Alloy_pre_write_read env ->
      Alloy_files_chmod
        (chmod_if_differs ~mode:alloy_config_declared_mode
           ~path:alloy_config_path config
        @ chmod_if_differs ~mode:alloy_env_declared_mode ~path:alloy_env_path
            env)

(* Withdrawing alloy from the configuration takes its files off the host. It is
   a builder rather than a literal in the interpret arm for the reason the write
   commands are: the directory it deletes has to be the directory they wrote to,
   and a removal naming a directory nothing writes to leaves a withdrawn
   credential on disk with nothing failing. *)
let alloy_remove_config_command =
  Printf.sprintf "sudo rm -rf %s" (Filename.quote alloy_config_dir)

(* The clean-up of an undeclared Alloy's configuration directory, planned on
   every run with Alloy undeclared, whether or not anything is there. [-v] makes
   [rm] print a line for each path it deletes and nothing when there was none,
   so the host's own answer says whether this run changed anything. *)
let alloy_clean_config_command =
  Printf.sprintf "sudo rm -rfv %s" (Filename.quote alloy_config_dir)

(* What the clean-up changed, read from the deletions the host reported. A line
   is a deletion only when it begins with [removed], which is how GNU [rm -v]
   opens each one; silence is nothing there, and any other text is an answer
   this run cannot read, which is not a change. *)
let alloy_config_clean_changes (output : string) : Setup_changes.change list =
  let deletion line =
    Bondi_common.String_utils.starts_with ~prefix:"removed " line
  in
  if List.exists deletion (String.split_on_char '\n' output) then
    [ Setup_changes.Alloy_config_removed ]
  else []

(* The directory Alloy keeps its journal read position in, created before every
   run because the run mounts it with --mount, which refuses a source that does
   not exist. Every run rather than once: a box set up by an earlier release has
   no such directory, and `mkdir -p` leaves one that exists, with what it holds,
   untouched.

   Withdrawing alloy removes the config directory and not this one, which holds
   no credential. *)
let alloy_state_dir_command =
  Printf.sprintf "sudo mkdir -p %s" (Filename.quote Alloy_run_args.state_dir)

(* The `docker run` that starts the sidecar. The Grafana Cloud credentials are
   read out of the file [WriteAlloyEnv] wrote rather than interpolated here.
   Interpolated, they were in this client's ssh command line and in the host's
   process listing for as long as the run took. Those two copies are what the
   file takes away, and they are what the cram argv assertions pin.

   The Engine's own record is deliberately unchanged. The Docker CLI expands
   --env-file on the client, into the container's environment, before the create
   call ever leaves it, so the key sits in the alloy container's `docker
   inspect` byte for byte as it did under -e. [observed -- 2026-09-03: `docker run -d --env-file
   f` left the file's variables in .Config.Env unchanged. The expansion happens
   in the client, so the reading is against docker CLI 29.7.2 and it is the
   client version that decides it.]
   Anything with root on the box reads the file itself anyway. Nothing here
   claims otherwise, and a reader who checks `docker inspect` and finds the key
   should not read that as the change having done nothing -- what closes is the
   process table and the ssh invocation, not the Engine.

   Both variables move, not only the key. The generated River configuration reads
   both through sys.env, so supplying one through the file and one through -e
   would split a single contract across two mechanisms, with nothing failing when
   the two disagree.

   The paths are the module's own constants rather than literals spelled a second
   time: the file this command reads must be the file the write created, and a
   run command pointing at a path nothing wrote starts a sidecar that ships
   nothing while every half of the pair still looks right on its own.

   The journal mount, the state bind, --storage.path, the host network and the
   HTTP listen address come from [Alloy_run_args] and are spelled nowhere here.
   The behavioural test runs the real image with the arguments that module
   prints, so an argument written a second time in this command would let that
   test pass on a run line that does not ship. The Docker options go before the
   image and the Alloy options after `run`, because each program refuses the
   other's. *)
let quoted_join options = String.concat " " (List.map Filename.quote options)

let render_alloy_run ~restart ~spec_label ~image =
  let journal =
    Alloy_run_args.journal ~host_state_dir:Alloy_run_args.state_dir
  in
  let http = Alloy_run_args.http ~listen_port:Alloy_run_args.http_listen_port in
  Printf.sprintf
    "docker run -d --name %s%s -v /var/run/docker.sock:/var/run/docker.sock:ro \
     -v %s:%s:ro %s %s --label bondi.managed=true --label \
     bondi.type=infrastructure --label bondi.logs=false%s --env-file %s %s run \
     %s %s %s"
    Builtin_container.alloy restart alloy_config_path alloy_config_path
    (quoted_join journal.docker_options)
    (quoted_join http.docker_options)
    spec_label alloy_env_path (Filename.quote image)
    (quoted_join journal.alloy_options)
    (quoted_join http.alloy_options)
    alloy_config_path

(* The same rule as the orchestrator's, plus the two files Alloy reads at start.
   Neither is on its command line, so a rewritten River configuration or a
   rotated credential is a change only they show. They are rendered from the
   same River value the write arms render them from. *)
let alloy_spec_hash ~image ~river =
  Builtin_spec.hash
    ~run_command:(render_alloy_run ~restart:"" ~spec_label:"" ~image)
    ~files:
      [
        Bondi_common.Alloy_river.generate river;
        Bondi_common.Alloy_river.env_file_contents river;
      ]

let alloy_run_command ~image ~river =
  render_alloy_run ~restart:restart_flag
    ~spec_label:(Builtin_spec.label_flag (alloy_spec_hash ~image ~river))
    ~image

(* -a in the listing, rather than a plain ps: since the orchestrator stopped
   running with --rm, a container that died on startup is still on the host, and
   a plain ps cannot see it. Every state but running converges to the same
   plan, remove it and then run: none of them is ready, and every one of them
   holds the name. *)
let orchestrator_state_of_probe probe =
  match Container_listing.of_probe probe with
  | Container_listing.Absent -> Orchestrator_absent
  | Container_listing.Not_running -> Orchestrator_not_running
  | Container_listing.Running { image; spec_hash } ->
      Orchestrator_running
        { version = Server_version.version_of_listed_image image; spec_hash }
  | Container_listing.Undetermined err -> Orchestrator_undetermined err

(* Why a running orchestrator whose configuration does not match is replaced,
   as the reason the run's closing line gives. The listing's version is [None]
   when the image column was an image id -- the tag has moved under the
   container -- and that is its own reason rather than a string comparison of a
   hex id against the configured version. The line printed before the stop is
   worded from this value by [orchestrator_restart_reason], so there is one
   comparison and two renderings. *)
let orchestrator_recreate_reason ~wanted ~running ~spec_hash :
    Setup_changes.orchestrator_reason =
  match running with
  | None -> Setup_changes.Reason Setup_changes.Image_moved
  | Some running when not (String.equal running wanted) ->
      Setup_changes.Version
        { running = Host_answer.of_host_output running; wanted }
  | Some _ -> (
      match spec_hash with
      | None -> Setup_changes.Reason Setup_changes.No_digest
      | Some _ -> Setup_changes.Reason Setup_changes.Config_changed)

(* The wording of the line printed ahead of the stop, for the moment before it:
   the same reason the closing line gives afterwards. A replacement for a
   container that was not running, or whose mounted file was missing, is never
   decided by this comparison; those arms say what they are all the same. *)
let orchestrator_restart_reason ~wanted ~running ~spec_hash =
  match orchestrator_recreate_reason ~wanted ~running ~spec_hash with
  | Setup_changes.Reason Setup_changes.Image_moved ->
      "running an image its tag no longer names"
  | Setup_changes.Version { running; wanted } ->
      Printf.sprintf "version mismatch: running %s, want %s"
        (Host_answer.to_string running)
        wanted
  | Setup_changes.Reason Setup_changes.No_digest ->
      "it records no configuration digest"
  | Setup_changes.Reason Setup_changes.Config_changed ->
      "its configuration changed"
  | Setup_changes.Reason Setup_changes.Not_running -> "it is not running"
  | Setup_changes.Reason Setup_changes.Mounted_file_missing ->
      "a file it mounts is missing"

(* What the plan needs to know of alloy is whether the name is taken, and for a
   running container the digest it was created with. *)
let alloy_state_of_probe probe =
  match Container_listing.of_probe probe with
  | Container_listing.Absent -> Alloy_absent
  | Container_listing.Not_running -> Alloy_not_running
  | Container_listing.Running { image = _; spec_hash } ->
      Alloy_running { spec_hash }
  | Container_listing.Undetermined err -> Alloy_undetermined err

(* Managed containers are discovered by label rather than by name: the declared
   set is not known to the server, and [-a] is what lets a self-restarting
   container be observed rather than read as absent. *)
let managed_ps_command =
  let label_key, label_value = Managed_container.type_label in
  Printf.sprintf
    "ps -a --filter label=%s=%s --format '{{.Label \"bondi.name\"}}\t{{.Label \
     \"%s\"}}'"
    label_key label_value Managed_container.spec_hash_label

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

(* The status a shell exits with when the command does not exist: POSIX
   reserves 127 for it, and the shell on this machine was observed exiting 127
   for one on 2026-09-04. ssh propagates the remote command's status, so it
   reaches this client as the host's own answer. The words that come with it do
   not carry that answer -- they are the remote shell's, and nothing here pins
   which shell the host runs -- so they are kept for the operator to read and
   never read for the verdict. *)
let shell_command_not_found_code = 127

(* A successful probe is a version string and nothing else. It used to be read
   for the words a shell prints when the command is missing, because the runner
   of the day appended [2>&1] and a not-found line could arrive on the success
   channel. It cannot now: the runner answers a successful command with its
   standard output alone unless the caller asks otherwise, and the two callers
   that ask are the pass-through printers, not this probe. *)
let docker_status_of_probe = function
  | Ok version_output -> Docker_installed (String.trim version_output)
  (* The shell reports a missing command by exiting non-zero, which is the same
     channel a dropped connection arrives on. What tells them apart is the
     status the host's own shell returned, and that reading is the only one
     that may lead to an install. *)
  | Error failure ->
      if Remote_exec.exited_with ~code:shell_command_not_found_code failure then
        Docker_not_installed (String.trim (Remote_exec.message failure))
      else Docker_undetermined (Remote_exec.message failure)

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

(* What reading the host's curl established. The line this bondi writes carries
   no curl -- it is a docker exec, and docker exec's own exit status is what
   makes a failed run a non-zero line -- but the lines an older bondi wrote are
   curl invocations using --fail-with-body, they keep firing until each job is
   deployed again, and an older curl rejects that option as unknown. So the
   version is read once at setup time rather than discovered by a job at 3am.

   What that reading no longer settles is whether those lines run. A current
   image serves nothing, and no orchestrator this command creates publishes a
   port, so on a host carrying a current orchestrator a surviving legacy line
   fails at the connection whatever curl is installed; the version separates nothing, and only re-deploying each job
   replaces its line. The check is deliberately kept on the whole cron path
   rather than narrowed to hosts observed to hold such a line: setup does not
   read the crontab, and a gate on its way out does not earn a new read. It goes
   when the reader for those lines goes.

   That reading is a version string, and a command that never ran has no version
   string in it. Folding the transport's own error into curl's output tells the
   operator that curl answered "the host was not reached (255): Connection
   closed by …" but 7.76.0 is required, which is a failure to ask dressed as a
   fact about curl. Absence is different: the host's own report that the command does not
   exist arrives on the same channel and is an answer, so the two are told apart
   by the status the host's shell returned rather than by the channel it came
   on or the words it came with. *)
type cron_curl_verdict =
  | Cron_curl_reported of string
  | Cron_curl_undetermined of string

let cron_curl_verdict_of_probe = function
  | Ok output -> Cron_curl_reported output
  | Error failure ->
      if Remote_exec.exited_with ~code:shell_command_not_found_code failure then
        Cron_curl_reported (Remote_exec.message failure)
      else Cron_curl_undetermined (Remote_exec.message failure)

(* Whether the environment cron runs a job in resolves [docker] at all. The
   generated crontab line invokes [docker exec] by bare name, and cron gives a
   job a minimal PATH rather than the login one every other probe in this file
   is answered under -- /usr/bin:/bin on Debian and Ubuntu, which covers the apt
   install get.docker.com performs and does not cover /usr/local/bin, where a
   static or hand-placed binary lands. A host of the second kind answers the
   Docker probe above, accepts the deploy, and then fails every scheduled job at
   its next fire, which is the class of failure setup exists to move forward.
   [env -i] is what makes the two different questions: the shell resolves the
   name with no inherited environment, the way cron's would.

   The probe always exits 0 and says which on standard output, leaving the exit
   status to mean "the command could be run on that host" -- the same separation
   the ACME probe draws, and for the same reason: [command -v] reports a name it
   cannot resolve by exiting non-zero, which is the channel a dropped connection
   arrives on too. *)
let cron_docker_present_marker = "BONDI_CRON_DOCKER_PRESENT"
let cron_docker_absent_marker = "BONDI_CRON_DOCKER_ABSENT"

let cron_docker_probe_command =
  Printf.sprintf
    "env -i sh -c 'if resolved=$(command -v docker); then echo \"%s \
     $resolved\"; else echo %s; fi'"
    cron_docker_present_marker cron_docker_absent_marker

type cron_docker_state =
  | Cron_docker_on_path of string
      (** the path cron's own resolution would run *)
  | Cron_docker_off_path
  | Cron_docker_undetermined of string

let cron_docker_state_of_probe = function
  | Error message -> Cron_docker_undetermined message
  | Ok output -> (
      let present_prefix = cron_docker_present_marker ^ " " in
      match
        Bondi_common.String_utils.index_of ~needle:present_prefix output
      with
      | Some at ->
          let from = at + String.length present_prefix in
          let rest = String.sub output from (String.length output - from) in
          let path =
            match String.index_opt rest '\n' with
            | None -> rest
            | Some newline -> String.sub rest 0 newline
          in
          Cron_docker_on_path (String.trim path)
      | None ->
          if
            Bondi_common.String_utils.contains ~needle:cron_docker_absent_marker
              output
          then Cron_docker_off_path
          else
            Cron_docker_undetermined
              (Printf.sprintf "the host answered without saying which: %s"
                 (String.trim output)))

let gather_context ?session (server : Config_file.server) :
    (setup_context, string) result =
  let docker_status =
    docker_status_of_probe
      (Remote_exec.docker_command_output ?session
         ~timeout_seconds:host_command_seconds ~command:"--version" server)
  in
  let orchestrator =
    match docker_status with
    | Docker_not_installed _ -> Orchestrator_absent
    | Docker_undetermined message -> Orchestrator_undetermined message
    | Docker_installed _ ->
        orchestrator_state_of_probe
          (Remote_exec.docker_command_output_text ?session
             ~timeout_seconds:host_command_seconds
             ~command:
               (Container_listing.command ~name:Builtin_container.orchestrator)
             server)
  in
  let alloy_state =
    match docker_status with
    | Docker_not_installed _ -> Alloy_absent
    | Docker_undetermined message -> Alloy_undetermined message
    | Docker_installed _ ->
        alloy_state_of_probe
          (Remote_exec.docker_command_output_text ?session
             ~timeout_seconds:host_command_seconds
             ~command:(Container_listing.command ~name:Builtin_container.alloy)
             server)
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
        match
          Remote_exec.docker_command_output_text ?session
            ~timeout_seconds:host_command_seconds ~command:managed_ps_command
            server
        with
        | Ok output -> Managed_observed (managed_of_ps_output output)
        | Error err -> Managed_unobserved err)
  in
  (* Read on every run, including on a host whose configuration declares no cron
     job at all. What the plan needs to know is whether the box holds a Bondi
     section, and a box holding one that the configuration no longer declares is
     exactly the box whose files a recreate would take with it. Reading only
     where jobs are declared would skip it.

     Not gated on the Docker reading either: the section is a file on the host,
     and a host with no Docker can still be holding one. *)
  let crontab =
    Crontab_listing.of_read_output
      (Remote_exec.command_output ?session ~timeout_seconds:host_command_seconds
         ~command:Crontab_listing.read_command server)
  in
  Ok { docker_status; orchestrator; alloy_state; managed; crontab }

(* ------------------------------------------------------------------------- *)
(* Alloy River config generation (delegates to Bondi_common.Alloy_river)     *)
(* ------------------------------------------------------------------------- *)

let excluded_containers_from_config (config : Config_file.t) =
  match config.user_service with
  | Some svc when svc.logs = Some false ->
      [ Bondi_common.Router_name.to_string svc.name ]
  | Some _
  | None ->
      []

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
    max_backoff_retries = alloy.grafana_cloud.max_backoff_retries;
  }

(* ------------------------------------------------------------------------- *)
(* Phase 2: Plan (pure)                                                      *)
(* ------------------------------------------------------------------------- *)

(* Traefik is deployed only for a service that declares [traefik:]; a service
   without it runs with no proxy and nothing reads an ACME file. *)
let uses_traefik (config : Config_file.t) =
  Option.is_some config.user_service && Option.is_some config.traefik

let has_cron_jobs (config : Config_file.t) : bool =
  match config.cron_jobs with
  | Some (_ :: _) -> true
  | Some []
  | None ->
      false

(* Whether this host keeps cron payloads at all — the one value the copy out of
   the old container and the mount into the new one are both read from.

   Two authorities could answer it and they do not answer alike. The
   configuration knows what is declared; the host's crontab knows what is
   scheduled, including a line for a job the configuration no longer declares.
   Either alone leaves a real box wrong. Reading only the configuration would
   plan no copy for a section it does not declare — the case this whole phase
   exists for. Reading only the section would give a host its first cron job's
   mount only after the deploy that writes the line, which is after the run file
   it names has already been written into a layer the next recreate deletes. So
   the answer is the disjunction, taken once and consumed twice: a mount without
   a copy loses the files, and a copy without a mount puts them where nothing
   reads them and then reports success.

   A host that positively said it has no Bondi section and declares no job holds
   no line whose file a recreate could orphan. A section that could not be read,
   and one whose markers do not balance, both count: a read that failed is not
   the host answering "there is nothing here", and the copy costs a directory
   that may turn out to be empty. *)
let cron_payload_needed (config : Config_file.t) (ctx : setup_context) : bool =
  match ctx.crontab with
  | Crontab_listing.Section _
  | Crontab_listing.Malformed _
  | Crontab_listing.Unreadable _ ->
      true
  | Crontab_listing.No_section -> has_cron_jobs config

(* A job's files live in the orchestrator's writable layer on any host that does
   not bind-mount them, so removing that container is what deletes them — while
   the crontab line that reads them stays in the spool file and goes on firing.
   The directory is copied out onto the host first.

   The section's own outcome travels, not a list of names taken out of it: what
   may be said about the files on the box differs by outcome, and the payload
   reporting is where that is decided. A line, and every part of one, stays on
   the box all the same. Three of that outcome's four shapes carry nothing but
   names and positions by construction; the fourth carries the transport's own
   account of a read that failed, which its own reader cuts at the marker
   printed ahead of the file's first byte, and which the report this phase
   prints does not say. *)
let cron_payload_preserve (config : Config_file.t) (ctx : setup_context) :
    action list =
  if cron_payload_needed config ctx then
    [ PreserveCronPayloads { crontab = ctx.crontab } ]
  else []

(* The orchestrator torn down and created again: the cron payloads copied out
   first where the host keeps any, then the stop, the removal and the run. One
   list, built here, for both routes to a replacement -- a configuration that
   differs, known when planning, and an image that moved behind its tag, known
   only once the pull has run -- differing only in the reason its run reports. *)
let orchestrator_replacement (config : Config_file.t) (ctx : setup_context)
    ~reason : action list =
  cron_payload_preserve config ctx
  @ [
      StopOrchestrator;
      RemoveOrchestrator;
      RunServer { reports = Setup_changes.Orchestrator_recreated reason };
      AwaitOrchestratorReady;
    ]

(* Whether the running orchestrator was created with the command this setup
   would create it with: mounts, user and image included, since all of them are
   in the command the digest is taken over. *)
let orchestrator_spec_matches (config : Config_file.t) (ctx : setup_context)
    ~spec_hash =
  Builtin_spec.matches
    ~expected:
      (orchestrator_spec_hash
         ~cron_payload_needed:(cron_payload_needed config ctx)
         config)
    spec_hash

(* Converge on "the declared container is running". Every state that is not that
   ends in [RunServer] and the readings that follow it, and every state that
   leaves a container behind removes it first: [docker run] refuses a name that
   is already taken, and without the removal an orchestrator that died on
   startup would make the next [bondi setup] — the command an operator reaches
   for to recover — fail too.

   Every state opens with the pull. Left to [docker run], the fetch happened
   after the old container was stopped and removed, so a registry that was down
   or a version never published left the box with no orchestrator and every
   cron line failing. Pulled first, that failure leaves the old container
   exactly as it was -- ahead of the cron payload copy too, which touches
   nothing but is the phase's first step otherwise.

   A running container whose configuration matches is not torn down on the
   plan's word alone, and not left alone on it either: the pull may have moved
   the tag to another image, which only a reading taken after it can show. So
   it is pulled and then checked, and the check carries the replacement this
   plan would otherwise have issued. A cron host is no exception: recreating it
   on every run killed whatever job was running at that moment. *)
let orchestrator_actions (config : Config_file.t) (ctx : setup_context) :
    action list =
  match ctx.orchestrator with
  (* Nothing to copy out of: there is no container here, so nothing this run
     does can take a job's files with it. *)
  | Orchestrator_absent ->
      [
        PullOrchestrator;
        RunServer
          {
            reports =
              Setup_changes.Orchestrator_created config.bondi_server.version;
          };
        AwaitOrchestratorReady;
      ]
  (* Nothing is planned against a listing that never ran; [plan_for_config] is
     where that becomes an error rather than a silent no-op. *)
  | Orchestrator_undetermined _ -> []
  (* A stopped container still holds its writable layer, and [docker cp] reads
     one whether or not it is running — so this is a recreate like any other,
     and the files go with it unless they are copied out first. *)
  | Orchestrator_not_running ->
      (PullOrchestrator :: cron_payload_preserve config ctx)
      @ [
          RemoveOrchestrator;
          RunServer
            {
              reports =
                Setup_changes.Orchestrator_recreated
                  (Setup_changes.Reason Setup_changes.Not_running);
            };
          AwaitOrchestratorReady;
        ]
  | Orchestrator_running { version; spec_hash } ->
      if orchestrator_spec_matches config ctx ~spec_hash then
        [
          PullOrchestrator;
          CheckOrchestratorImage
            {
              kept = [];
              replacement =
                orchestrator_replacement config ctx
                  ~reason:(Setup_changes.Reason Setup_changes.Image_moved);
            };
        ]
      else
        PullOrchestrator
        :: orchestrator_replacement config ctx
             ~reason:
               (orchestrator_recreate_reason ~wanted:config.bondi_server.version
                  ~running:version ~spec_hash)

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
  let start ~reports = [ WriteManagedEnv spec; RunManaged { spec; reports } ] in
  match managed_state_of observed name with
  | Managed_absent -> start ~reports:(Setup_changes.Managed_created name)
  | Managed_present { spec_hash } ->
      if spec_hash = Managed_container.spec_hash spec then []
      else
        [ StopManaged name; RemoveManaged name ]
        @ start ~reports:(Setup_changes.Managed_recreated name)

(* A container withdrawn from configuration converges to stopped, removed, and
   its config directory — which holds its secrets — deleted. *)
let managed_removals ~(specs : Managed_container.t list) observed =
  let declared = List.map Managed_container.name specs in
  observed
  |> List.filter (fun (name, _state) -> not (List.mem name declared))
  |> List.concat_map (fun (name, _state) ->
      [ StopManaged name; RemoveManaged name; CleanManagedConfig name ])

(* The image alloy runs, read the way the run arm reads it, so that the digest
   the plan compares against is taken over the command that arm issues. *)
let alloy_image (alloy : Config_file.alloy) =
  Bondi_common.Image_reference.to_string
    (Builtin_image.alloy ~declared:alloy.image)

(* Why a running alloy whose digest does not match is replaced: one that records
   none cannot be compared, and is replaced once so that it carries one from
   then on; one that records another was created from a different command,
   River configuration or credentials file. *)
let alloy_recreate_reason ~spec_hash : Setup_changes.recreate_reason =
  match spec_hash with
  | None -> Setup_changes.No_digest
  | Some _ -> Setup_changes.Config_changed

(* Whether the running alloy was created with the command, River configuration
   and credentials this setup would write: all three are in its digest. *)
let alloy_spec_matches (config : Config_file.t) (alloy : Config_file.alloy)
    ~spec_hash =
  Builtin_spec.matches
    ~expected:
      (alloy_spec_hash ~image:(alloy_image alloy)
         ~river:(alloy_river_config config alloy))
    spec_hash

(* What an image check leads to once both ids are read: the line the run
   prints, and which of the two lists the plan gave the check is run next. The
   check itself holds no other decision; it reads, and carries this out.

   A reading that could not be taken runs neither list. Keeping the container
   would claim an image the host never reported, and replacing it would stop a
   container for want of a reading. The failure is bare, like every arm's:
   naming the server is the failure report's job.

   [running] is what the kept line says the container is running: the
   orchestrator's version, as the line has always said, or alloy's image. *)
let after_image_check ~server ~container ~running
    ~(reference : Bondi_common.Image_reference.t) { kept; replacement } verdict
    =
  let image = Bondi_common.Image_reference.to_string reference in
  match verdict with
  | Image_identity.Same ->
      Ok
        ( Printf.sprintf
            "%s container is already running on server %s: %s, skipping..."
            container server running,
          kept )
  | Image_identity.Moved ->
      Ok
        ( Printf.sprintf
            "%s on server %s: %s names a new image, stopping to restart..."
            container server image,
          replacement )
  | Image_identity.Unreadable answer ->
      Error
        (Printf.sprintf
           "could not read whether %s runs the image %s names, so setup left \
            it as it is: %s"
           container image
           (Host_answer.to_string answer))

let plan (config : Config_file.t) ~(specs : Managed_container.t list)
    (ctx : setup_context) : action list =
  (* ACME only when a service declares [traefik:] (Traefik will be used) *)
  let acme = if uses_traefik config then [ EnsureAcmeFile ] else [] in
  let server = orchestrator_actions config ctx in
  (* Every state that leaves a container behind removes it first, stopped ones
     included: [docker run] refuses a name that is already taken, so a stopped
     alloy container makes every later setup fail on a name conflict — and because
     alloy precedes the managed containers here, nothing after it converges
     either. The stop stays ahead of the removal because [RemoveAlloy]'s [docker
     rm] refuses a paused or restarting container just as it refuses a running
     one, and both are states a non-running container can be in.

     The journal comes first in the phase, ahead of the stop: Alloy reads cron
     jobs' lines from it, and a box whose journal cannot be made persistent
     fails the run there. Read first, that failure leaves the box with the Alloy
     it already had rather than with none. The state directory is ahead of the
     stop for the same reason: a [mkdir] that fails after the old Alloy was
     removed leaves the box with none.

     The pull opens the phase on both paths that run a container, for the reason
     the orchestrator's does: a fetch left to [docker run] happens after the old
     container is gone. A withdrawn alloy runs nothing, so it pulls nothing.

     A running alloy whose recorded configuration matches -- its command, its
     River configuration and its credentials file -- is checked after the pull
     rather than replaced, for the reason the orchestrator is. The journal and
     the state directory are still ensured ahead of the check: neither touches
     the running container, and a replacement the check calls for needs both.

     A kept alloy is waited on as well. The listing names a container as
     running for as long as Docker holds it so, and a crash-looping Alloy is
     [running] between its restarts, so a listing that said running proved
     nothing about its answering. The wait follows the mode correction because
     a mode the container cannot read is a cause the correction removes. When
     the correction instead finds a file missing it plans the replacement, which
     waits for itself, and this second wait then answers at once.

     [RequireAlloyCurl] follows the pull in [prepare], so it is on the kept path
     too: the kept path's wait asks with the host's curl, and a refusal is
     cheapest before the journal and state directory, not at the wait. [RequireAlloyPort] is
     not on the kept path: the port is the kept container's own, and the wait is
     what proves it answers. *)
  let alloy =
    let prepare =
      [ PullAlloy; RequireAlloyCurl; EnsureJournalStorage; EnsureAlloyState ]
    in
    match (config.alloy, ctx.alloy_state) with
    | Some alloy, Alloy_running { spec_hash } ->
        if alloy_spec_matches config alloy ~spec_hash then
          prepare
          @ [
              CheckAlloyImage
                {
                  kept = [ CorrectAlloyConfigMode; AwaitAlloyHealthy ];
                  replacement = alloy_replacement Setup_changes.Image_moved;
                };
            ]
        else prepare @ alloy_replacement (alloy_recreate_reason ~spec_hash)
    | Some _, Alloy_not_running ->
        prepare @ alloy_replacement Setup_changes.Not_running
    | Some _, Alloy_absent ->
        prepare
        @ (RequireAlloyPort :: alloy_start ~reports:Setup_changes.Alloy_created)
    (* Withdrawn from configuration. A stopped container has to go too, or the
       name stays taken and the wedge outlives the withdrawal. *)
    | None, (Alloy_not_running | Alloy_running _) -> [ StopAlloy; RemoveAlloy ]
    (* Withdrawn with nothing left to observe. A container removed by any route
       other than bondi -- a hand-run [docker rm], a prune, a rebuilt daemon --
       takes the listing's only evidence with it and leaves the credentials file
       behind, so a removal planned from the listing plans nothing and the key
       outlives the configuration that declared it. What says alloy is withdrawn
       is the configuration; the directory removal is planned from that, which
       is why it is here and not conditional on a container. The branch above
       does not repeat it: [RemoveAlloy] deletes the same directory, and
       planning both would delete it twice. *)
    | None, Alloy_absent -> [ CleanAlloyConfig ]
    (* Nothing is planned against a listing that never ran, whether alloy is
       declared or not. With it declared [plan_for_config] turns this into an
       error. Withdrawn, the directory removal above would be as well founded
       here -- what says alloy is gone is the configuration, which was read --
       but the listing failed on this host's own connection, so a removal issued
       over the same connection fails with it and stops the run before every
       phase below, on a box that never declared alloy at all. The unknown stays
       tolerated and the directory goes on the next run that reads the
       listing. *)
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
     starts -- not for the line this bondi writes, which uses no curl, but for
     the lines an older one wrote: those use --fail-with-body, an older curl
     rejects it as unknown, and they go on firing until each job is deployed
     again. What that check no longer establishes is whether those jobs run. A
     current image serves nothing, and no orchestrator this command creates
     publishes a port, so on a host carrying a current orchestrator a surviving
     legacy line fails at the connection at its next tick whatever curl is
     installed, and only re-deploying each job replaces its line. The gate is kept unnarrowed for the reason its own module gives,
     and it goes when the reader for those lines goes. *)
  let cron_curl =
    match config.cron_jobs with
    | Some (_ :: _) -> [ RequireCronCurl ]
    | Some []
    | None ->
        []
  in
  (* The same host, asked the other half of the question. The emitted line runs
     [docker exec] by bare name and cron resolves it against its own PATH, not
     the login one every probe here is otherwise answered under, so a box whose
     docker sits outside that PATH passes setup and fails every job at its next
     fire. Read before the orchestrator starts, for the reason above: a host
     that cannot run the line never gets one written for it. *)
  let cron_docker =
    match config.cron_jobs with
    | Some (_ :: _) -> [ RequireCronDocker ]
    | Some []
    | None ->
        []
  in
  List.concat
    [
      (* Docker first, then the shared network before anything joins it *)
      [ EnsureDocker; EnsureNetwork Bondi_common.Defaults.network_name ];
      cron_docker;
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
  (* The declared image, held to the floor before anything is started rather
     than after. An image below it has no subcommands to answer with: it
     ignores the arguments and starts serving, so the reading setup takes to
     establish that the container came up never answers at all, and the box is
     reported as one that could not be reached. Refused here, the operator is
     told which version was asked for and which is required, on a host where
     nothing has been stopped, removed or run.

     The floor is the one the client already holds a box to before running a
     subcommand inside its container, not a second number: two floors for one
     capability drift, and the drift is silent in the direction that accepts a
     box which cannot answer. *)
  let* () =
    Server_version.answers_command_surface config.bondi_server.version
  in
  (* A declared alloy reads cron lines from the journal, which only a server
     from [minimum_for_journald_capture] writes there. Held to the floor on the
     pinned version, as above, so nothing is stopped or run first. *)
  let* () =
    match config.alloy with
    | None -> Ok ()
    | Some _ ->
        Server_version.captures_cron_to_journald config.bondi_server.version
  in
  (* The references the pulls fetch, read before there is a plan, so one that
     could never be fetched refuses the run on a box where nothing has been
     stopped. Read here and again in the pull arms rather than carried in the
     plan, the way [RunServer] and [RunAlloy] read their images from the
     configuration: both readings are the same pure function of it. *)
  let* (_ : Bondi_common.Image_reference.t) =
    Builtin_image.orchestrator ~version:config.bondi_server.version
  in
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
             "could not list the %s container on the server, so setup will not \
              act on whether it is running: %s"
             Builtin_container.orchestrator message)
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
             "could not list the %s container on the server, so setup will not \
              act on whether it is running: %s"
             Builtin_container.alloy message)
    | Alloy_undetermined _, None
    | (Alloy_absent | Alloy_not_running | Alloy_running _), _ ->
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
(* Phase 3: Interpreter                                                      *)
(* ------------------------------------------------------------------------- *)

let interpret ?session ~cron_payload_needed (server : Config_file.server)
    (config : Config_file.t) (actions : action list) :
    Setup_phases.correction list
    * Setup_changes.change list
    * (unit, string) result =
  let ip_address = server.Config_file.ip_address in
  (* One action, applied, and whatever divergence applying it corrected, beside
     whatever change it made that only the host's answer decides. No arm
     here knows what follows it: the plan stops at the first failure, and saying
     what that leaves undone is [run]'s job below. Most arms correct nothing and
     say so with the empty list -- a write with no read-back after it has nothing
     to report, which is a different fact from a read-back that agreed. *)
  (* Bounded by the number [RunServer] and [RunAlloy] are: the fetch used to
     happen inside their [docker run], under that same bound, so moving it out
     needs no number of its own. *)
  let pull reference =
    let* _ =
      Remote_exec.docker_command_output_text ?session
        ~timeout_seconds:host_command_seconds
        ~command:(Builtin_image.pull_command reference)
        server
      |> Result.map_error (fun reason ->
          Builtin_image.pull_failure reference ~reason)
    in
    print_endline
      (Printf.sprintf "Pulled %s on server %s"
         (Bondi_common.Image_reference.to_string reference)
         ip_address);
    Ok ([], [])
  in
  (* The config file's mode read back after setup set it, for the write and for
     the in-place change alike: asking for a mode is not applying one. What the
     answer means is [alloy_config_mode_of_probe]'s; this words the two ways it
     can fail, naming how the mode was set. *)
  let confirm_file_mode ~path ~declared ~done_as ~doing_as =
    let* probe_output =
      Remote_exec.command_output_text ?session
        ~timeout_seconds:host_command_seconds
        ~command:(alloy_file_mode_command ~path)
        server
    in
    match alloy_config_mode_of_probe ~expected:declared probe_output with
    | Alloy_mode_applied -> Ok ()
    | Alloy_mode_differs { observed } ->
        Error
          (Printf.sprintf
             "%s on server %s is mode %s after %s %s -- refusing to report \
              success on a posture that was not applied"
             path ip_address
             (Host_answer.to_string observed)
             done_as declared)
    | Alloy_mode_unreadable reason ->
        let detail = alloy_mode_unreadable_detail reason in
        Error
          (Printf.sprintf
             "could not read back the mode of %s on server %s after %s %s, so \
              whether the mode was applied is unknown: %s"
             path ip_address doing_as declared detail)
  in
  let confirm_config_mode =
    confirm_file_mode ~path:alloy_config_path
      ~declared:alloy_config_declared_mode
  in
  (* Both ids read after the pull, and the verdict carried out: the line it
     says, then the list it names, which [run] below applies next. *)
  let check_image ~container ~running ~reference check =
    let verdict =
      Image_identity.verdict
        (Remote_exec.command_output_text ?session
           ~timeout_seconds:host_command_seconds
           ~command:(Image_identity.command ~image:reference ~container)
           server)
    in
    let* line, next =
      after_image_check ~server:ip_address ~container ~running ~reference check
        verdict
    in
    print_endline line;
    Ok next
  in
  (* What each arm returns is the pair a step adds to the run's account: the
     divergences it read back and corrected, and the changes only the host's
     answer decides, which today is the Docker install. A change the plan
     decided is the one the action carries, read by [reported_change] in [run]
     below once the arm has succeeded and never before, so a run stopped by the
     arm lists only what was done ahead of it. *)
  let step :
      action ->
      (Setup_phases.correction list * Setup_changes.change list, string) result
      = function
    | EnsureDocker -> (
        (* The version is read again here rather than taken from the gathered
           context: this is a separate SSH round trip, and a host can change
           under a long setup run. What the reading may lead to is decided in
           [docker_install_verdict_of_probe]; this arm only carries it out. *)
        match
          docker_install_verdict_of_probe
            (Remote_exec.docker_command_output ?session
               ~timeout_seconds:host_command_seconds ~command:"--version" server)
        with
        (* Bare: [run] below names the server once, for every arm. *)
        | Docker_abort message -> Error message
        | Docker_satisfied version ->
            print_endline
              (Printf.sprintf "Docker is already installed on server %s: %s"
                 ip_address version);
            Ok ([], [])
        | Docker_install ->
            print_endline
              (Printf.sprintf
                 "Docker not found on server %s\nInstalling Docker..."
                 ip_address);
            let install_cmd =
              "curl -fsSL https://get.docker.com -o get-docker.sh && sudo sh \
               get-docker.sh"
            in
            let* output =
              Remote_exec.command_output_text ?session
                ~timeout_seconds:host_command_seconds ~command:install_cmd
                server
            in
            print_endline
              (Printf.sprintf "Docker installed on server %s: %s" ip_address
                 (String.trim output));
            Ok ([], [ Setup_changes.Docker_installed ]))
    | EnsureAcmeFile -> (
        let path = Bondi_common.Defaults.acme_file_path in
        let host_command command =
          Remote_exec.command_output_text ?session
            ~timeout_seconds:host_command_seconds ~command server
        in
        let read () =
          Acme_file.state_of_probe ~expected:Acme_file.declared
            (host_command (Acme_file.probe_command ~path))
        in
        (* What the reading leads to is decided in [Acme_file.course]; this arm
           only obtains the host's answer and carries it out. *)
        match Acme_file.course ~path (read ()) with
        | Acme_file.Refuse message -> Error message
        | Acme_file.Keep ->
            print_endline
              (Printf.sprintf "ACME file is already %s on server %s: %s"
                 Acme_file.declared ip_address path);
            Ok ([], [])
        | Acme_file.Correct { command; found } ->
            let* _ = host_command command in
            let* correction =
              Acme_file.confirmation ~path ~server:ip_address ~found (read ())
            in
            Ok ([ correction ], [])
        | Acme_file.Create { command } ->
            let* _ = host_command command in
            (* A command that exited zero is not the file being there at what
               Bondi declares: the change is recorded on the read-back, the
               way a correction is. *)
            let* () = Acme_file.confirmed ~path ~server:ip_address (read ()) in
            print_endline
              (Printf.sprintf "ACME file created on server %s: %s" ip_address
                 path);
            Ok ([], [ Setup_changes.Acme_file_created ]))
    | EnsureNetwork network ->
        let* line, changes =
          Network_probe.account ~server:ip_address ~network
            (Remote_exec.command_output_text ?session
               ~timeout_seconds:host_command_seconds
               ~command:(Network_probe.ensure_command ~network)
               server)
        in
        print_endline line;
        Ok ([], changes)
    | RequireCronDocker ->
        (* What counts as the host having answered is decided in
           [cron_docker_state_of_probe]; this arm only obtains the reply and
           carries the verdict out. *)
        let* path =
          match
            cron_docker_state_of_probe
              (Remote_exec.command_output_text ?session
                 ~timeout_seconds:host_command_seconds
                 ~command:cron_docker_probe_command server)
          with
          | Cron_docker_on_path path -> Ok path
          | Cron_docker_off_path ->
              Error
                (Printf.sprintf
                   "cron cannot find docker on server %s. The crontab line \
                    bondi writes runs `docker exec %s`, and cron gives a job a \
                    minimal PATH rather than the login one this setup run \
                    uses, so a docker outside it answers over ssh and still \
                    fails every scheduled job at its next fire. Install Docker \
                    from the distribution's packages, or place it on the PATH \
                    cron runs jobs with, then run bondi setup again."
                   ip_address Builtin_container.orchestrator)
          | Cron_docker_undetermined message ->
              Error
                (Printf.sprintf
                   "could not read whether cron can find docker on the server, \
                    so setup will not act on whether it can run the crontab \
                    line: %s"
                   message)
        in
        print_endline
          (Printf.sprintf "cron on server %s resolves docker at %s" ip_address
             path);
        Ok ([], [])
    | RequireCronCurl ->
        (* The version comparison is a pure decision in [Curl_version] and what
           counts as curl having answered is one in [cron_curl_verdict_of_probe];
           this arm only obtains the host's reply and carries the verdict out. *)
        let* output =
          match
            cron_curl_verdict_of_probe
              (Remote_exec.command_output ?session
                 ~timeout_seconds:host_command_seconds ~command:"curl --version"
                 server)
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
          (Printf.sprintf
             "curl on server %s can run the crontab lines an older bondi \
              wrote: %s"
             ip_address
             (String.trim
                (match String.split_on_char '\n' output with
                | [] -> output
                | line :: _ -> line)));
        Ok ([], [])
    | PreserveCronPayloads { crontab } ->
        (* The copy runs on the box and the files never come here. What is
           preserved is a run payload and a credential file, and a client that
           read them in and wrote them back would put both through the
           operator's machine for no gain.

           This is planned ahead of the stop, so a host this cannot reach is a
           host nothing has been stopped on yet. *)
        let* _ =
          Remote_exec.command_output_text ?session
            ~timeout_seconds:host_command_seconds
            ~command:Cron_payload.preserve_command server
        in
        print_endline
          (Printf.sprintf
             "Preserved the cron payload directory on server %s ahead of the \
              orchestrator recreate"
             ip_address);
        (* What survived is read back rather than assumed: the copy tolerates a
           container that never held the directory, which is precisely the host
           whose jobs have already lost their files. Which of them did is
           decided in [Cron_payload.divergences] and said in
           [Cron_payload.report], along with the jobs the section no longer
           fires; this arm only obtains the listing and prints what comes back. *)
        let listing =
          Cron_payload.of_listing_output
            (Remote_exec.command_output ?session
               ~timeout_seconds:host_command_seconds
               ~command:Cron_payload.listing_command server)
        in
        List.iter print_endline
          (Cron_payload.report ~server:ip_address ~crontab listing);
        Ok ([], [])
    | PullOrchestrator ->
        let* reference =
          Builtin_image.orchestrator ~version:config.bondi_server.version
        in
        pull reference
    (* An image check corrects nothing. Its reading is taken in [then_run],
       because what it yields is the actions that follow it. *)
    | CheckOrchestratorImage _
    | CheckAlloyImage _ ->
        Ok ([], [])
    | StopOrchestrator ->
        let* _ =
          Remote_exec.docker_command_output_text ?session
            ~timeout_seconds:host_command_seconds
            ~command:(Printf.sprintf "stop %s" Builtin_container.orchestrator)
            server
        in
        print_endline
          (Printf.sprintf "Stopped %s container on server %s"
             Builtin_container.orchestrator ip_address);
        Ok ([], [])
    | RemoveOrchestrator ->
        (* Asserts the outcome rather than the command's exit status: an
           orchestrator started by an older Bondi ran with --rm, so [docker
           stop] has already deleted it and [docker rm] would report "no such
           container" on a host that is in exactly the state wanted. What
           matters is that no container holds the name afterwards. *)
        let cmd =
          Printf.sprintf
            "docker rm --force %s > /dev/null 2>&1; docker ps -a --filter \
             name=^/%s$ --format '{{.Names}}' | grep -q . && { echo '%s could \
             not be removed' >&2; exit 1; } || true"
            Builtin_container.orchestrator Builtin_container.orchestrator
            Builtin_container.orchestrator
        in
        let* _ =
          Remote_exec.command_output_text ?session
            ~timeout_seconds:host_command_seconds ~command:cmd server
        in
        print_endline
          (Printf.sprintf "Removed %s container on server %s"
             Builtin_container.orchestrator ip_address);
        Ok ([], [])
    | RunServer { reports = _ } ->
        let run_cmd = orchestrator_run_command ~cron_payload_needed config in
        let* _ =
          Remote_exec.command_output_text ?session
            ~timeout_seconds:host_command_seconds ~command:run_cmd server
        in
        Ok ([], [])
    | AwaitOrchestratorReady ->
        let image = orchestrator_image config in
        (* [docker run -d] reports that the container was created, which is not
           the same fact as the server being up, and the two are two actions
           for that reason: the container is on the box once the run returns,
           so the run is counted as a change then, and a reading that rejects
           it afterwards fails the run without taking that back. Each reading's
           verdict is a
           pure decision; this arm obtains the host's answers in the order the
           readings declare, stops at the first that rejects, and fetches the
           container's own account of the failure only when there is one to
           explain.

           What the reading is told about cron is the value this run already
           planned from, not a second predicate built here. It is still read
           from the configuration rather than from the box -- the container
           cannot soundly infer it about itself, and the host's crontab is the
           thing this run converges rather than the thing it asks -- but it
           also counts the reading of the crontab setup has already taken and
           already acted on. A box that declares no job and is holding a Bondi
           section got the spool and the payload mounts a moment ago; asked the
           narrower question it would be the one box never probed about the
           lines it is likeliest to be holding. *)
        let* () =
          List.fold_left
            (fun taken reading ->
              let* () = taken in
              orchestrator_reading_verdict reading
                (Remote_exec.command_output ?session
                   ~timeout_seconds:host_command_seconds
                   ~command:
                     (orchestrator_reading_command
                        ~cron_configured:cron_payload_needed reading)
                   server))
            (Ok ()) orchestrator_readings
          |> Result.map_error (fun reason ->
              let diagnostics =
                match
                  Remote_exec.command_output_text ?session
                    ~timeout_seconds:host_command_seconds
                    ~command:Orchestrator_probe.diagnostics_command server
                with
                | Ok output -> String.trim output
                | Error message -> message
              in
              Orchestrator_probe.failure_message ~ip_address ~image ~reason
                ~diagnostics)
        in
        print_endline
          (Printf.sprintf "%s is ready on server %s: %s"
             Builtin_container.orchestrator ip_address image);
        Ok ([], [])
    | EnsureJournalStorage -> (
        (* What a storage reading means, which commands it calls for and what
           the reading taken after them means are decided in
           [Journal_storage]; this arm takes the readings, runs the commands in
           order and carries the verdicts out. Read here rather than with the
           gathered context, for the reason [EnsureAlloyConfig] reads its mode
           here: only a host that declares alloy plans this action, so only
           that host is asked. *)
        let read_storage () =
          Journal_storage.reading_of_probe
            (Remote_exec.command_output_text ?session
               ~timeout_seconds:host_command_seconds
               ~command:Journal_storage.probe_command server)
        in
        let* planned = Journal_storage.plan (read_storage ()) in
        match planned with
        | Journal_storage.Nothing_to_do ->
            print_endline
              (Printf.sprintf
                 "Journal on server %s is stored persistently under %s"
                 ip_address Alloy_run_args.journal_path);
            Ok ([], [])
        | Journal_storage.Provision_then_recheck commands ->
            let* () =
              List.fold_left
                (fun ran command ->
                  let* () = ran in
                  let* _ =
                    Remote_exec.command_output_text ?session
                      ~timeout_seconds:host_command_seconds ~command server
                  in
                  Ok ())
                (Ok ()) commands
            in
            let* () = Journal_storage.recheck (read_storage ()) in
            print_endline
              (Printf.sprintf
                 "Provisioned persistent journal storage on server %s: %s"
                 ip_address Alloy_run_args.journal_path);
            Ok ([ Setup_phases.journal_storage_provisioned ], []))
    | EnsureAlloyConfig -> (
        match config.alloy with
        | None -> Ok ([], [])
        | Some alloy ->
            let river_config =
              Bondi_common.Alloy_river.generate
                (alloy_river_config config alloy)
            in
            (* The mode the host has is read before the write and not after,
               because the write recreates the file: by the time the read-back
               below runs, the only mode there is the one just asked for, so a
               run can say what it applied and never what it found. This is the
               one moment the reading exists at all.

               Read here rather than alongside the rest of the gathered context:
               nothing at that point knows whether alloy is declared, and asking
               every host about a file most of them do not have spends a round
               trip per server for an answer no account uses. Read even so on a
               box that has no such file -- an absent file is an answer, and it
               is a different one from a stat the host refused.

               What the answer means is decided in
               [alloy_config_pre_write_account]; this carries that out, and it
               carries it out before the write so that the notices it may hold
               reach the transcript in the order the run took them. *)
            let pre_write_output =
              (* Not bound with [let*]. This reading changes no exit code and
                 stops no run: a host that answers the unreadable marker produces
                 a line of the account, and an ssh call that failed is a reading
                 that could not be taken, so it takes the same route -- carrying
                 the runner's message, which is not the same fact as a host that
                 said nothing. Ending the run on it would fail a setup over a
                 reading taken only to report. *)
              Remote_exec.command_output_text ?session
                ~timeout_seconds:host_command_seconds
                ~command:alloy_config_pre_write_mode_command server
            in
            let pre_write_corrections =
              alloy_config_pre_write_account
                ~expected:alloy_config_declared_mode
                (alloy_pre_write_reading_of_run
                   ~expected:alloy_config_declared_mode pre_write_output)
            in
            (* The config travels on standard input rather than inside a
               heredoc in the command, which is what lets the write be a single
               root-owned command that also sets the mode.

               Both numbers below were measured rather than reasoned about,
               because the runner drains no output while the write is in flight
               and a payload larger than the pipe buffer deadlocks it. A
               generated config with three labels and an excluded container is
               1041 bytes; an unadjusted pipe on this platform
               holds 65536, read from F_GETPIPE_SZ rather than from the
               /proc ceiling, which reports the maximum a pipe may be raised to
               and not the capacity it has. The config grows only with the
               declared label map -- excluded_containers_from_config yields at
               most one name -- so reaching the buffer would take on the order
               of a thousand declared labels. *)
            let* _ =
              Remote_exec.command_output_text ?session ~input:river_config
                ~timeout_seconds:host_command_seconds
                ~command:
                  (alloy_config_write_command ~mode:alloy_config_declared_mode)
                server
            in
            (* Asking for a mode is not applying one, so the file is read back
               before the run says it wrote it. A write whose chmod was refused,
               or that landed somewhere a later phase does not look at, is
               otherwise a clean setup over a file at the host's umask. *)
            let* () =
              confirm_config_mode ~done_as:"being written at"
                ~doing_as:"writing it at"
            in
            print_endline
              (Printf.sprintf "Alloy config written on server %s: %s" ip_address
                 alloy_config_path);
            (* Yielded here and not where the reading was taken: a correction is a
               write that succeeded, and every path between the reading and this
               line -- the write, and the read-back that proves the mode was
               applied -- returns [Error] instead. A correction reported for a
               mode the host refused to take would be the reassurance this
               account replaces. *)
            Ok (pre_write_corrections, []))
    | WriteAlloyEnv -> (
        match config.alloy with
        | None -> Ok ([], [])
        | Some alloy ->
            let contents =
              Bondi_common.Alloy_river.env_file_contents
                (alloy_river_config config alloy)
            in
            (* The credentials travel on standard input, so they appear in no
               command line here, in no process listing on the host, and in no
               container's arguments once the run command references the file
               instead of interpolating them.

               The payload is two short lines, far inside the 65536-byte pipe
               the runner measures against -- it drains no output while the
               write is in flight, so a payload larger than the buffer would
               deadlock. *)
            let* _ =
              Remote_exec.command_output_text ?session ~input:contents
                ~timeout_seconds:host_command_seconds
                ~command:(alloy_env_write_command ~mode:alloy_env_declared_mode)
                server
            in
            (* The path, not the contents. A message that quoted what it wrote
               would put the key back in the place this arm exists to take it
               out of. *)
            print_endline
              (Printf.sprintf "Wrote Alloy credentials file on server %s: %s"
                 ip_address alloy_env_path);
            Ok ([], []))
    | EnsureAlloyState ->
        let* _ =
          Remote_exec.command_output_text ?session
            ~timeout_seconds:host_command_seconds
            ~command:alloy_state_dir_command server
        in
        Ok ([], [])
    | PullAlloy -> (
        match config.alloy with
        | None -> Ok ([], [])
        | Some alloy -> pull (Builtin_image.alloy ~declared:alloy.image))
    | CorrectAlloyConfigMode -> Ok ([], [])
    | RunAlloy { reports = _ } -> (
        match config.alloy with
        | None -> Ok ([], [])
        | Some alloy ->
            let image = alloy_image alloy in
            let* output =
              Remote_exec.command_output_text ?session
                ~timeout_seconds:host_command_seconds
                ~command:
                  (alloy_run_command ~image
                     ~river:(alloy_river_config config alloy))
                server
            in
            print_endline
              (Printf.sprintf "%s container started on server %s: %s"
                 Builtin_container.alloy ip_address (String.trim output));
            Ok ([], []))
    | RequireAlloyCurl ->
        (* What counts as the host having answered, and what each answer means,
           is [Alloy_preflight]'s; this arm obtains the reply and carries the
           verdict out. It runs ahead of every stop, so the refusal leaves the
           Alloy the box had. *)
        let port = Alloy_run_args.http_listen_port in
        let* output =
          Remote_exec.command_output_text ?session
            ~timeout_seconds:host_command_seconds
            ~command:Alloy_preflight.curl_probe_command server
        in
        let* () =
          Alloy_preflight.require_curl ~port
            (Alloy_preflight.curl_verdict_of_probe
               (Host_answer.of_host_output output))
        in
        print_endline
          (Printf.sprintf "curl on server %s can ask Alloy on port %d"
             ip_address port);
        Ok ([], [])
    | RequireAlloyPort ->
        let port = Alloy_run_args.http_listen_port in
        let* output =
          Remote_exec.command_output_text ?session
            ~timeout_seconds:host_command_seconds
            ~command:(Alloy_preflight.port_probe_command ~port)
            server
        in
        let* () =
          Alloy_preflight.require_port_available
            (Alloy_preflight.port_verdict_of_probe ~port
               (Host_answer.of_host_output output))
        in
        print_endline
          (Printf.sprintf "port %d on server %s is free for Alloy" port
             ip_address);
        Ok ([], [])
    | AwaitAlloyHealthy ->
        (* What the answer means is [Alloy_health]'s decision; this arm only
           obtains it and carries the verdict out. *)
        let port = Alloy_run_args.http_listen_port in
        let* output =
          Remote_exec.command_output_text ?session
            ~timeout_seconds:host_command_seconds
            ~command:
              (Alloy_health.probe_command ~port
                 ~timeout_s:Alloy_health.wait_seconds)
            server
        in
        let* () =
          Alloy_health.require_healthy
            (Alloy_health.verdict_of_probe ~port
               (Host_answer.of_host_output output))
        in
        print_endline
          (Printf.sprintf "%s answered healthy on server %s, port %d"
             Builtin_container.alloy ip_address port);
        Ok ([], [])
    | StopAlloy ->
        let* _ =
          Remote_exec.docker_command_output_text ?session
            ~timeout_seconds:host_command_seconds
            ~command:(Printf.sprintf "stop %s" Builtin_container.alloy)
            server
        in
        print_endline
          (Printf.sprintf "Stopped %s container on server %s"
             Builtin_container.alloy ip_address);
        Ok ([], [])
    | RemoveAlloy ->
        let* _ =
          Remote_exec.docker_command_output_text ?session
            ~timeout_seconds:host_command_seconds
            ~command:(Printf.sprintf "rm %s" Builtin_container.alloy)
            server
        in
        let* _ =
          Remote_exec.command_output_text ?session
            ~timeout_seconds:host_command_seconds
            ~command:alloy_remove_config_command server
        in
        print_endline
          (Printf.sprintf "Removed %s container and config on server %s"
             Builtin_container.alloy ip_address);
        Ok ([], [])
    | CleanAlloyConfig ->
        let* output =
          Remote_exec.command_output_text ?session
            ~timeout_seconds:host_command_seconds
            ~command:alloy_clean_config_command server
        in
        print_endline
          (Printf.sprintf
             "No alloy is configured for server %s: %s is not on the host"
             ip_address alloy_config_dir);
        Ok ([], alloy_config_clean_changes output)
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
        let* _ =
          Remote_exec.command_output_text ?session ~input
            ~timeout_seconds:host_command_seconds ~command:write_cmd server
        in
        print_endline
          (Printf.sprintf "Wrote secret environment file on server %s: %s"
             ip_address env_path);
        Ok ([], [])
    | RunManaged { spec; reports = _ } ->
        let args = Managed_container.run_args spec |> List.map Filename.quote in
        let* output =
          Remote_exec.docker_command_output_text ?session
            ~timeout_seconds:host_command_seconds
            ~command:(String.concat " " args) server
        in
        print_endline
          (Printf.sprintf "%s container started on server %s: %s"
             (Managed_container.container_name spec)
             ip_address (String.trim output));
        Ok ([], [])
    | StopManaged name ->
        let container = Managed_container.container_name_of name in
        let* _ =
          Remote_exec.docker_command_output_text ?session
            ~timeout_seconds:host_command_seconds
            ~command:("stop " ^ Filename.quote container)
            server
        in
        print_endline
          (Printf.sprintf "Stopped %s container on server %s" container
             ip_address);
        Ok ([], [])
    | RemoveManaged name ->
        let container = Managed_container.container_name_of name in
        let* _ =
          Remote_exec.docker_command_output_text ?session
            ~timeout_seconds:host_command_seconds
            ~command:("rm " ^ Filename.quote container)
            server
        in
        print_endline
          (Printf.sprintf "Removed %s container on server %s" container
             ip_address);
        Ok ([], [])
    | CleanManagedConfig name ->
        let dir = Managed_container.config_dir_of name in
        let* _ =
          Remote_exec.command_output_text ?session
            ~timeout_seconds:host_command_seconds
            ~command:("sudo rm -rf " ^ Filename.quote dir)
            server
        in
        print_endline
          (Printf.sprintf "Removed config directory on server %s: %s" ip_address
             dir);
        Ok ([], [])
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
  (* The account and the outcome are returned together rather than as a result
     carrying the account in one arm, because a run that stopped part-way is
     exactly when what it already changed matters most: reachable only through
     [Ok], the corrections and changes made before a failure would be the same
     silence this account exists to remove, arriving by another route. So both
     are returned on both paths, in plan order, and the failing path returns
     everything the actions above it corrected and changed.

     Accumulated reversed and turned over once at the end: an accumulator
     appended to on every action copies itself on every action, and the plan is
     as long as the box's declared containers make it. *)
  (* What a kept alloy's two mounted files call for. It lives with [then_run]
     and not in [step] because its reading changes what follows it, which is
     what [then_run] is for: a file that is not there is the replacement, and
     the corrections account is returned beside it. The files are left as they
     are, contents and all, so the mode each had is read, reported, and
     corrected where it differs -- which the rewrite used to do as a side effect
     of recreating them. A container kept over a missing bind-mount source fails
     at the daemon's next restart, so a missing file is not left alone. The
     readings are the pre-write kind and are read the way that arm reads them:
     taken only to report, so an ssh call that failed is a line of the account
     and not the end of the run. What they call for is decided in
     [alloy_kept_files_course], and what they report in
     [alloy_config_pre_write_account] and [alloy_env_pre_write_account]. *)
  let correct_kept_alloy_files () =
    let read ~expected ~command =
      alloy_pre_write_reading_of_run ~expected
        (Remote_exec.command_output_text ?session
           ~timeout_seconds:host_command_seconds ~command server)
    in
    let config_reading =
      read ~expected:alloy_config_declared_mode
        ~command:alloy_config_pre_write_mode_command
    in
    let env_reading =
      read ~expected:alloy_env_declared_mode
        ~command:alloy_env_pre_write_mode_command
    in
    let corrections =
      alloy_config_pre_write_account ~expected:alloy_config_declared_mode
        config_reading
      @ alloy_env_pre_write_account ~expected:alloy_env_declared_mode
          env_reading
    in
    match alloy_kept_files_course ~config:config_reading ~env:env_reading with
    | Alloy_files_replace replacement ->
        print_endline
          (Printf.sprintf
             "Alloy on server %s is missing a file it mounts, replacing it..."
             ip_address);
        Ok (corrections, replacement)
    | Alloy_files_chmod files ->
        let* () =
          List.fold_left
            (fun applied (path, declared) ->
              let* () = applied in
              let* _ =
                Remote_exec.command_output_text ?session
                  ~timeout_seconds:host_command_seconds
                  ~command:(alloy_file_chmod_command ~mode:declared ~path)
                  server
              in
              confirm_file_mode ~path ~declared ~done_as:"being changed to"
                ~doing_as:"changing it to")
            (Ok ()) files
        in
        Ok (corrections, [])
  in
  (* The actions one action calls for after it, which only an image check does:
     the list its verdict names is applied next, by this same interpreter, ahead
     of the rest of the plan. *)
  let then_run :
      action -> (Setup_phases.correction list * action list, string) result =
    function
    | CheckOrchestratorImage check ->
        let* reference =
          Builtin_image.orchestrator ~version:config.bondi_server.version
        in
        let* next =
          check_image ~container:Builtin_container.orchestrator
            ~running:config.bondi_server.version ~reference check
        in
        Ok ([], next)
    | CheckAlloyImage check -> (
        match config.alloy with
        | None -> Ok ([], [])
        | Some alloy ->
            let reference = Builtin_image.alloy ~declared:alloy.image in
            let* next =
              check_image ~container:Builtin_container.alloy
                ~running:(Bondi_common.Image_reference.to_string reference)
                ~reference check
            in
            Ok ([], next))
    | CorrectAlloyConfigMode -> correct_kept_alloy_files ()
    | EnsureDocker
    | EnsureAcmeFile
    | EnsureNetwork _
    | RequireCronDocker
    | RequireCronCurl
    | PreserveCronPayloads _
    | PullOrchestrator
    | StopOrchestrator
    | RemoveOrchestrator
    | RunServer _
    | AwaitOrchestratorReady
    | EnsureJournalStorage
    | EnsureAlloyState
    | PullAlloy
    | EnsureAlloyConfig
    | WriteAlloyEnv
    | RunAlloy _
    | AwaitAlloyHealthy
    | RequireAlloyCurl
    | RequireAlloyPort
    | StopAlloy
    | RemoveAlloy
    | CleanAlloyConfig
    | WriteManagedEnv _
    | RunManaged _
    | StopManaged _
    | RemoveManaged _
    | CleanManagedConfig _ ->
        Ok ([], [])
  in
  (* A correction is a change too, so each one an action made is counted among
     the changes where that action made it: the changes come out in the order
     the run made them, which is the order the closing line lists them in. *)
  let rec run corrected changed = function
    | [] -> (List.rev corrected, List.rev changed, Ok ())
    | action :: rest -> (
        let applied =
          let* corrections, changes = step action in
          let* followed, next = then_run action in
          let corrections = corrections @ followed in
          Ok
            ( corrections,
              changes_of_action ~corrections ~reported_by_arm:changes action,
              next )
        in
        match applied with
        | Ok (corrections, changes, next) ->
            run
              (List.rev_append corrections corrected)
              (List.rev_append changes changed)
              (next @ rest)
        | Error reason ->
            ( List.rev corrected,
              List.rev changed,
              Error
                (action_failure_report ~server:ip_address ~failed:action
                   ~remaining:rest ~reason) ))
  in
  run [] [] actions

(* Docker's default restart policy is `no`, so creation is not the only moment a
   container's policy can be wrong: a docker-ce upgrade, a daemon crash or a
   `docker update` run by hand all leave a healthy container that will not
   survive the next reboot, and none of them is visible from the run command
   this tool issued. A box converged by `bondi setup` was found at `no` on
   2026-09-02 for exactly that reason. So the applied policy is read from the
   host on every run rather than only where something else happened to force a
   recreation, corrected where it differs, and read again -- `docker update`
   accepting the command is not the same fact as the daemon having applied it,
   which is the assumption the run command's own flag already makes.

   The correction is in place: the policy is a mutable field on a running
   container, so the pid and StartedAt are untouched -- measured 2026-09-02
   against Docker 29.x, not reasoned from the documentation. Recreating the
   orchestrator to change a flag would drop TLS for every site on the box. *)
let converge_orchestrator_restart_policy ?session (server : Config_file.server)
    =
  let ip_address = server.Config_file.ip_address in
  let expected = Bondi_common.Defaults.bondi_restart_policy in
  (* One fallible sequence, turned into the pair once at the end. Nothing here
     can fail after a correction exists -- the correction is what the final
     read-back agreeing means -- so a failing path has an empty account, and the
     pair is built from the sequence rather than threaded through it. *)
  let attempt () =
    let* reported =
      Remote_exec.command_output_text ?session
        ~timeout_seconds:host_command_seconds
        ~command:orchestrator_restart_command server
    in
    match orchestrator_restart_convergence ~expected reported with
    | Restart_policy_already_applied -> Ok []
    (* Nothing was read, so there is nothing to correct: a `docker update` here
       would be issued against a container the host never reported, and the run
       would fail on whatever raw text Docker returned instead of on what setup
       was attempting. *)
    | Restart_policy_unreadable ->
        Error
          (Printf.sprintf
             "%s restart policy on server %s could not be read -- `%s` \
              reported nothing, which is what a removed or unreadable \
              container looks like, so its restart policy was left alone \
              rather than corrected blind"
             Builtin_container.orchestrator ip_address
             orchestrator_restart_command)
    | Restart_policy_needs_update { command; _ } as verdict ->
        let* _ =
          Remote_exec.command_output_text ?session
            ~timeout_seconds:host_command_seconds ~command server
        in
        let* applied =
          Remote_exec.command_output_text ?session
            ~timeout_seconds:host_command_seconds
            ~command:orchestrator_restart_command server
        in
        let* () =
          declared_restart_matches ~expected applied
          |> Result.map_error (fun got ->
              Printf.sprintf
                "%s restart policy on server %s is still %s after asking for \
                 %s -- refusing to report success on a posture that was not \
                 applied"
                Builtin_container.orchestrator ip_address got expected)
        in
        (* What the host reported reaches the account through the verdict, which
           is the one place it is read from: a sentence written here as well would
           be a second wording for the same disagreement, and the reason the two
           sites had different ones. *)
        Ok (restart_policy_corrections ~expected verdict)
  in
  match attempt () with
  | Ok corrections -> (corrections, Ok ())
  | Error message -> ([], Error message)

(* The run that creates the container reads the policy too. The `--restart` on
   the `docker run` this tool issues is a request; what the daemon applied is
   only ever visible from an inspect, which is the same reasoning the
   convergence above already rests on -- three containers created with the flag
   were found at `no` on 2026-09-02. A host that had no Docker is therefore not
   a host whose policy is known, it is the one host nobody has ever asked, and
   the first `bondi setup` a box ever gets used to be the only run that skipped
   the question.

   A Docker state that could not be read is still skipped, and that is not
   symmetry for its own sake: an inspect issued against a host whose version
   probe never answered fails on the transport, and the run would report that
   as a restart policy it could not converge -- a second failure describing the
   first one badly. [plan_for_config] has already refused such a reading before
   this is reached, so the arm is the rule written down rather than a path with
   traffic on it. *)
let converge_restart_policy ?session server ~docker_status =
  match docker_status with
  | Docker_installed _
  | Docker_not_installed _ ->
      converge_orchestrator_restart_policy ?session server
  | Docker_undetermined _ -> ([], Ok ())

(* ------------------------------------------------------------------------- *)
(* Entry point                                                               *)
(* ------------------------------------------------------------------------- *)

let setup_server config server =
  let open Config_file in
  let { ip_address; _ } = server in
  print_endline ("Processing server: " ^ ip_address);
  match Remote_exec.ssh_config server with
  | Error failure ->
      prerr_endline (Remote_exec.message failure);
      ([], [], Error "missing ssh configuration")
  (* The credentials are read again by the session below, which is the module
     that owns the key on disk. What is decided here is only whether there are
     any: a server with no [ssh] block is reported once, by name, rather than
     once per command it was never going to run. Which server that is, and how
     the absence reads, are both the runner's to say -- this is the one place
     that asks it. *)
  | Ok _ -> (
      let converge ?session () =
        (* Nothing is read back before there is a plan, so a run that never got
           one has an empty account rather than no account -- which is what
           the closing line has a sentence for, and why the account is returned
           from here too. *)
        let planned =
          let* context = gather_context ?session server in
          (* [plan_for_config] refuses a reading it could not take, and it does
             not know which host it was taken from. Every failure the interpreter
             reports names its server, and [run] below prints them all at the end
             of a multi-server run, far from the "Processing server" line that
             would otherwise have to identify them. *)
          let* actions =
            plan_for_config config context
            |> Result.map_error (fun message ->
                Printf.sprintf "server %s: %s" ip_address message)
          in
          Ok (context, actions)
        in
        match planned with
        | Error message -> ([], [], Error message)
        | Ok (context, actions) -> (
            (* Log skip/restart reason when a container is already there *)
            (match context.orchestrator with
            | Orchestrator_absent -> ()
            (* Nothing to report: [plan_for_config] above has already refused
               a listing that never ran, so this line is never reached with
               one. *)
            | Orchestrator_undetermined _ -> ()
            | Orchestrator_not_running ->
                print_endline
                  (Printf.sprintf
                     "%s on server %s exists but is not running, replacing \
                      it..."
                     Builtin_container.orchestrator ip_address)
            (* A container whose configuration matches is kept or replaced on
               the image check's reading, and the check says which once it has
               read the ids: what this line would claim is not known yet. *)
            | Orchestrator_running { version = running; spec_hash } ->
                if not (orchestrator_spec_matches config context ~spec_hash)
                then
                  let reason =
                    orchestrator_restart_reason
                      ~wanted:config.bondi_server.version ~running ~spec_hash
                  in
                  print_endline
                    (Printf.sprintf
                       "%s on server %s: %s, stopping to restart..."
                       Builtin_container.orchestrator ip_address reason));
            let interpreted, changed, applied =
              interpret ?session
                ~cron_payload_needed:(cron_payload_needed config context)
                server config actions
            in
            (* The plan's own corrections are kept whichever way it went, and
               the restart-policy convergence is only reached when it went
               through: [interpret] has already left the host part-way and said
               which phases did not run, and issuing an inspect after that would
               report the policy of a box this run had stopped working on. *)
            match applied with
            | Error message -> (interpreted, changed, Error message)
            | Ok () ->
                let converged, outcome =
                  converge_restart_policy ?session server
                    ~docker_status:context.docker_status
                in
                ( interpreted @ converged,
                  changed
                  @ List.filter_map Setup_changes.of_correction converged,
                  outcome ))
      in
      (* One staged key for the whole of a server's run, rather than one with
         every command in it. This is the client's longest sequence of remote
         calls -- the readings, every step the plan interprets, and the
         restart-policy convergence after them -- so a key staged with each of
         them is a window with each of them, and a handshake with each of them.

         A session that could not be staged runs the same body without one,
         which is exactly what this function did before there were sessions:
         every call opens its own. It is not a second attempt, because a
         [with_session] that returns [Error] is one whose body never ran. *)
      match
        Remote_exec.with_session ~timeout_seconds:host_command_seconds server
          (fun session -> converge ~session ())
      with
      | Ok outcome -> outcome
      | Error _ -> converge ())

(* What one server's run produced: whether it converged, what it corrected on the
   way, every change it made, and what the host holds afterwards. Kept apart
   because a run that stopped part-way is exactly when all but the first are
   worth reading, so none of them may stand in for another -- the plan's account
   of what it executed is the thing that was never a report of the box, and a
   divergence the run repaired is neither of those. The changes include the
   corrections, which is why the closing line can be worded over them alone. *)
type server_outcome = {
  converged : (unit, string) result;
  corrections : Setup_phases.correction list;
  changes : Setup_changes.change list;
  report : Status_report.server_report;
}

(* The report is taken after the run, whatever the run returned. Its reads stay
   independent of what [setup_server] decided — none of them can change it, and
   a read that failed becomes a cell rather than an early return — and they
   share one staging of the key, which is a different question: independence is
   about what a read may change, and the session is about how many times key
   material reaches disk. The run's own session is closed by the time this
   begins, because a run that stopped part-way is exactly when the report is
   worth taking, so this opens a second one rather than extending the first. *)
let setup_and_report ~fetch config (server : Config_file.server) =
  let corrections, changes, converged = setup_server config server in
  let taken ?session () =
    let reading =
      Status_gather.gather ?session ~timeout_seconds:host_command_seconds
        ~fetch:(fetch ?session) server
    in
    (* The wait is scoped by the reading rather than by the configuration: what
       declares a healthcheck is a fact about the containers on the box, and a
       declared component the host does not have is not something to wait for —
       it is already the report's own row. Taking the reading first is what
       makes the wait about the box as this run left it. *)
    let waits =
      Status_gather.health_waits ?session
        ~timeout_seconds:Container_health.wait_timeout_seconds server
        reading.docker
    in
    (reading, waits)
  in
  let reading, waits =
    match
      Remote_exec.with_session ~timeout_seconds:host_command_seconds server
        (fun session -> taken ~session ())
    with
    | Ok pair -> pair
    (* A session that could not be staged is a server with no ssh block, no ssh
       on this machine, or nowhere to write a key, and every read would have
       answered with that same failure. The body never ran, so taking the
       report without a session is what derives it -- once per read, exactly as
       it was derived before there was a session to open -- rather than reading
       anything twice. *)
    | Error _ -> taken ()
  in
  {
    converged;
    corrections;
    (* Settled here, once the run is over, because only the whole list can say
       whether a removal was followed by the start that makes it a
       replacement. *)
    changes = Setup_changes.settled changes;
    report =
      Status_gather.report_of_reading ~config ~address:server.ip_address ~waits
        reading;
  }

(** [deprecation_notices config] is what this run says about fields [config]
    declares that Bondi still parses and no longer acts on.

    A value rather than a call inside [run], so that which commands say this is
    a property a test can hold: [run] reads a file from the working directory,
    prints and exits, and nothing about it can be asked what it would have said.
    The sentences themselves are {!Deprecations}'s. *)
let deprecation_notices (config : Config_file.t) =
  Deprecations.messages config.bondi_server

let run () =
  match Config_file.read () with
  | Error message ->
      prerr_endline ("Error reading configuration: " ^ message);
      exit 1
  | Ok config -> (
      (* Said before the servers are looked at, because it is the file that is
         being reported on and not the estate: a bondi.yaml that declares a dead
         field and no server has two things wrong with it and an operator is
         owed both. On stderr, as [deploy] writes the same sentences: stdout
         carries what setup did, and a notice about the file is not that. *)
      List.iter prerr_endline (deprecation_notices config);
      let servers = Config_file.servers config in
      if servers = [] then (
        prerr_endline
          "Error: no servers configured. Add servers to bondi.yaml or \
           configure a service with servers.";
        exit 1);
      print_endline "Setting up the servers...";
      let service_name =
        match config.user_service with
        | Some service -> Some (Bondi_common.Router_name.to_string service.name)
        | None -> None
      in
      let outcomes =
        List.map
          (setup_and_report
             ~fetch:(fun ?session server ->
               Status.orchestrator_reading ?session ~service_name server)
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
      (* The run's second register, collected here rather than printed where each
         correction happened: a line written mid-transcript is scattered through
         the output of every other phase, and it is lost from view altogether on
         the run that stopped after it -- which is the run whose repairs matter
         most. The closing line follows each server's corrections and names every
         change the run made there, or says it made none. Printed for every
         server, including one whose run never started, because an account
         nobody took and an account with nothing in it are different facts and
         the closing line is what tells them apart.

         Nothing here reads [errors] or [health_failed] and nothing here decides
         an exit code: a correction is a write that succeeded, and refusing on one
         would block the command that repairs the host. *)
      List.iter
        (fun outcome ->
          List.iter print_endline
            (Setup_phases.corrections_report ~server:outcome.report.address
               outcome.corrections);
          print_endline
            (Setup_changes.closing_line ~server:outcome.report.address
               outcome.changes))
        outcomes;
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
