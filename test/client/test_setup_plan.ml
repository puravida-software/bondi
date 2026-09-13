open Alcotest
module Config_file = Bondi_client.Config_file
module Remote_exec = Bondi_client.Remote_exec
module Managed_container = Bondi_common.Managed_container
module Setup = Bondi_client.Cmd.Setup
module Status_cmd = Bondi_client.Cmd.Status
module Setup_phases = Bondi_client.Setup_phases
module Crontab_listing = Bondi_client.Crontab_listing

(* Production always passes the declared specs; the existing tests predate them
   and are about the non-managed parts of the plan. *)
let plan ?(specs = []) config context = Setup.plan config ~specs context

let action_string = function
  | Setup.EnsureDocker -> "EnsureDocker"
  | Setup.EnsureAcmeFile -> "EnsureAcmeFile"
  | Setup.EnsureNetwork name -> "EnsureNetwork " ^ name
  | Setup.RequireCronDocker -> "RequireCronDocker"
  | Setup.RequireCronCurl -> "RequireCronCurl"
  | Setup.PreserveCronPayloads { crontab } -> (
      match Crontab_listing.jobs_read crontab with
      | None -> "PreserveCronPayloads (no section read)"
      | Some jobs -> "PreserveCronPayloads " ^ String.concat "," jobs)
  | Setup.StopOrchestrator -> "StopOrchestrator"
  | Setup.RemoveOrchestrator -> "RemoveOrchestrator"
  | Setup.RunServer -> "RunServer"
  | Setup.EnsureAlloyConfig -> "EnsureAlloyConfig"
  | Setup.WriteAlloyEnv -> "WriteAlloyEnv"
  | Setup.RunAlloy -> "RunAlloy"
  | Setup.StopAlloy -> "StopAlloy"
  | Setup.RemoveAlloy -> "RemoveAlloy"
  | Setup.CleanAlloyConfig -> "CleanAlloyConfig"
  | Setup.WriteManagedEnv spec ->
      "WriteManagedEnv " ^ Managed_container.name spec
  | Setup.RunManaged spec -> "RunManaged " ^ Managed_container.name spec
  | Setup.StopManaged name -> "StopManaged " ^ name
  | Setup.RemoveManaged name -> "RemoveManaged " ^ name
  | Setup.CleanManagedConfig name -> "CleanManagedConfig " ^ name

let check_actions ~expected actions =
  check (list string) "actions" expected (List.map action_string actions)

let is_ensure_network = function
  | Setup.EnsureNetwork _ -> true
  | Setup.EnsureDocker
  | Setup.EnsureAcmeFile
  | Setup.RequireCronDocker
  | Setup.RequireCronCurl
  | Setup.PreserveCronPayloads _
  | Setup.StopOrchestrator
  | Setup.RemoveOrchestrator
  | Setup.RunServer
  | Setup.EnsureAlloyConfig
  | Setup.WriteAlloyEnv
  | Setup.RunAlloy
  | Setup.StopAlloy
  | Setup.RemoveAlloy
  | Setup.CleanAlloyConfig
  | Setup.WriteManagedEnv _
  | Setup.RunManaged _
  | Setup.StopManaged _
  | Setup.RemoveManaged _
  | Setup.CleanManagedConfig _ ->
      false

(* An action that starts a container on the shared network. EnsureNetwork must
   precede every one of these. *)
let joins_network = function
  | Setup.RunServer
  | Setup.RunAlloy
  | Setup.RunManaged _ ->
      true
  | Setup.EnsureDocker
  | Setup.EnsureAcmeFile
  | Setup.EnsureNetwork _
  | Setup.RequireCronDocker
  | Setup.RequireCronCurl
  | Setup.PreserveCronPayloads _
  | Setup.StopOrchestrator
  | Setup.RemoveOrchestrator
  | Setup.EnsureAlloyConfig
  | Setup.WriteAlloyEnv
  | Setup.StopAlloy
  | Setup.RemoveAlloy
  | Setup.CleanAlloyConfig
  | Setup.WriteManagedEnv _
  | Setup.StopManaged _
  | Setup.RemoveManaged _
  | Setup.CleanManagedConfig _ ->
      false

(* Every action the managed-container convergence can emit. Filtering to these
   keeps the convergence assertions independent of the rest of the plan. *)
let is_managed = function
  | Setup.WriteManagedEnv _
  | Setup.RunManaged _
  | Setup.StopManaged _
  | Setup.RemoveManaged _
  | Setup.CleanManagedConfig _ ->
      true
  | Setup.EnsureDocker
  | Setup.EnsureAcmeFile
  | Setup.EnsureNetwork _
  | Setup.RequireCronDocker
  | Setup.RequireCronCurl
  | Setup.PreserveCronPayloads _
  | Setup.StopOrchestrator
  | Setup.RemoveOrchestrator
  | Setup.RunServer
  | Setup.EnsureAlloyConfig
  | Setup.WriteAlloyEnv
  | Setup.RunAlloy
  | Setup.StopAlloy
  | Setup.RemoveAlloy
  | Setup.CleanAlloyConfig ->
      false

let check_managed_actions ~expected actions =
  check (list string) "managed actions" expected
    (actions |> List.filter is_managed |> List.map action_string)

let indices_where predicate actions =
  actions
  |> List.mapi (fun index action -> (index, action))
  |> List.filter_map (fun (index, action) ->
      if predicate action then Some index else None)

let minimal_server =
  { Config_file.ip_address = "1.2.3.4"; Config_file.ssh = None; port = None }

let minimal_user_service =
  {
    Config_file.name = "my-service";
    Config_file.image = "app";
    Config_file.port = 8080;
    Config_file.registry_user = None;
    Config_file.registry_pass = None;
    Config_file.env_vars = [];
    Config_file.servers = [ minimal_server ];
    Config_file.drain_grace_period = None;
    Config_file.deployment_strategy = None;
    Config_file.health_timeout = None;
    Config_file.poll_interval = None;
    Config_file.logs = None;
  }

let make_config ?(alloy = None) ?(managed_containers = None) ~user_service
    ~cron_jobs ~version () =
  {
    Config_file.user_service;
    Config_file.bondi_server =
      { Config_file.version; bind_address = None; api_token = None };
    Config_file.traefik = None;
    Config_file.cron_jobs;
    Config_file.alloy;
    managed_containers;
  }

(* The context carries the probe's own result rather than a pre-derived status,
   so every arm of the plan is reached through the same derivation production
   uses: a fixture that bypassed it could pin a state [gather_context] can
   never produce. *)
(* [crontab] defaults to the host having no Bondi section, which is the arm that
   plans nothing: a case that leaves it out cannot silently acquire an action it
   did not ask for. Both cases that care about it pass it, including the one
   asserting its absence, so neither rests on this default. *)
let ctx ?(alloy_state = Setup.Alloy_absent)
    ?(managed = Setup.Managed_observed [])
    ?(crontab = Crontab_listing.No_section) ~orchestrator ~docker_probe () =
  {
    Setup.docker_status = Setup.docker_status_of_probe docker_probe;
    Setup.orchestrator;
    Setup.alloy_state;
    Setup.managed;
    Setup.crontab;
  }

(* One distinctive transport failure, shared by every probe fixture in this
   file. An assertion that this text reached the operator cannot pass on a
   generic failure the way "an error was returned" would. The probes that read
   the failure as a value and the ones that still read it as text are pinned
   against the same sentence by deriving the text from the value, rather than
   by spelling it twice. *)
let transport_failure =
  Remote_exec.Ssh_failed
    { code = 255; output = "Connection closed by 203.0.113.9 port 22" }

let transport_error = Remote_exec.message transport_failure

(* The four probe results this file pins apart. Absence and transport failure
   both reach the client on the error channel — [ssh] propagates the remote
   shell's exit 127 for a missing command, and every non-zero exit arrives as
   an [Error] — so a fixture that answered [Ok] for an absent Docker would pin
   a reading [gather_context] can never produce. What tells them apart is the
   status, which is why these carry the failure rather than its rendering. *)
let docker_present = Ok "Docker version 24.0"

let docker_missing =
  Error
    (Remote_exec.Command_failed
       { code = 127; output = "bash: docker: command not found\n" })

let docker_unreachable = Error transport_failure

let docker_status_string = function
  | Setup.Docker_installed output -> "Docker_installed " ^ output
  | Setup.Docker_not_installed output -> "Docker_not_installed " ^ output
  | Setup.Docker_undetermined message -> "Docker_undetermined " ^ message

let check_docker_status ~expected probe =
  check string "docker status"
    (docker_status_string expected)
    (docker_status_string (Setup.docker_status_of_probe probe))

let docker_install_verdict_string = function
  | Setup.Docker_satisfied version -> "Docker_satisfied " ^ version
  | Setup.Docker_install -> "Docker_install"
  | Setup.Docker_abort message -> "Docker_abort " ^ message

let check_docker_install_verdict ~expected probe =
  check string "docker install verdict"
    (docker_install_verdict_string expected)
    (docker_install_verdict_string
       (Setup.docker_install_verdict_of_probe probe))

(* ------------------------------------------------------------------------- *)
(* Managed container fixtures                                                *)
(* ------------------------------------------------------------------------- *)

let managed_entry ?(tag = "10.48.1e") ?ports ?env_vars ?secret_env_vars ~name ()
    =
  {
    Config_file.name;
    Config_file.image = "acme/gateway";
    Config_file.tag;
    Config_file.restart = "unless-stopped";
    Config_file.network = Some Bondi_common.Defaults.network_name;
    Config_file.ports;
    Config_file.env_vars;
    Config_file.secret_env_vars;
  }

(* Declared specs are built through the real config path rather than through
   [Managed_container.create] directly, so the plan tests exercise the same
   parsing the CLI does. *)
let specs_of_entries entries =
  let config =
    make_config ~managed_containers:(Some entries) ~user_service:None
      ~cron_jobs:None ~version:"1.0.0" ()
  in
  match Config_file.managed_containers config with
  | Ok specs -> specs
  | Error message -> failwith message

let spec_named name specs =
  match List.find_opt (fun s -> Managed_container.name s = name) specs with
  | Some spec -> spec
  | None -> failwith ("no spec named " ^ name)

(* Observed state is built from real [docker ps] output so the gather parser and
   the plan are pinned together rather than the fixture bypassing the parser. *)
let observed pairs =
  pairs
  |> List.map (fun (name, hash) -> Printf.sprintf "%s\t%s" name hash)
  |> String.concat "\n"
  |> fun output ->
  Setup.Managed_observed (Setup.managed_of_ps_output (output ^ "\n"))

(* ------------------------------------------------------------------------- *)
(* Orchestrator observation                                                  *)
(* ------------------------------------------------------------------------- *)

(* The two orchestrator listings the plan tests are built from: one that
   answered, and one that never ran. *)
let orchestrator_probe_running = Ok "running\tmlopez1506/bondi-server:0.9.0\n"
let orchestrator_unreachable = Error transport_error

(* `docker ps -a` reports containers in every state, which is what lets a dead
   orchestrator be seen at all. Reading "exited" as running is the shape of the
   outage this change exists to prevent: setup would skip the restart and leave
   the host with nothing serving. *)
let test_exited_orchestrator_is_not_read_as_running () =
  check bool "an exited container is not running" true
    (Setup.orchestrator_state_of_ps_output
       "exited\tmlopez1506/bondi-server:0.10.1\n"
    = Setup.Orchestrator_not_running)

let test_running_orchestrator_reports_its_version () =
  check bool "version read from the image tag" true
    (Setup.orchestrator_state_of_ps_output
       "running\tmlopez1506/bondi-server:0.10.1\n"
    = Setup.Orchestrator_running { version = "0.10.1" })

(* A container built from some other image is still the orchestrator by name.
   Reporting the whole image is what makes the version-mismatch message
   readable when someone has pinned a fork or a local build. *)
let test_running_orchestrator_from_another_image_reports_the_image () =
  check bool "whole image reported" true
    (Setup.orchestrator_state_of_ps_output "running\tlocal/bondi:dev\n"
    = Setup.Orchestrator_running { version = "local/bondi:dev" })

let orchestrator_state_string = function
  | Setup.Orchestrator_absent -> "Orchestrator_absent"
  | Setup.Orchestrator_not_running -> "Orchestrator_not_running"
  | Setup.Orchestrator_running { version } -> "Orchestrator_running " ^ version
  | Setup.Orchestrator_undetermined message ->
      "Orchestrator_undetermined " ^ message

(* A [docker ps] that never ran cannot say the host holds no orchestrator.
   Reading its transport error as an absence plans a [docker run] against a name
   that may already be taken, and the error the client saw is discarded on the
   way. The affirmative arm is the same function on a successful probe: without
   it the assertion above would hold for a derivation that reports every reading
   as undetermined. *)
let test_orchestrator_probe_error_is_undetermined () =
  check string "a failed listing is undetermined"
    (orchestrator_state_string
       (Setup.Orchestrator_undetermined
          "the host was not reached (255): Connection closed by 203.0.113.9 \
           port 22"))
    (orchestrator_state_string
       (Setup.orchestrator_state_of_probe orchestrator_unreachable));
  check string "a successful listing is read"
    (orchestrator_state_string
       (Setup.Orchestrator_running { version = "0.9.0" }))
    (orchestrator_state_string
       (Setup.orchestrator_state_of_probe orchestrator_probe_running))

let test_no_orchestrator_container_is_absent () =
  check bool "no container is absent" true
    (Setup.orchestrator_state_of_ps_output "\n" = Setup.Orchestrator_absent)

(* Docker reports "created" for a container that was never started and
   "restarting" for one in a crash loop. Neither is serving, and both must be
   replaced rather than skipped. *)
let test_non_running_states_are_not_serving () =
  List.iter
    (fun state ->
      check bool
        (state ^ " is not running")
        true
        (Setup.orchestrator_state_of_ps_output
           (state ^ "\tmlopez1506/bondi-server:0.10.1\n")
        = Setup.Orchestrator_not_running))
    [ "created"; "restarting"; "paused"; "dead" ]

(* ------------------------------------------------------------------------- *)
(* Alloy observation                                                         *)
(* ------------------------------------------------------------------------- *)

(* Alloy state is built from real `docker ps -a` output for the same reason the
   managed fixtures are: a fixture that bypasses the derivation can pin a state
   [gather_context] is unable to produce. *)
let alloy_ps ~state ~image =
  Setup.alloy_state_of_ps_output (Printf.sprintf "%s\t%s\n" state image)

(* A container that exists but is not running still holds its name, so it is not
   the same fact as no container at all. Reading the first as the second makes
   the plan run [docker run] against a name that is taken, which is the conflict
   that wedged every later setup on the affected host. *)
let test_alloy_stopped_container_is_present_not_absent () =
  check bool "an exited container is present" true
    (alloy_ps ~state:"exited" ~image:"grafana/alloy:v1.8.0"
    = Setup.Alloy_present)

(* Running and stopped are the same fact to the plan: both hold the name, and
   alloy is replaced either way. The state column is still read because it is
   what tells a container apart from no container at all. *)
let test_alloy_running_container_is_present () =
  check bool "a running container is present" true
    (alloy_ps ~state:"running" ~image:"grafana/alloy:v1.8.0"
    = Setup.Alloy_present)

let test_alloy_no_container_is_absent () =
  check bool "no container is absent" true
    (Setup.alloy_state_of_ps_output "\n" = Setup.Alloy_absent)

let alloy_state_string = function
  | Setup.Alloy_absent -> "Alloy_absent"
  | Setup.Alloy_present -> "Alloy_present"
  | Setup.Alloy_undetermined message -> "Alloy_undetermined " ^ message

(* The two alloy listings the plan tests are built from. *)
let alloy_probe_stopped = Ok "exited\tgrafana/alloy:v1.8.0\n"
let alloy_unreachable = Error transport_error

(* The same reading as the orchestrator's: a listing that never ran is not a
   host with no alloy container, and the plan must not run one against a name it
   never checked. The affirmative arm is the same function on a listing that
   answered. *)
let test_alloy_probe_error_is_undetermined () =
  check string "a failed listing is undetermined"
    (alloy_state_string (Setup.Alloy_undetermined transport_error))
    (alloy_state_string (Setup.alloy_state_of_probe alloy_unreachable));
  check string "a successful listing is read"
    (alloy_state_string Setup.Alloy_present)
    (alloy_state_string (Setup.alloy_state_of_probe alloy_probe_stopped))

(* ------------------------------------------------------------------------- *)
(* Docker observation                                                        *)
(* ------------------------------------------------------------------------- *)

(* A probe that never ran says nothing about the remote host. Reading its
   transport error as "Docker is not installed" is what let a dropped SSH
   connection pipe an installer into root's shell on a host whose engine was
   already current. *)
let test_docker_probe_error_is_undetermined () =
  check_docker_status
    ~expected:
      (Setup.Docker_undetermined
         "the host was not reached (255): Connection closed by 203.0.113.9 \
          port 22")
    docker_unreachable

(* The affirmative absence arm: the shell's own report that the command does
   not exist is a positive determination, and the only one that may lead to an
   install. It arrives as a non-zero exit, which is the same channel the
   transport error above arrives on — the two are told apart by the status the
   host's shell returned, not by whether the command succeeded. *)
let test_docker_probe_command_not_found_is_not_installed () =
  check_docker_status
    ~expected:
      (Setup.Docker_not_installed
         "command failed (127): bash: docker: command not found")
    docker_missing

let test_docker_probe_version_output_is_installed () =
  check_docker_status
    ~expected:(Setup.Docker_installed "Docker version 29.2.1, build 1234567")
    (Ok "Docker version 29.2.1, build 1234567\n")

(* Absence is the status the host's shell returned, not the words it chose to
   return it with. A shell that words it without the word "command" exits 127
   all the same, and a client that read the sentence rather than the status
   refused to install on a host that had positively answered. *)
let test_docker_probe_absence_is_the_exit_status_not_the_wording () =
  check_docker_status
    ~expected:
      (Setup.Docker_not_installed
         "command failed (127): sh: 1: docker: not found")
    (Error
       (Remote_exec.Command_failed
          { code = 127; output = "sh: 1: docker: not found\n" }))

(* The same reading in the direction that costs something. A connection that
   never opened leaves by ssh's own exit 255, and nothing keeps the text it
   leaves from carrying those same words: the output is whatever reached this
   client. Read as a sentence, that piped get.docker.com into root's shell on a
   host this run never reached; the status says the command never ran. *)
let test_docker_probe_transport_failure_that_says_not_found_is_undetermined () =
  let never_connected =
    Error
      (Remote_exec.Ssh_failed
         { code = 255; output = "sh: line 1: jump-helper: command not found\n" })
  in
  check_docker_status
    ~expected:
      (Setup.Docker_undetermined
         "the host was not reached (255): sh: line 1: jump-helper: command not \
          found")
    never_connected;
  match Setup.docker_install_verdict_of_probe never_connected with
  | Setup.Docker_install ->
      fail "a connection that never opened must not install Docker"
  | Setup.Docker_satisfied version ->
      failf "nor is it an installed Docker: %s" version
  | Setup.Docker_abort _ -> ()

(* No action list is produced at all, so nothing is interpreted against a host
   whose state was never read. *)
let test_plan_for_config_aborts_on_undetermined_docker () =
  let config =
    make_config ~user_service:None ~cron_jobs:None ~version:"1.0.0" ()
  in
  let context =
    ctx ~orchestrator:Setup.Orchestrator_absent ~docker_probe:docker_unreachable
      ()
  in
  match Setup.plan_for_config config context with
  | Ok actions ->
      fail
        ("expected an undetermined Docker probe to be rejected, planned: "
        ^ String.concat ", " (List.map action_string actions))
  | Error _ -> ()

(* Naming the transport error is what makes the abort actionable. A message
   that only said a probe had failed would be a second silent conclusion. *)
let test_plan_for_config_abort_names_the_transport_error () =
  let config =
    make_config ~user_service:None ~cron_jobs:None ~version:"1.0.0" ()
  in
  let context =
    ctx ~orchestrator:Setup.Orchestrator_absent ~docker_probe:docker_unreachable
      ()
  in
  match Setup.plan_for_config config context with
  | Ok _ -> fail "expected an undetermined Docker probe to be rejected"
  | Error message ->
      check bool "carries the probe's own text"
        (Bondi_common.String_utils.contains
           ~needle:"Connection closed by 203.0.113.9 port 22" message)
        true

(* The same fixture with a positively absent Docker: the abort above must be
   caused by the reading, not by the plan having stopped installing at all. *)
let test_plan_for_config_still_installs_when_docker_is_absent () =
  let config =
    make_config ~user_service:None ~cron_jobs:None ~version:"1.0.0" ()
  in
  let context =
    ctx ~orchestrator:Setup.Orchestrator_absent ~docker_probe:docker_missing ()
  in
  match Setup.plan_for_config config context with
  | Error message -> fail message
  | Ok actions ->
      check bool "EnsureDocker planned for an absent Docker"
        (List.mem Setup.EnsureDocker actions)
        true

(* ------------------------------------------------------------------------- *)
(* Docker install verdict                                                     *)
(* ------------------------------------------------------------------------- *)

(* The interpreter re-probes the version itself before acting on EnsureDocker,
   which is a second SSH round trip and a second chance for the connection to
   drop. A dropped one used to print "Docker not found" and pipe get.docker.com
   into root's shell, upgrading the engine and restarting every container on a
   host whose Docker was already current. *)
let test_ensure_docker_probe_error_is_a_failure_not_an_install () =
  match Setup.docker_install_verdict_of_probe docker_unreachable with
  | Setup.Docker_install -> fail "a failed probe must not install Docker"
  | Setup.Docker_satisfied version ->
      fail ("a failed probe is not an installed Docker: " ^ version)
  | Setup.Docker_abort message ->
      check bool "carries the probe's own text"
        (Bondi_common.String_utils.contains
           ~needle:"Connection closed by 203.0.113.9 port 22" message)
        true

(* The affirmative arm: the shell's own report that the command does not exist
   is the one reading that may install. Without it the assertion above would
   hold for a verdict that never installs at all. *)
let test_ensure_docker_verdict_installs_only_when_absent () =
  check_docker_install_verdict ~expected:Setup.Docker_install docker_missing

let test_ensure_docker_verdict_is_satisfied_when_installed () =
  check_docker_install_verdict
    ~expected:(Setup.Docker_satisfied "Docker version 29.2.1, build 1234567")
    (Ok "Docker version 29.2.1, build 1234567\n")

(* ------------------------------------------------------------------------- *)
(* Cron curl verdict                                                          *)
(* ------------------------------------------------------------------------- *)

(* The lines an older bondi wrote use --fail-with-body and keep firing until
   each job is deployed again, so setup checks the host's curl before the
   orchestrator starts. That check reads a version string, and a
   probe that never ran has no version string in it. Folding the transport's own
   error into curl's output told the operator that curl had answered
   "the host was not reached (255): Connection closed by …" but 7.76.0 is
   required — a failure to ask, dressed up as a fact about curl. *)
let test_cron_curl_probe_error_is_not_curls_answer () =
  match Setup.cron_curl_verdict_of_probe (Error transport_failure) with
  | Setup.Cron_curl_reported output ->
      failf "a probe that never ran is not curl's answer: %s" output
  | Setup.Cron_curl_undetermined message ->
      check bool "carries the probe's own text" true
        (Bondi_common.String_utils.contains
           ~needle:"Connection closed by 203.0.113.9 port 22" message)

(* Two affirmative arms on the same builder, because a verdict that is never
   curl's answer would satisfy the assertion above. A version the host printed
   is one; so is the host's own report that the command does not exist, which
   arrives on the error channel too and is a fact about curl rather than about
   the read. *)
let test_cron_curl_host_answers_are_curls_answer () =
  (match
     Setup.cron_curl_verdict_of_probe (Ok "curl 8.5.0 (x86_64) libcurl/8.5.0")
   with
  | Setup.Cron_curl_reported output ->
      check bool "the version the host printed" true
        (Bondi_common.String_utils.contains ~needle:"8.5.0" output)
  | Setup.Cron_curl_undetermined message ->
      failf "a version the host printed is curl's answer: %s" message);
  match
    Setup.cron_curl_verdict_of_probe
      (Error
         (Remote_exec.Command_failed
            { code = 127; output = "bash: curl: command not found\n" }))
  with
  | Setup.Cron_curl_reported output ->
      check bool "and so is the host saying it has none" true
        (Bondi_common.String_utils.contains ~needle:"command not found" output)
  | Setup.Cron_curl_undetermined message ->
      failf "a host reporting no curl has answered about curl: %s" message

(* Curl's absence is read the same way Docker's is: by the status the host's
   shell returned, not by the words it chose. A shell that words it without the
   word "command" has still answered about curl. *)
let test_cron_curl_absence_is_the_exit_status_not_the_wording () =
  match
    Setup.cron_curl_verdict_of_probe
      (Error
         (Remote_exec.Command_failed
            { code = 127; output = "sh: 1: curl: not found\n" }))
  with
  | Setup.Cron_curl_reported output ->
      check bool "carries what the host said" true
        (Bondi_common.String_utils.contains ~needle:"curl: not found" output)
  | Setup.Cron_curl_undetermined message ->
      failf "a host reporting no curl has answered about curl: %s" message

(* And a connection that never opened is not curl's answer however its own text
   reads. It leaves by ssh's own exit 255, and reading it as an answer decides
   the crontab command's fate against a version the host never printed. *)
let test_cron_curl_transport_failure_that_says_not_found_is_undetermined () =
  match
    Setup.cron_curl_verdict_of_probe
      (Error
         (Remote_exec.Ssh_failed
            {
              code = 255;
              output = "sh: line 1: jump-helper: command not found\n";
            }))
  with
  | Setup.Cron_curl_reported output ->
      failf "a probe that never ran is not curl's answer: %s" output
  | Setup.Cron_curl_undetermined _ -> ()

(* ------------------------------------------------------------------------- *)
(* Cron docker probe                                                          *)
(* ------------------------------------------------------------------------- *)

(* The generated crontab line invokes [docker exec] by bare name, and cron runs
   a job with a minimal PATH rather than the login one every other probe here is
   answered under. The probe asks the question cron would ask, under [env -i],
   and it always exits 0 and says which -- so a connection that never opened is
   not the host's report that cron cannot find docker. Read as one, setup would
   refuse a perfectly good box, or -- with the arms the other way round -- pass
   a box whose jobs all fail at their next fire. *)
let test_cron_docker_probe_error_is_not_an_absent_docker () =
  match Setup.cron_docker_state_of_probe (Error "the read failed") with
  | Setup.Cron_docker_on_path path ->
      failf "a probe that never ran did not resolve docker: %s" path
  | Setup.Cron_docker_off_path ->
      fail "a probe that never ran is not the host saying cron has no docker"
  | Setup.Cron_docker_undetermined message ->
      check bool "carries the read's own text" true
        (Bondi_common.String_utils.contains ~needle:"the read failed" message)

(* Both host answers, on the one builder. A verdict that is never [on_path]
   would satisfy the absent assertion below, and one that is never [off_path]
   would satisfy the present one. The present arm carries the path cron would
   run, which is the fact an operator acts on when the two Docker installs
   disagree. *)
let test_cron_docker_probe_reports_what_the_host_resolved () =
  (match
     Setup.cron_docker_state_of_probe
       (Ok "BONDI_CRON_DOCKER_PRESENT /usr/bin/docker\n")
   with
  | Setup.Cron_docker_on_path path ->
      check string "the path cron's own PATH resolves" "/usr/bin/docker" path
  | Setup.Cron_docker_off_path ->
      fail "a host that resolved docker has not said cron cannot find it"
  | Setup.Cron_docker_undetermined message ->
      failf "a host that resolved docker has answered: %s" message);
  match Setup.cron_docker_state_of_probe (Ok "BONDI_CRON_DOCKER_ABSENT\n") with
  | Setup.Cron_docker_on_path path ->
      failf "a host that resolved nothing has no path: %s" path
  | Setup.Cron_docker_off_path -> ()
  | Setup.Cron_docker_undetermined message ->
      failf "a host saying cron cannot find docker has answered: %s" message

(* An answer carrying neither marker is neither. The probe is the only thing
   that can produce them, so output without one came from something else --
   a banner, a shell profile, a wrapper -- and reading it as an answer decides
   the host's cron against words nothing here wrote. *)
let test_cron_docker_probe_without_a_marker_is_undetermined () =
  match
    Setup.cron_docker_state_of_probe (Ok "Welcome to Ubuntu 22.04 LTS\n")
  with
  | Setup.Cron_docker_on_path path -> failf "no marker, yet a path: %s" path
  | Setup.Cron_docker_off_path -> fail "no marker is not an absence"
  | Setup.Cron_docker_undetermined message ->
      check bool "quotes what the host said" true
        (Bondi_common.String_utils.contains ~needle:"Welcome to Ubuntu" message)

(* The command asks the question cron would ask, not the one ssh would. Without
   [env -i] the shell resolves the name against the login PATH, which is the
   reading the Docker probe already has and the one this check exists to
   distinguish from. *)
let test_cron_docker_probe_command_clears_the_environment () =
  let command = Setup.cron_docker_probe_command in
  let says needle = Bondi_common.String_utils.contains ~needle command in
  check bool "runs under an empty environment" true (says "env -i");
  check bool "asks the shell to resolve the name" true
    (says "command -v docker");
  check bool "offers the present marker" true
    (says Setup.cron_docker_present_marker);
  check bool "offers the absent marker" true
    (says Setup.cron_docker_absent_marker)

(* ------------------------------------------------------------------------- *)
(* ACME file probe                                                            *)
(* ------------------------------------------------------------------------- *)

(* [test -f] reports an absent file by exiting non-zero, which is the channel a
   dropped connection arrives on as well, so the answer and the failure to get
   one were the same value. A blip on the read was answered with mkdir, touch,
   chown and chmod against a file the host may already have had. The probe says
   which it is on standard output, leaving the exit status to mean "the command
   could be run on that host". *)
let test_acme_probe_error_is_not_an_absent_file () =
  match Setup.acme_file_state_of_probe (Error transport_error) with
  | Setup.Acme_file_absent ->
      fail "a read that never happened is not an absent file"
  | Setup.Acme_file_present -> fail "nor a file the host said it has"
  | Setup.Acme_file_undetermined message ->
      check bool "carries the probe's own text" true
        (Bondi_common.String_utils.contains
           ~needle:"Connection closed by 203.0.113.9 port 22" message)

(* The affirmative arms on the same builder: the host does say which, and the
   two answers are told apart. Without them the assertion above would hold for a
   probe that is never able to answer at all. *)
let test_acme_probe_reports_what_the_host_said () =
  (match
     Setup.acme_file_state_of_probe (Ok (Setup.acme_file_present_marker ^ "\n"))
   with
  | Setup.Acme_file_present -> ()
  | Setup.Acme_file_absent
  | Setup.Acme_file_undetermined _ ->
      fail "the host saying it has the file is the file being there");
  match
    Setup.acme_file_state_of_probe (Ok (Setup.acme_file_absent_marker ^ "\n"))
  with
  | Setup.Acme_file_absent -> ()
  | Setup.Acme_file_present
  | Setup.Acme_file_undetermined _ ->
      fail "the host saying it does not have the file is the file being absent"

(* An answer carrying neither marker never said which. Read as absence it
   becomes a write against a host that was never asked. *)
let test_acme_probe_without_a_marker_is_undetermined () =
  match Setup.acme_file_state_of_probe (Ok "") with
  | Setup.Acme_file_absent -> fail "silence is not an absent file"
  | Setup.Acme_file_present -> fail "nor a present one"
  | Setup.Acme_file_undetermined _ -> ()

(* The command carries the whole distinction, so it is pinned here rather than
   left to the one caller: it names the file, offers both answers, and the
   client's reading of it is only as good as the command asking the question. *)
let test_acme_probe_command_asks_for_both_answers () =
  let command = Setup.acme_probe_command ~path:"/etc/traefik/acme/acme.json" in
  let carries needle = Bondi_common.String_utils.contains ~needle command in
  check bool "names the file it is asking about" true
    (carries "/etc/traefik/acme/acme.json");
  check bool "can say the host has it" true
    (carries Setup.acme_file_present_marker);
  check bool "and can say the host does not" true
    (carries Setup.acme_file_absent_marker)

let test_plan_always_includes_ensure_docker () =
  let config =
    make_config ~user_service:None ~cron_jobs:None ~version:"1.0.0" ()
  in
  let context =
    ctx ~orchestrator:Setup.Orchestrator_absent ~docker_probe:docker_present ()
  in
  let actions = plan config context in
  check bool "EnsureDocker is first"
    (match actions with
    | first :: _ -> first = Setup.EnsureDocker
    | [] -> false)
    true

let test_plan_no_user_service_skips_acme () =
  let config =
    make_config ~user_service:None ~cron_jobs:None ~version:"1.0.0" ()
  in
  let context =
    ctx ~orchestrator:Setup.Orchestrator_absent ~docker_probe:docker_present ()
  in
  let actions = plan config context in
  check bool "no EnsureAcmeFile when no user_service"
    (List.mem Setup.EnsureAcmeFile actions)
    false

let test_plan_with_user_service_includes_acme () =
  let config =
    make_config ~user_service:(Some minimal_user_service) ~cron_jobs:None
      ~version:"1.0.0" ()
  in
  let context =
    ctx ~orchestrator:Setup.Orchestrator_absent ~docker_probe:docker_present ()
  in
  let actions = plan config context in
  check bool "EnsureAcmeFile when user_service present"
    (List.mem Setup.EnsureAcmeFile actions)
    true

let test_plan_skip_server_when_up_to_date () =
  let config =
    make_config ~user_service:None ~cron_jobs:None ~version:"1.0.0" ()
  in
  let context =
    ctx
      ~orchestrator:(Setup.Orchestrator_running { version = "1.0.0" })
      ~docker_probe:docker_present ()
  in
  let actions = plan config context in
  check bool "no RunServer when version matches and no cron"
    (List.mem Setup.RunServer actions)
    false;
  check bool "no StopOrchestrator when skipping"
    (List.mem Setup.StopOrchestrator actions)
    false

let test_plan_fresh_install_runs_server () =
  let config =
    make_config ~user_service:None ~cron_jobs:None ~version:"1.0.0" ()
  in
  let context =
    ctx ~orchestrator:Setup.Orchestrator_absent ~docker_probe:docker_present ()
  in
  let actions = plan config context in
  check bool "RunServer when no running orchestrator"
    (List.mem Setup.RunServer actions)
    true;
  check bool "no StopOrchestrator on fresh install"
    (List.mem Setup.StopOrchestrator actions)
    false

(* ------------------------------------------------------------------------- *)
(* The readings the orchestrator phase takes                                 *)
(* ------------------------------------------------------------------------- *)

let contains ~needle haystack =
  Bondi_common.String_utils.contains ~needle haystack

(* The commands the orchestrator phase actually sends, built the way the
   interpreter builds them: the production list of readings, mapped through the
   production command for each. A list spelled here instead would assert the
   order of a fixture rather than the order the box is asked in. *)
let reading_commands ~cron_configured =
  List.map
    (Setup.orchestrator_reading_command ~cron_configured)
    Setup.orchestrator_readings

(* Waiting and reading are one ordered pair, and both halves of the order
   matter. A reading taken before the container is running answers for a
   container that has not started, which is the failure the wait exists to
   remove; and a second reading is not free -- the check writes to the
   container's log stream and, where cron is configured, touches the spool the
   host's cron daemon watches, so a phase that reads twice pays those costs
   twice. *)
let test_the_orchestrator_phase_waits_for_running_then_reads_once () =
  let commands = reading_commands ~cron_configured:false in
  (match commands with
  | [ wait; reading; _ ] ->
      check bool "the wait on a running state comes first" true
        (contains ~needle:"{{.State.Status}}" wait);
      check bool "the reading follows it" true
        (contains ~needle:"bondi-server check" reading)
  | []
  | [ _ ]
  | [ _; _ ]
  | _ :: _ :: _ :: _ :: _ ->
      failf
        "the orchestrator phase takes the wait, one reading and the log-stream \
         read, not %d commands"
        (List.length commands));
  check int "exactly one reading is taken" 1
    (List.length (List.filter (contains ~needle:"bondi-server check") commands))

(* The line the log-stream read looks for is one the check writes, so a read
   taken ahead of the check answers for a stream the check had not written to
   yet -- and every orchestrator would be reported as one whose diagnostics
   never arrive, including the ones whose diagnostics do. The order is asserted
   over the production list mapped through the production commands, because
   that list is the thing that decides it; a list spelled here would agree with
   itself. *)
let test_the_log_stream_is_read_after_the_reading_not_before () =
  let commands = reading_commands ~cron_configured:false in
  match commands with
  | [ _; reading; log_read ] ->
      check bool "the reading is taken second" true
        (contains ~needle:"bondi-server check" reading);
      check bool "the log stream is read after it" true
        (contains ~needle:"docker logs" log_read);
      check bool "the read is bounded rather than the container's whole history"
        true
        (contains ~needle:"--tail" log_read)
  | []
  | [ _ ]
  | [ _; _ ]
  | _ :: _ :: _ :: _ :: _ ->
      failf
        "the orchestrator phase takes the wait, one reading and the log-stream \
         read, not %d commands"
        (List.length commands)

(* Each reading is the single place a host's answer collapses into "the phase
   may go on" or "the phase stops, and this is the sentence". Both arms of both
   collapses are pinned here rather than only through a host fixture: a
   boundary owns its contract, and a regression in one should fail at the
   boundary rather than in whichever cram file happened to exercise it. *)
let test_each_reading_collapses_to_go_on_or_stop_with_a_sentence () =
  let waited_out =
    Remote_exec.Command_failed
      {
        code = 1;
        output =
          "container bondi-orchestrator did not reach a running state after 30 \
           attempts";
      }
  in
  let named_its_faults =
    Remote_exec.Command_failed
      {
        code = Bondi_common.Readiness_exit_code.not_ready;
        output = "the Docker socket is not readable";
      }
  in
  let could_not_read =
    Remote_exec.Command_failed
      { code = 1; output = "Error: No such container: bondi-orchestrator" }
  in
  (match Setup.orchestrator_reading_verdict Setup.Wait_running (Ok "") with
  | Ok () -> ()
  | Error reason ->
      failf "a wait that came back is not a container that never started: %s"
        reason);
  (match
     Setup.orchestrator_reading_verdict Setup.Wait_running (Error waited_out)
   with
  | Ok () -> fail "a wait that gave up is not a container that reached running"
  | Error reason ->
      check bool "the host's own sentence survives the collapse" true
        (contains ~needle:"did not reach a running state" reason));
  (match
     Setup.orchestrator_reading_verdict Setup.Take_check (Ok "{\"ready\":true}")
   with
  | Ok () -> ()
  | Error reason -> failf "a box that answered is not a rejection: %s" reason);
  (match
     Setup.orchestrator_reading_verdict Setup.Take_check
       (Error named_its_faults)
   with
  | Ok () -> fail "a box that named its faults is not a box that can serve"
  | Error reason ->
      check bool "the box's own account survives the collapse" true
        (contains ~needle:"the Docker socket is not readable" reason));
  (match
     Setup.orchestrator_reading_verdict Setup.Read_log_stream
       (Ok
          ("2026-09-12T09:00:00Z " ^ Bondi_common.Check_marker.diagnostic_sink
         ^ "\n"))
   with
  | Ok () -> ()
  | Error reason ->
      failf "a stream carrying the line is not a container nobody can see: %s"
        reason);
  (match
     Setup.orchestrator_reading_verdict Setup.Read_log_stream
       (Ok "2026-09-12T09:00:00Z listening on 0.0.0.0:3030\n")
   with
  | Ok () ->
      fail
        "a container whose diagnostics never reach its log stream is not one \
         that came up"
  | Error reason ->
      check bool "the sentence says the line was written and did not arrive"
        true
        (contains ~needle:"diagnostic sink" reason));
  match
    Setup.orchestrator_reading_verdict Setup.Read_log_stream
      (Error could_not_read)
  with
  | Ok () ->
      fail "a stream that could not be read is not a stream found carrying"
  | Error reason ->
      check bool "a read that never happened is not reported as a silent stream"
        true
        (contains ~needle:"the log stream read" reason)

(* ------------------------------------------------------------------------- *)
(* The floor the configured orchestrator image is held to                    *)
(* ------------------------------------------------------------------------- *)

(* An image whose binary has no subcommands does not refuse the reading: it
   ignores the arguments and serves, so the command never answers and the box
   is reported as one that could not be reached. Refusing the configuration is
   what turns that into a sentence naming the two versions. *)
let test_an_image_below_the_command_surface_floor_is_refused () =
  let config =
    make_config ~user_service:None ~cron_jobs:None ~version:"0.14.9" ()
  in
  let context =
    ctx ~orchestrator:Setup.Orchestrator_absent ~docker_probe:docker_present ()
  in
  match Setup.plan_for_config config context with
  | Ok actions ->
      failf "a configuration below the floor was planned: %s"
        (String.concat ", " (List.map action_string actions))
  | Error message ->
      check bool "names the version found" true
        (contains ~needle:"0.14.9" message);
      check bool "names the version needed" true
        (contains
           ~needle:Bondi_client.Server_version.minimum_for_command_surface
           message)

(* The affirmative half of the refusal above, on the same fixture: only the
   declared version moves. Without it the refusal could be a plan that fails
   for any other reason, and the assertion that no container is started would
   hold on a fixture that starts none whatever the version says. *)
let test_an_image_at_the_command_surface_floor_still_runs_the_server () =
  let config =
    make_config ~user_service:None ~cron_jobs:None
      ~version:Bondi_client.Server_version.minimum_for_command_surface ()
  in
  let context =
    ctx ~orchestrator:Setup.Orchestrator_absent ~docker_probe:docker_present ()
  in
  match Setup.plan_for_config config context with
  | Error message -> failf "the floor itself was refused: %s" message
  | Ok actions ->
      check bool "the server is planned at the floor" true
        (List.mem Setup.RunServer actions)

(* ------------------------------------------------------------------------- *)
(* What a rejected reading is reported as                                    *)
(* ------------------------------------------------------------------------- *)

(* Every action the plan still had ahead of the one that failed. Derived from
   the plan rather than spelled, so a phase added after the orchestrator is
   carried into the report by the same route production carries it. *)
let actions_after actions ~failed =
  let rec drop = function
    | [] -> []
    | action :: rest -> if action = failed then rest else drop rest
  in
  drop actions

(* The whole sentence an operator is left with when the box rejects the
   reading, composed the way production composes it: the verdict decides the
   reason, the orchestrator report quotes the container's own account beside
   it, and the phase report says what the run did not reach. Each of the three
   is tested on its own elsewhere; what nothing covers is that the operator
   gets all three at once -- and the container's account, the half that cost a
   day of an outage to obtain by hand, is the one a composition can silently
   drop. *)
let test_a_rejected_reading_reports_the_account_and_the_phases_left_unrun () =
  (* Every field is set, including the ones whose absence is what the phase
     does with them: a record built from a default and edited would leave the
     phases this report names resting on a value nothing here chose. *)
  let alloy =
    {
      Config_file.image = None;
      Config_file.grafana_cloud =
        {
          Config_file.instance_id = "123456";
          Config_file.api_key = "glc_secret";
          Config_file.endpoint =
            "https://logs-prod.grafana.net/loki/api/v1/push";
        };
      Config_file.collect = None;
      Config_file.labels = None;
    }
  in
  let config =
    make_config ~alloy:(Some alloy) ~user_service:None ~cron_jobs:None
      ~version:"1.0.0" ()
  in
  let specs = specs_of_entries [ managed_entry ~name:"gateway" () ] in
  let context =
    ctx ~orchestrator:Setup.Orchestrator_absent ~docker_probe:docker_present ()
  in
  let actions = plan ~specs config context in
  check bool "the fixture plans the run that is rejected" true
    (List.mem Setup.RunServer actions);
  let rejected =
    Remote_exec.Command_failed
      {
        code = Bondi_common.Readiness_exit_code.not_ready;
        output = "docker socket is not readable";
      }
  in
  let reason =
    match
      Bondi_client.Orchestrator_probe.verdict_of_output (Error rejected)
    with
    | Bondi_client.Orchestrator_probe.Serving ->
        fail "the readiness exit code read as a box that can serve"
    | Bondi_client.Orchestrator_probe.Not_ready reason
    | Bondi_client.Orchestrator_probe.Unreachable reason ->
        reason
  in
  let report =
    Setup.action_failure_report ~server:"1.2.3.4" ~failed:Setup.RunServer
      ~remaining:(actions_after actions ~failed:Setup.RunServer)
      ~reason:
        (Bondi_client.Orchestrator_probe.failure_message ~ip_address:"1.2.3.4"
           ~image:"mlopez1506/bondi-server:1.0.0" ~reason
           ~diagnostics:
             "status=exited exit=127 oom=false error=\n\
              --- last 50 log lines ---\n\
              Error loading shared library libzstd.so.1")
  in
  check bool "the box's own reason is carried" true
    (contains ~needle:"docker socket is not readable" report);
  check bool "the container's final state is quoted" true
    (contains ~needle:"status=exited" report);
  check bool "the container's exit code is quoted" true
    (contains ~needle:"exit=127" report);
  check bool "the container's last log lines are quoted" true
    (contains ~needle:"Error loading shared library libzstd.so.1" report);
  check bool "the phases that did not run are named" true
    (contains ~needle:"alloy, managed containers" report)

(* The orchestrator phase, in the order the plan emits it. Filtering by the
   production mapping rather than by a list spelled here keeps the assertion
   about ordering within the phase and independent of everything the plan does
   before and after it. *)
let orchestrator_phase actions =
  actions
  |> List.filter (fun action ->
      Setup.phase_of_action action = Setup_phases.Orchestrator)
  |> List.map action_string

(* A section holding one line the reader could name and one it could not. The
   unnamed entry is what proves the preserve carries jobs rather than lines: a
   position is not a job, and nothing downstream could look for its files. *)
let section_with_one_named_job =
  Crontab_listing.Section
    {
      entries =
        [
          Crontab_listing.Named "nightly-report";
          Crontab_listing.Unnamed { position = 2 };
        ];
    }

(* The copy has to be planned before the container it copies out of is stopped
   and removed, because removing it is what destroys the files on any host that
   does not bind-mount them. Planned after, it would copy from a container that
   is no longer there and report every job as having lost everything -- on a
   host where this run is what lost it. *)
let test_plan_preserve_precedes_the_orchestrator_recreate () =
  let config =
    make_config ~user_service:None ~cron_jobs:None ~version:"1.0.0" ()
  in
  let context =
    ctx
      ~orchestrator:(Setup.Orchestrator_running { version = "0.9.0" })
      ~crontab:section_with_one_named_job ~docker_probe:docker_present ()
  in
  check (list string) "orchestrator phase"
    [
      "PreserveCronPayloads nightly-report";
      "StopOrchestrator";
      "RemoveOrchestrator";
      "RunServer";
    ]
    (orchestrator_phase (plan config context))

(* The same configuration and the same recreate, differing only in what the host
   said its crontab holds. A host Bondi has never written a section on holds no
   line whose file a recreate could orphan, so there is nothing to preserve --
   and the case above is what shows this absence is the reading's doing rather
   than the fixture never reaching the branch. *)
let test_plan_no_preserve_without_a_section () =
  let config =
    make_config ~user_service:None ~cron_jobs:None ~version:"1.0.0" ()
  in
  let context =
    ctx
      ~orchestrator:(Setup.Orchestrator_running { version = "0.9.0" })
      ~crontab:Crontab_listing.No_section ~docker_probe:docker_present ()
  in
  check (list string) "orchestrator phase"
    [ "StopOrchestrator"; "RemoveOrchestrator"; "RunServer" ]
    (orchestrator_phase (plan config context))

(* A stopped container is a recreate like any other, and its files are still
   there to lose: [docker cp] reads a container's writable layer whether or not
   it is running, and the removal that follows is what deletes them while the
   line that reads them stays in the spool. The running arm above was the only
   one pinned, so this arm could have reached that same removal with nothing
   copied out first. *)
let test_plan_preserve_precedes_a_stopped_orchestrator_recreate () =
  let config =
    make_config ~user_service:None ~cron_jobs:None ~version:"1.0.0" ()
  in
  let context =
    ctx ~orchestrator:Setup.Orchestrator_not_running
      ~crontab:section_with_one_named_job ~docker_probe:docker_present ()
  in
  check (list string) "orchestrator phase"
    [ "PreserveCronPayloads nightly-report"; "RemoveOrchestrator"; "RunServer" ]
    (orchestrator_phase (plan config context))

(* A section whose markers do not balance, and a spool file that was never read,
   are the two hosts whose crontab Bondi understands least -- and both are
   copied out of all the same. Neither reading can name a job, so the copy
   carries no section at all -- not an empty one, which would have the report
   name every job in the directory as having no line firing it -- and the run
   reports nothing about the box; the directory it costs is a directory on a
   host nothing is about to rewrite,
   while skipping it is how the recreate deletes the files of lines that go on
   firing. A read that failed is not the host saying there is nothing here.

   The negative arm is the third reading in the same shape: a host that
   positively said it holds no Bondi section and declares no job plans no copy
   at all, so the two copies above are these readings' doing rather than a copy
   planned unconditionally. *)
let test_plan_preserve_for_a_crontab_that_could_not_be_understood () =
  let config =
    make_config ~user_service:None ~cron_jobs:None ~version:"1.0.0" ()
  in
  let phase_for crontab =
    orchestrator_phase
      (plan config
         (ctx
            ~orchestrator:(Setup.Orchestrator_running { version = "0.9.0" })
            ~crontab ~docker_probe:docker_present ()))
  in
  let recreate = [ "StopOrchestrator"; "RemoveOrchestrator"; "RunServer" ] in
  List.iter
    (fun (label, crontab) ->
      check (list string) label
        ("PreserveCronPayloads (no section read)" :: recreate)
        (phase_for crontab))
    [
      ( "markers that do not balance",
        Crontab_listing.Malformed Crontab_listing.Begin_without_end );
      ( "a spool file that was never read",
        Crontab_listing.Unreadable "the host refused sudo -n" );
    ];
  check (list string) "a host that answered it holds no section" recreate
    (phase_for Crontab_listing.No_section)

(* The mount and the copy have to agree, and until they were derived from one
   value they did not. The copy is planned from the section the host holds, so a
   box whose configuration declares no cron job still gets its payload directory
   copied onto the host -- and the mount that makes that directory the
   replacement container's own view was planned from the configuration, which on
   this box declares nothing. The files landed where nothing reads them, the
   crontab line's redirect is evaluated inside the container, and the listing
   read the host directory and found both files, so the run reported success on
   a job that was already broken. *)
let test_run_command_mounts_the_payload_directory_for_a_held_section () =
  let config =
    make_config ~user_service:None ~cron_jobs:None ~version:"1.0.0" ()
  in
  let context =
    ctx
      ~orchestrator:(Setup.Orchestrator_running { version = "0.9.0" })
      ~crontab:section_with_one_named_job ~docker_probe:docker_present ()
  in
  let needed = Setup.cron_payload_needed config context in
  check bool "the section alone makes the payload directory needed" true needed;
  check bool "and the same value plans the copy" true
    (List.mem "PreserveCronPayloads nightly-report"
       (orchestrator_phase (plan config context)));
  match Setup.orchestrator_run_command ~cron_payload_needed:needed config with
  | Error message -> fail message
  | Ok command ->
      check bool "the replacement container sees the host directory" true
        (Bondi_common.String_utils.contains
           ~needle:"-v /etc/bondi/cron:/etc/bondi/cron" command)

(* The negative arm, so the assertion above is the section's doing rather than a
   mount added unconditionally. A host with no section and no declared cron job
   has nothing under that path and gets neither the copy nor the mount. *)
let test_run_command_omits_the_payload_mount_without_cron () =
  let config =
    make_config ~user_service:None ~cron_jobs:None ~version:"1.0.0" ()
  in
  let context =
    ctx
      ~orchestrator:(Setup.Orchestrator_running { version = "0.9.0" })
      ~crontab:Crontab_listing.No_section ~docker_probe:docker_present ()
  in
  let needed = Setup.cron_payload_needed config context in
  check bool "nothing needs the payload directory" false needed;
  match Setup.orchestrator_run_command ~cron_payload_needed:needed config with
  | Error message -> fail message
  | Ok command ->
      check bool "no payload mount" false
        (Bondi_common.String_utils.contains ~needle:"/etc/bondi/cron" command)

(* The reading is asked about the same cron this run planned the mounts from,
   which on this box is not what the configuration declares. A host declaring no
   job and holding a Bondi section all the same is the shape the payload phase
   exists for, and the shape likeliest to be holding a line for a job nothing
   declares any more -- so it is the box whose spool and whose divergence most
   want looking at, on a container this run has just given the mounts to answer
   with. Asked what the configuration declares, it is the one box never probed
   about either.

   The negative arm is the same configuration on a host that answered it holds
   no section: nothing is converged there, and the reading says so. That the
   interpreter passes this planned value and not a second predicate of its own
   is pinned on the commands that reach a host, in
   test/cram/setup_orchestrator.t. *)
let test_the_reading_asks_about_cron_wherever_the_run_converges_it () =
  let config =
    make_config ~user_service:None ~cron_jobs:None ~version:"1.0.0" ()
  in
  let context crontab =
    ctx
      ~orchestrator:(Setup.Orchestrator_running { version = "0.9.0" })
      ~crontab ~docker_probe:docker_present ()
  in
  let asks_about_cron crontab =
    List.exists
      (contains ~needle:"bondi-server check --cron-configured")
      (reading_commands
         ~cron_configured:(Setup.cron_payload_needed config (context crontab)))
  in
  check bool "the configuration declares no cron job" false
    (Setup.has_cron_jobs config);
  check bool "a host holding a section is asked about its crontab" true
    (asks_about_cron section_with_one_named_job);
  check bool "and a host holding none is not" false
    (asks_about_cron Crontab_listing.No_section)

let test_plan_version_mismatch_stops_and_runs () =
  let config =
    make_config ~user_service:None ~cron_jobs:None ~version:"1.0.0" ()
  in
  let context =
    ctx
      ~orchestrator:(Setup.Orchestrator_running { version = "0.9.0" })
      ~docker_probe:docker_present ()
  in
  let actions = plan config context in
  check bool "StopOrchestrator on version mismatch"
    (List.mem Setup.StopOrchestrator actions)
    true;
  check bool "RunServer after version mismatch"
    (List.mem Setup.RunServer actions)
    true

(* The orchestrator no longer runs with --rm, so a container that died on
   startup is still there on the next setup. Running without removing it first
   fails on the name collision, which would make the box unrecoverable by the
   very command an operator reaches for to recover it. *)
let test_plan_exited_orchestrator_is_removed_before_running () =
  let config =
    make_config ~user_service:None ~cron_jobs:None ~version:"1.0.0" ()
  in
  let context =
    ctx ~orchestrator:Setup.Orchestrator_not_running
      ~docker_probe:docker_present ()
  in
  let actions = plan config context in
  check_actions
    ~expected:
      [
        "EnsureDocker";
        "EnsureNetwork bondi-network";
        "RemoveOrchestrator";
        "RunServer";
        "CleanAlloyConfig";
      ]
    actions

(* A running orchestrator being replaced is stopped and then removed: stopping
   alone used to be enough only because --rm deleted it. *)
let test_plan_running_orchestrator_is_removed_after_stopping () =
  let config =
    make_config ~user_service:None ~cron_jobs:None ~version:"1.0.0" ()
  in
  let context =
    ctx
      ~orchestrator:(Setup.Orchestrator_running { version = "0.9.0" })
      ~docker_probe:docker_present ()
  in
  let actions = plan config context in
  check_actions
    ~expected:
      [
        "EnsureDocker";
        "EnsureNetwork bondi-network";
        "StopOrchestrator";
        "RemoveOrchestrator";
        "RunServer";
        "CleanAlloyConfig";
      ]
    actions

let test_plan_cron_jobs_force_restart () =
  let cron_job =
    {
      Config_file.name = "backup";
      Config_file.image = "backup:v1";
      Config_file.schedule = "0 0 * * *";
      Config_file.network = None;
      Config_file.env_vars = None;
      Config_file.secret_env_vars = None;
      Config_file.registry_user = None;
      Config_file.registry_pass = None;
      Config_file.alert_sinks = None;
      Config_file.exit_code_severities = None;
      Config_file.server = minimal_server;
    }
  in
  let config =
    make_config ~user_service:None ~cron_jobs:(Some [ cron_job ])
      ~version:"1.0.0" ()
  in
  let context =
    ctx
      ~orchestrator:(Setup.Orchestrator_running { version = "1.0.0" })
      ~docker_probe:docker_present ()
  in
  let actions = plan config context in
  check bool "StopOrchestrator when adding cron jobs"
    (List.mem Setup.StopOrchestrator actions)
    true;
  check bool "RunServer when adding cron jobs"
    (List.mem Setup.RunServer actions)
    true

let test_plan_action_order () =
  let config =
    make_config ~user_service:(Some minimal_user_service) ~cron_jobs:None
      ~version:"1.0.0" ()
  in
  let context =
    ctx
      ~orchestrator:(Setup.Orchestrator_running { version = "0.9.0" })
      ~docker_probe:docker_present ()
  in
  let actions = plan config context in
  check_actions
    ~expected:
      [
        "EnsureDocker";
        "EnsureNetwork bondi-network";
        "EnsureAcmeFile";
        "StopOrchestrator";
        "RemoveOrchestrator";
        "RunServer";
        "CleanAlloyConfig";
      ]
    actions

let test_plan_cron_only_no_acme () =
  let cron_job =
    {
      Config_file.name = "backup";
      Config_file.image = "backup:v1";
      Config_file.schedule = "0 0 * * *";
      Config_file.network = None;
      Config_file.env_vars = None;
      Config_file.secret_env_vars = None;
      Config_file.registry_user = None;
      Config_file.registry_pass = None;
      Config_file.alert_sinks = None;
      Config_file.exit_code_severities = None;
      Config_file.server = minimal_server;
    }
  in
  let config =
    make_config ~user_service:None ~cron_jobs:(Some [ cron_job ])
      ~version:"1.0.0" ()
  in
  let context =
    ctx ~orchestrator:Setup.Orchestrator_absent ~docker_probe:docker_present ()
  in
  let actions = plan config context in
  check bool "no EnsureAcmeFile when cron-only (no user_service)"
    (List.mem Setup.EnsureAcmeFile actions)
    false;
  check_actions
    ~expected:
      [
        "EnsureDocker";
        "EnsureNetwork bondi-network";
        "RequireCronDocker";
        "RequireCronCurl";
        "RunServer";
        "CleanAlloyConfig";
      ]
    actions

(* The crontab lines an older bondi wrote use --fail-with-body, which an older
   curl rejects as an unknown option, and they go on firing until each job is
   deployed again. Verifying the host's curl at setup turns that into one loud
   failure here rather than every surviving legacy job failing at its next tick. The check precedes RunServer, so an unusable host
   never gets an orchestrator that would write lines it cannot run. *)
let test_plan_requires_curl_when_cron_jobs_declared () =
  let cron_job =
    {
      Config_file.name = "backup";
      Config_file.image = "backup:v1";
      Config_file.schedule = "0 0 * * *";
      Config_file.network = None;
      Config_file.env_vars = None;
      Config_file.secret_env_vars = None;
      Config_file.registry_user = None;
      Config_file.registry_pass = None;
      Config_file.alert_sinks = None;
      Config_file.exit_code_severities = None;
      Config_file.server = minimal_server;
    }
  in
  let config =
    make_config ~user_service:None ~cron_jobs:(Some [ cron_job ])
      ~version:"1.0.0" ()
  in
  let context =
    ctx ~orchestrator:Setup.Orchestrator_absent ~docker_probe:docker_present ()
  in
  let actions = plan config context in
  let index_of target =
    let rec find i = function
      | [] -> None
      | action :: rest -> if action = target then Some i else find (i + 1) rest
    in
    find 0 actions
  in
  match (index_of Setup.RequireCronCurl, index_of Setup.RunServer) with
  | None, _ -> fail "a config declaring cron jobs must verify the host's curl"
  | _, None -> fail "the plan must still run the server"
  | Some curl, Some server ->
      check bool "the curl check precedes RunServer" true (curl < server)

(* The affirmative arm above with the cron jobs removed: a host that runs no
   cron jobs never sees a bondi crontab line, so requiring a curl version of it
   would be a prerequisite it does not owe. *)
let test_plan_omits_curl_check_without_cron_jobs () =
  let config =
    make_config ~user_service:(Some minimal_user_service) ~cron_jobs:None
      ~version:"1.0.0" ()
  in
  let context =
    ctx ~orchestrator:Setup.Orchestrator_absent ~docker_probe:docker_present ()
  in
  check bool "no curl requirement without cron jobs"
    (List.mem Setup.RequireCronCurl (plan config context))
    false

(* The crontab line invokes [docker exec] by bare name, and cron gives a job a
   minimal PATH. A box whose docker sits outside it answers every probe setup
   runs over ssh and still fails every scheduled job at its next fire, which is
   the class of failure the setup-time gates exist to move forward. The check
   precedes RunServer for the same reason the curl one does: a host that cannot
   run the line never gets an orchestrator that would write it. *)
let test_plan_requires_cron_docker_when_cron_jobs_declared () =
  let cron_job =
    {
      Config_file.name = "backup";
      Config_file.image = "backup:v1";
      Config_file.schedule = "0 0 * * *";
      Config_file.network = None;
      Config_file.env_vars = None;
      Config_file.secret_env_vars = None;
      Config_file.registry_user = None;
      Config_file.registry_pass = None;
      Config_file.alert_sinks = None;
      Config_file.exit_code_severities = None;
      Config_file.server = minimal_server;
    }
  in
  let config =
    make_config ~user_service:None ~cron_jobs:(Some [ cron_job ])
      ~version:"1.0.0" ()
  in
  let context =
    ctx ~orchestrator:Setup.Orchestrator_absent ~docker_probe:docker_present ()
  in
  let actions = plan config context in
  let index_of target =
    let rec find i = function
      | [] -> None
      | action :: rest -> if action = target then Some i else find (i + 1) rest
    in
    find 0 actions
  in
  match (index_of Setup.RequireCronDocker, index_of Setup.RunServer) with
  | None, _ ->
      fail
        "a config declaring cron jobs must verify docker is on the PATH cron \
         runs a job with"
  | _, None -> fail "the plan must still run the server"
  | Some cron_docker, Some server ->
      check bool "the cron docker check precedes RunServer" true
        (cron_docker < server)

(* The affirmative arm above with the cron jobs removed: a host that runs no
   cron jobs never sees a bondi crontab line, so what cron's PATH resolves is
   not a prerequisite it owes. *)
let test_plan_omits_cron_docker_check_without_cron_jobs () =
  let config =
    make_config ~user_service:(Some minimal_user_service) ~cron_jobs:None
      ~version:"1.0.0" ()
  in
  let context =
    ctx ~orchestrator:Setup.Orchestrator_absent ~docker_probe:docker_present ()
  in
  check bool "no cron docker requirement without cron jobs"
    (List.mem Setup.RequireCronDocker (plan config context))
    false

let test_setup_plans_ensure_network () =
  let config =
    make_config ~user_service:None ~cron_jobs:None ~version:"1.0.0" ()
  in
  let context =
    ctx ~orchestrator:Setup.Orchestrator_absent ~docker_probe:docker_present ()
  in
  let actions = plan config context in
  check bool "EnsureNetwork for the shared network"
    (List.mem (Setup.EnsureNetwork Bondi_common.Defaults.network_name) actions)
    true

let minimal_alloy =
  {
    Config_file.image = None;
    Config_file.grafana_cloud =
      {
        Config_file.instance_id = "123456";
        Config_file.api_key = "glc_secret";
        Config_file.endpoint = "https://logs-prod.grafana.net/loki/api/v1/push";
      };
    Config_file.collect = None;
    Config_file.labels = None;
  }

let test_setup_plan_ensure_network_precedes_joining_actions () =
  let entries = [ managed_entry ~name:"gateway" () ] in
  let config =
    make_config ~alloy:(Some minimal_alloy) ~managed_containers:(Some entries)
      ~user_service:(Some minimal_user_service) ~cron_jobs:None ~version:"1.0.0"
      ()
  in
  let context =
    ctx
      ~orchestrator:(Setup.Orchestrator_running { version = "0.9.0" })
      ~docker_probe:docker_present ()
  in
  let actions = plan config ~specs:(specs_of_entries entries) context in
  let joining = indices_where joins_network actions in
  (* Affirmative arm: without this the ordering assertion below would hold
     vacuously on a plan that starts no containers at all. *)
  check (list string) "plan starts containers"
    [ "RunServer"; "RunAlloy"; "RunManaged gateway" ]
    (actions |> List.filter joins_network |> List.map action_string);
  match indices_where is_ensure_network actions with
  | [ network_index ] ->
      check bool "EnsureNetwork precedes every joining action" true
        (List.for_all (fun index -> network_index < index) joining)
  | [] -> fail "no EnsureNetwork in plan"
  | _ :: _ :: _ -> fail "EnsureNetwork planned more than once"

(* ------------------------------------------------------------------------- *)
(* Managed container convergence                                             *)
(* ------------------------------------------------------------------------- *)

let converge ?(observed_managed = Setup.Managed_observed []) entries =
  let specs = specs_of_entries entries in
  let config =
    make_config ~managed_containers:(Some entries) ~user_service:None
      ~cron_jobs:None ~version:"1.0.0" ()
  in
  let context =
    ctx ~managed:observed_managed
      ~orchestrator:(Setup.Orchestrator_running { version = "1.0.0" })
      ~docker_probe:docker_present ()
  in
  (specs, plan config ~specs context)

let test_managed_absent_plans_run () =
  let _, actions = converge [ managed_entry ~name:"gateway" () ] in
  check_managed_actions
    ~expected:[ "WriteManagedEnv gateway"; "RunManaged gateway" ]
    actions

let test_managed_hash_mismatch_plans_recreate () =
  let entries = [ managed_entry ~name:"gateway" () ] in
  let _, actions =
    converge
      ~observed_managed:(observed [ ("gateway", "a-different-digest") ])
      entries
  in
  check_managed_actions
    ~expected:
      [
        "StopManaged gateway";
        "RemoveManaged gateway";
        "WriteManagedEnv gateway";
        "RunManaged gateway";
      ]
    actions

let test_managed_converged_plans_nothing () =
  let entries = [ managed_entry ~name:"gateway" () ] in
  let specs = specs_of_entries entries in
  let hash = Managed_container.spec_hash (spec_named "gateway" specs) in
  let _, actions =
    converge ~observed_managed:(observed [ ("gateway", hash) ]) entries
  in
  check_managed_actions ~expected:[] actions

(* A container that restarts itself is still observed, because the gather
   lists stopped containers too. Dropping [-a] would make a mid-restart Gateway
   read as absent and get recreated. *)
let test_managed_stopped_container_still_observed () =
  check bool "gather lists stopped containers"
    (Bondi_common.String_utils.contains ~needle:"ps -a" Setup.managed_ps_command)
    true;
  check bool "gather selects by managed label"
    (Bondi_common.String_utils.contains ~needle:"label=bondi.type=managed"
       Setup.managed_ps_command)
    true;
  (* Affirmative arm: the command's output shape really does parse into the
     observed state the plan consumes. *)
  check (list string) "parsed names" [ "gateway" ]
    (match observed [ ("gateway", "digest") ] with
    | Setup.Managed_unobserved message -> fail message
    | Setup.Managed_observed pairs -> List.map fst pairs)

let test_managed_undeclared_plans_removal () =
  let _, actions =
    converge ~observed_managed:(observed [ ("gateway", "digest") ]) []
  in
  check_managed_actions
    ~expected:
      [
        "StopManaged gateway";
        "RemoveManaged gateway";
        "CleanManagedConfig gateway";
      ]
    actions

let test_managed_ignores_unsafe_observed_names () =
  (* The observed name comes from a label Bondi reads but did not necessarily
     write, and withdrawal turns it into an [rm -rf] target. A name [create]
     would have rejected must not reach the plan at all. The safe entry in the
     same output is the affirmative arm: it proves the unsafe ones are dropped
     for being unsafe, not because the parser stopped producing entries. *)
  let _, actions =
    converge
      ~observed_managed:
        (observed
           [
             ("../../root", "digest");
             ("/etc/passwd", "digest");
             (".ssh", "digest");
             ("gateway", "digest");
           ])
      []
  in
  check_managed_actions
    ~expected:
      [
        "StopManaged gateway";
        "RemoveManaged gateway";
        "CleanManagedConfig gateway";
      ]
    actions

let test_managed_ignores_malformed_ps_lines () =
  (* A [--format] change or a tab inside a label value yields a line with the
     wrong field count. Dropping it silently reads as "absent", which plans a
     duplicate run, so the arity arms need their own pin. The well-formed entry
     is the affirmative arm. *)
  let output =
    String.concat "\n"
      [
        "onlyonefield";
        "three\tfields\there";
        "four\tfields\there\ttoo";
        "gateway\tdigest";
        "";
      ]
  in
  let actions =
    match Setup.Managed_observed (Setup.managed_of_ps_output output) with
    | Setup.Managed_unobserved _ -> fail "fixture must be an observation"
    | Setup.Managed_observed _ as managed ->
        let config =
          make_config ~managed_containers:None ~user_service:None
            ~cron_jobs:None ~version:"1.0.0" ()
        in
        plan config
          (ctx ~managed
             ~orchestrator:(Setup.Orchestrator_running { version = "1.0.0" })
             ~docker_probe:docker_present ())
  in
  check_managed_actions
    ~expected:
      [
        "StopManaged gateway";
        "RemoveManaged gateway";
        "CleanManagedConfig gateway";
      ]
    actions

let test_multiple_managed_mixed_states () =
  let entries =
    [ managed_entry ~name:"gateway" (); managed_entry ~name:"relay" () ]
  in
  let specs = specs_of_entries entries in
  let gateway_hash = Managed_container.spec_hash (spec_named "gateway" specs) in
  let _, actions =
    converge
      ~observed_managed:
        (observed [ ("gateway", gateway_hash); ("relay", "stale-digest") ])
      entries
  in
  check_managed_actions
    ~expected:
      [
        "StopManaged relay";
        "RemoveManaged relay";
        "WriteManagedEnv relay";
        "RunManaged relay";
      ]
    actions

(* The plan is pure over already-validated specs, so something must pin that the
   specs it converges are the ones bondi.yaml actually declares. *)
let test_plan_for_config_reads_declared_containers () =
  let config =
    make_config
      ~managed_containers:(Some [ managed_entry ~name:"gateway" () ])
      ~user_service:None ~cron_jobs:None ~version:"1.0.0" ()
  in
  let context =
    ctx
      ~orchestrator:(Setup.Orchestrator_running { version = "1.0.0" })
      ~docker_probe:docker_present ()
  in
  match Setup.plan_for_config config context with
  | Error message -> fail message
  | Ok actions ->
      check_managed_actions
        ~expected:[ "WriteManagedEnv gateway"; "RunManaged gateway" ]
        actions

let test_plan_for_config_surfaces_invalid_declaration () =
  let entry =
    {
      (managed_entry ~name:"gateway" ()) with
      Config_file.restart = "sometimes";
    }
  in
  let config =
    make_config ~managed_containers:(Some [ entry ]) ~user_service:None
      ~cron_jobs:None ~version:"1.0.0" ()
  in
  let context =
    ctx
      ~orchestrator:(Setup.Orchestrator_running { version = "1.0.0" })
      ~docker_probe:docker_present ()
  in
  match Setup.plan_for_config config context with
  | Ok _ -> fail "expected an invalid restart policy to be rejected"
  | Error message ->
      check bool "names the offending value"
        (Bondi_common.String_utils.contains ~needle:"sometimes" message)
        true

(* A failed [docker ps] must not read as "no containers exist": planning against
   it would create containers that are already running. The declared set is what
   makes the difference matter, so the two arms are split on it. *)
let test_plan_for_config_rejects_unobserved_with_declarations () =
  let config =
    make_config
      ~managed_containers:(Some [ managed_entry ~name:"gateway" () ])
      ~user_service:None ~cron_jobs:None ~version:"1.0.0" ()
  in
  let context =
    ctx ~managed:(Setup.Managed_unobserved "connection refused")
      ~orchestrator:(Setup.Orchestrator_running { version = "1.0.0" })
      ~docker_probe:docker_present ()
  in
  match Setup.plan_for_config config context with
  | Ok _ -> fail "expected a failed managed-container lookup to be rejected"
  | Error message ->
      check bool "carries the underlying failure"
        (Bondi_common.String_utils.contains ~needle:"connection refused" message)
        true

let test_plan_for_config_allows_unobserved_without_declarations () =
  let config =
    make_config ~managed_containers:None ~user_service:None ~cron_jobs:None
      ~version:"1.0.0" ()
  in
  let context =
    ctx ~managed:(Setup.Managed_unobserved "connection refused")
      ~orchestrator:(Setup.Orchestrator_running { version = "1.0.0" })
      ~docker_probe:docker_present ()
  in
  match Setup.plan_for_config config context with
  | Error message -> fail message
  | Ok actions -> check_managed_actions ~expected:[] actions

let test_plan_alloy_enabled () =
  let config =
    make_config ~alloy:(Some minimal_alloy) ~user_service:None ~cron_jobs:None
      ~version:"1.0.0" ()
  in
  let context =
    ctx ~orchestrator:Setup.Orchestrator_absent ~docker_probe:docker_present ()
  in
  let actions = plan config context in
  check bool "EnsureAlloyConfig when alloy configured"
    (List.mem Setup.EnsureAlloyConfig actions)
    true;
  check bool "RunAlloy when alloy configured"
    (List.mem Setup.RunAlloy actions)
    true

let test_plan_alloy_disabled () =
  let config =
    make_config ~user_service:None ~cron_jobs:None ~version:"1.0.0" ()
  in
  let context =
    ctx ~orchestrator:Setup.Orchestrator_absent ~docker_probe:docker_present ()
  in
  let actions = plan config context in
  check bool "no EnsureAlloyConfig when alloy not configured"
    (List.mem Setup.EnsureAlloyConfig actions)
    false;
  check bool "no RunAlloy when alloy not configured"
    (List.mem Setup.RunAlloy actions)
    false

let test_plan_alloy_removed () =
  let config =
    make_config ~user_service:None ~cron_jobs:None ~version:"1.0.0" ()
  in
  let context =
    ctx ~alloy_state:Setup.Alloy_present
      ~orchestrator:(Setup.Orchestrator_running { version = "1.0.0" })
      ~docker_probe:docker_present ()
  in
  let actions = plan config context in
  check bool "StopAlloy when alloy removed from config"
    (List.mem Setup.StopAlloy actions)
    true;
  check bool "RemoveAlloy when alloy removed from config"
    (List.mem Setup.RemoveAlloy actions)
    true

(* A declared image does not change the plan: unlike the orchestrator, alloy is
   not compared against a running version — a present container is replaced
   whatever image it came from, so a custom image converges the same way the
   default one does. *)
let test_plan_alloy_declared_image_converges_like_the_default () =
  let alloy_with_custom_image =
    { minimal_alloy with Config_file.image = Some "grafana/alloy:v2.0.0" }
  in
  let config =
    make_config ~alloy:(Some alloy_with_custom_image) ~user_service:None
      ~cron_jobs:None ~version:"1.0.0" ()
  in
  let context =
    ctx ~alloy_state:Setup.Alloy_present
      ~orchestrator:(Setup.Orchestrator_running { version = "1.0.0" })
      ~docker_probe:docker_present ()
  in
  let actions = plan config context in
  check_actions
    ~expected:
      [
        "EnsureDocker";
        "EnsureNetwork " ^ Bondi_common.Defaults.network_name;
        "StopAlloy";
        "RemoveAlloy";
        "EnsureAlloyConfig";
        "WriteAlloyEnv";
        "RunAlloy";
      ]
    actions

let ensure_network_action =
  "EnsureNetwork " ^ Bondi_common.Defaults.network_name

(* The container the plan wants to run already holds the name, so the removal
   has to come first: a removal after the run is the same conflict. The whole
   list is enumerated rather than the two actions being looked for, because a
   plan that also stops what is already stopped is a different plan. *)
let test_plan_alloy_stopped_is_removed_before_running () =
  let config =
    make_config ~alloy:(Some minimal_alloy) ~user_service:None ~cron_jobs:None
      ~version:"1.0.0" ()
  in
  let context =
    ctx
      ~alloy_state:
        (alloy_ps ~state:"exited" ~image:Bondi_common.Defaults.alloy_image)
      ~orchestrator:(Setup.Orchestrator_running { version = "1.0.0" })
      ~docker_probe:docker_present ()
  in
  check_actions
    ~expected:
      [
        "EnsureDocker";
        ensure_network_action;
        "StopAlloy";
        "RemoveAlloy";
        "EnsureAlloyConfig";
        "WriteAlloyEnv";
        "RunAlloy";
      ]
    (plan config context)

(* The affirmative arm of the removal above: with no container on the host there
   is nothing to remove, and planning a removal anyway would fail the run on
   "no such container" — the first setup of a host is exactly this case. *)
let test_plan_alloy_absent_runs_without_removing () =
  let config =
    make_config ~alloy:(Some minimal_alloy) ~user_service:None ~cron_jobs:None
      ~version:"1.0.0" ()
  in
  let context =
    ctx
      ~alloy_state:(Setup.alloy_state_of_ps_output "\n")
      ~orchestrator:(Setup.Orchestrator_running { version = "1.0.0" })
      ~docker_probe:docker_present ()
  in
  check_actions
    ~expected:
      [
        "EnsureDocker";
        ensure_network_action;
        "EnsureAlloyConfig";
        "WriteAlloyEnv";
        "RunAlloy";
      ]
    (plan config context)

(* Withdrawing alloy from the configuration must clear a stopped container too.
   Leaving it behind keeps the name taken, so the wedge would survive the very
   change made to get rid of it. *)
let test_plan_alloy_withdrawn_stopped_is_removed () =
  let config =
    make_config ~user_service:None ~cron_jobs:None ~version:"1.0.0" ()
  in
  let context =
    ctx
      ~alloy_state:
        (alloy_ps ~state:"exited" ~image:Bondi_common.Defaults.alloy_image)
      ~orchestrator:(Setup.Orchestrator_running { version = "1.0.0" })
      ~docker_probe:docker_present ()
  in
  check_actions
    ~expected:
      [ "EnsureDocker"; ensure_network_action; "StopAlloy"; "RemoveAlloy" ]
    (plan config context)

(* The two branches that run alloy, as one fixture per host state so that a
   claim about the plan's shape is made against both rather than against
   whichever one happens to be enumerated. *)
let alloy_run_branch_actions ~alloy_state =
  let config =
    make_config ~alloy:(Some minimal_alloy) ~user_service:None ~cron_jobs:None
      ~version:"1.0.0" ()
  in
  let context =
    ctx ~alloy_state
      ~orchestrator:(Setup.Orchestrator_running { version = "1.0.0" })
      ~docker_probe:docker_present ()
  in
  plan config context

(* Where an action sits in a plan. A duplicate is its own failure rather than a
   position: an action planned twice runs twice, and comparing the first
   occurrence would report an ordering that holds for one of them. *)
let index_of action actions =
  match indices_where (fun candidate -> candidate = action) actions with
  | [ index ] -> index
  | [] -> fail (action_string action ^ " was not planned")
  | _ :: _ :: _ -> fail (action_string action ^ " was planned more than once")

(* The credentials file is written after the configuration that names the
   variables it supplies and before the container that reads them, in both
   branches that run alloy. A file written after the run is a container started
   against credentials that are not on the host yet.

   Stated as a relation rather than by re-enumerating the plan, which the two
   cases above already do. An enumerated list is repaired by pasting in whatever
   the plan now emits, so a change that quietly stopped writing the credentials
   would be accepted there; it is not accepted here. *)
let test_alloy_env_is_planned_before_the_run () =
  List.iter
    (fun (label, alloy_state) ->
      let actions = alloy_run_branch_actions ~alloy_state in
      let config_at = index_of Setup.EnsureAlloyConfig actions in
      let env_at = index_of Setup.WriteAlloyEnv actions in
      let run_at = index_of Setup.RunAlloy actions in
      check bool
        (label ^ ": credentials written after the config that names them")
        true (config_at < env_at);
      check bool
        (label ^ ": credentials written before the container that reads them")
        true (env_at < run_at))
    [
      ( "a stopped container",
        alloy_ps ~state:"exited" ~image:Bondi_common.Defaults.alloy_image );
      ("no container", Setup.alloy_state_of_ps_output "\n");
    ]

(* Withdrawing alloy from the configuration takes the credentials off the host
   with it. Nothing new is planned for that: [RemoveAlloy] already deletes the
   config directory whole, and the credentials file lives inside it -- which is
   the relation this test pins. A later move of the file to a sibling path would
   leave a withdrawn credential on disk with every other alloy test still
   green. *)
let test_withdrawn_alloy_still_removes_the_config_directory () =
  let config =
    make_config ~user_service:None ~cron_jobs:None ~version:"1.0.0" ()
  in
  let context =
    ctx
      ~alloy_state:
        (alloy_ps ~state:"exited" ~image:Bondi_common.Defaults.alloy_image)
      ~orchestrator:(Setup.Orchestrator_running { version = "1.0.0" })
      ~docker_probe:docker_present ()
  in
  let actions = plan config context in
  check bool "the removal that carries the credentials off is planned"
    (List.mem Setup.RemoveAlloy actions)
    true;
  check bool "no credentials are written for an alloy nothing declares"
    (List.mem Setup.WriteAlloyEnv actions)
    false;
  check bool
    (Setup.alloy_env_path ^ " is inside the directory the removal deletes")
    true
    (Bondi_common.String_utils.starts_with
       ~prefix:(Setup.alloy_config_dir ^ "/")
       Setup.alloy_env_path)

(* The credentials also have to go when there is no container left to observe.
   A bondi-alloy removed by any route other than bondi -- a hand-run [docker
   rm], a prune, a rebuilt daemon -- leaves the env file behind and the listing
   empty, so a removal planned from the listing plans nothing and the key stays
   on the host for as long as the box lives. What says alloy is withdrawn is the
   configuration, not the listing, and this is the arm that plans against it. *)
let test_withdrawn_alloy_removes_the_directory_with_no_container_observed () =
  let config =
    make_config ~user_service:None ~cron_jobs:None ~version:"1.0.0" ()
  in
  let context =
    ctx
      ~alloy_state:(Setup.alloy_state_of_ps_output "\n")
      ~orchestrator:(Setup.Orchestrator_running { version = "1.0.0" })
      ~docker_probe:docker_present ()
  in
  check_actions
    ~expected:[ "EnsureDocker"; ensure_network_action; "CleanAlloyConfig" ]
    (plan config context)

(* A listing that never ran is not a host that has no alloy container: the probe
   failed, and a removal issued over the same connection fails with it -- which
   would stop the run before the phases below it, on a host that never declared
   alloy at all. So the unknown stays tolerated here and the directory goes on
   the next run that reads the listing. The affirmative arm is the case above:
   the same config and the same fixture with the listing answered, which does
   plan the removal, so this emptiness is caused by the unread listing rather
   than by a fixture that stopped reaching the alloy branch. *)
let test_withdrawn_alloy_plans_nothing_against_a_listing_that_never_ran () =
  let config =
    make_config ~user_service:None ~cron_jobs:None ~version:"1.0.0" ()
  in
  let context =
    ctx
      ~alloy_state:(Setup.alloy_state_of_probe alloy_unreachable)
      ~orchestrator:(Setup.Orchestrator_running { version = "1.0.0" })
      ~docker_probe:docker_present ()
  in
  check_actions
    ~expected:[ "EnsureDocker"; ensure_network_action ]
    (plan config context)

(* ------------------------------------------------------------------------- *)
(* Container listings that never ran                                          *)
(* ------------------------------------------------------------------------- *)

(* Every case below is the same fixture with one probe result changed, so a
   difference in outcome can only come from the reading under test. *)
let plan_with_probes ?alloy ~orchestrator_probe ~alloy_probe () =
  let config =
    make_config ?alloy ~user_service:None ~cron_jobs:None ~version:"1.0.0" ()
  in
  let context =
    ctx
      ~orchestrator:(Setup.orchestrator_state_of_probe orchestrator_probe)
      ~alloy_state:(Setup.alloy_state_of_probe alloy_probe)
      ~docker_probe:docker_present ()
  in
  Setup.plan_for_config config context

(* Read as an absence, an unread orchestrator listing plans a [docker run]
   against a name that may already be taken, and the transport error the client
   saw never reaches the operator at all. Each probe aborts naming itself: a
   single "a probe failed" would leave the operator guessing which one. *)
let test_plan_for_config_aborts_on_undetermined_orchestrator () =
  match
    plan_with_probes ~orchestrator_probe:orchestrator_unreachable
      ~alloy_probe:(Ok "\n") ()
  with
  | Ok actions ->
      fail
        ("expected an unread orchestrator listing to be rejected, planned: "
        ^ String.concat ", " (List.map action_string actions))
  | Error message ->
      check bool "names the listing that failed"
        (Bondi_common.String_utils.contains ~needle:"bondi-orchestrator" message)
        true;
      check bool "carries the probe's own text"
        (Bondi_common.String_utils.contains ~needle:transport_error message)
        true

let test_plan_for_config_aborts_on_undetermined_alloy () =
  match
    plan_with_probes ~alloy:(Some minimal_alloy)
      ~orchestrator_probe:orchestrator_probe_running
      ~alloy_probe:alloy_unreachable ()
  with
  | Ok actions ->
      fail
        ("expected an unread alloy listing to be rejected, planned: "
        ^ String.concat ", " (List.map action_string actions))
  | Error message ->
      check bool "names the listing that failed"
        (Bondi_common.String_utils.contains ~needle:"bondi-alloy" message)
        true;
      check bool "carries the probe's own text"
        (Bondi_common.String_utils.contains ~needle:transport_error message)
        true

(* An alloy the configuration does not declare converges to nothing whether the
   listing answered or not, so refusing to plan at all would block the phases
   after it — the managed containers among them — over a reading nothing was
   going to be planned from. This is the refinement [Managed_unobserved] already
   makes: an unobservable listing only matters when something is declared
   against it. *)
let test_plan_for_config_allows_undetermined_alloy_without_declaration () =
  match
    plan_with_probes ~orchestrator_probe:orchestrator_probe_running
      ~alloy_probe:alloy_unreachable ()
  with
  | Error message -> fail message
  | Ok actions ->
      check_actions
        ~expected:
          [
            "EnsureDocker";
            ensure_network_action;
            "StopOrchestrator";
            "RemoveOrchestrator";
            "RunServer";
          ]
        actions

(* The affirmative arm of both aborts: the identical fixture with listings that
   answered plans the run. Without it the two refusals above would hold for a
   [plan_for_config] that had stopped planning anything at all. *)
let test_plan_for_config_proceeds_when_probes_succeed () =
  match
    plan_with_probes ~alloy:(Some minimal_alloy)
      ~orchestrator_probe:orchestrator_probe_running
      ~alloy_probe:alloy_probe_stopped ()
  with
  | Error message -> fail message
  | Ok actions ->
      check_actions
        ~expected:
          [
            "EnsureDocker";
            ensure_network_action;
            "StopOrchestrator";
            "RemoveOrchestrator";
            "RunServer";
            "StopAlloy";
            "RemoveAlloy";
            "EnsureAlloyConfig";
            "WriteAlloyEnv";
            "RunAlloy";
          ]
        actions

let test_excluded_containers_no_service () =
  let config =
    make_config ~user_service:None ~cron_jobs:None ~version:"1.0.0" ()
  in
  check (list string) "empty when no service" []
    (Setup.excluded_containers_from_config config)

let test_excluded_containers_logs_true () =
  let service = { minimal_user_service with Config_file.logs = Some true } in
  let config =
    make_config ~user_service:(Some service) ~cron_jobs:None ~version:"1.0.0" ()
  in
  check (list string) "empty when logs=true" []
    (Setup.excluded_containers_from_config config)

let test_excluded_containers_logs_none () =
  let config =
    make_config ~user_service:(Some minimal_user_service) ~cron_jobs:None
      ~version:"1.0.0" ()
  in
  check (list string) "empty when logs=None" []
    (Setup.excluded_containers_from_config config)

let test_excluded_containers_logs_false () =
  let service = { minimal_user_service with Config_file.logs = Some false } in
  let config =
    make_config ~user_service:(Some service) ~cron_jobs:None ~version:"1.0.0" ()
  in
  check (list string) "service name when logs=false" [ "my-service" ]
    (Setup.excluded_containers_from_config config)

let test_alloy_river_config_defaults () =
  let config =
    make_config ~user_service:None ~cron_jobs:None ~version:"1.0.0" ()
  in
  let river = Setup.alloy_river_config config minimal_alloy in
  check string "endpoint" "https://logs-prod.grafana.net/loki/api/v1/push"
    river.grafana_cloud_endpoint;
  check string "instance_id" "123456" river.grafana_cloud_instance_id;
  check string "api_key" "glc_secret" river.grafana_cloud_api_key;
  check bool "collect defaults to All" true
    (river.collect = Bondi_common.Alloy_river.All);
  check (list (pair string string)) "labels default to empty" [] river.labels;
  check (list string) "excluded_containers empty" [] river.excluded_containers

let test_alloy_river_config_services_only () =
  let alloy =
    { minimal_alloy with Config_file.collect = Some "services_only" }
  in
  let config =
    make_config ~user_service:None ~cron_jobs:None ~version:"1.0.0" ()
  in
  let river = Setup.alloy_river_config config alloy in
  check bool "collect is Services_only" true
    (river.collect = Bondi_common.Alloy_river.Services_only)

let test_alloy_river_config_with_labels () =
  let alloy =
    {
      minimal_alloy with
      Config_file.labels = Some [ ("env", "prod"); ("team", "platform") ];
    }
  in
  let config =
    make_config ~user_service:None ~cron_jobs:None ~version:"1.0.0" ()
  in
  let river = Setup.alloy_river_config config alloy in
  check
    (list (pair string string))
    "labels passed through"
    [ ("env", "prod"); ("team", "platform") ]
    river.labels

let test_alloy_river_config_excludes_service () =
  let service = { minimal_user_service with Config_file.logs = Some false } in
  let config =
    make_config ~user_service:(Some service) ~cron_jobs:None ~version:"1.0.0" ()
  in
  let river = Setup.alloy_river_config config minimal_alloy in
  check (list string) "excluded service name" [ "my-service" ]
    river.excluded_containers

let test_plan_alloy_already_running () =
  let config =
    make_config ~alloy:(Some minimal_alloy) ~user_service:None ~cron_jobs:None
      ~version:"1.0.0" ()
  in
  let context =
    ctx ~alloy_state:Setup.Alloy_present
      ~orchestrator:(Setup.Orchestrator_running { version = "1.0.0" })
      ~docker_probe:docker_present ()
  in
  let actions = plan config context in
  check bool "StopAlloy to converge config"
    (List.mem Setup.StopAlloy actions)
    true;
  check bool "RemoveAlloy to converge config"
    (List.mem Setup.RemoveAlloy actions)
    true;
  check bool "EnsureAlloyConfig to converge config"
    (List.mem Setup.EnsureAlloyConfig actions)
    true;
  check bool "RunAlloy to converge config"
    (List.mem Setup.RunAlloy actions)
    true

(* Addressed at 192.0.2.1, which RFC 5737 reserves as unroutable: were the
   stub on PATH ever to stop being resolved, the operator's own ssh would run,
   spend its connect timeout and report 255, and the case below would fail
   loudly rather than pass against nothing. *)
let unroutable_server : Config_file.server =
  {
    ip_address = "192.0.2.1";
    ssh =
      Some
        { user = "deploy"; private_key_contents = "KEY"; private_key_pass = "" };
    port = None;
  }

(* The private key's time on disk is a decision per server rather than per
   remote call. A `bondi setup` run against one box is the client's longest
   sequence of remote calls by a wide margin -- the readings, every step the
   plan interprets, and the restart-policy convergence after it -- so it is the
   run where staging a key with each call costs the most and leaves the most
   windows in which one is on disk.

   Driven through [setup_server], the function [run] maps over the server list,
   because that is where the lifetime is decided; asserting it of any one of the
   three functions below it would leave the other two free to stage their own.

   Both numbers are asserted. "One distinct path" is also what a run that made
   no calls at all reports, and the stub records nothing when it is never
   spawned, so the count of invocations is what proves this fixture reaches the
   calls it is counting. The count is asserted as a floor rather than an exact
   number: what this case is about is how many keys served them, and pinning the
   exact number of commands a setup run issues would make every change to the
   plan a failure here. *)
let test_a_servers_setup_run_stages_the_key_once () =
  let outcome, staged =
    Client_fixtures.staged_keys_during (fun () ->
        Setup.setup_server (Client_fixtures.mk_config ()) unroutable_server)
  in
  (* The run's own verdict is asserted rather than discarded. A stub that
     answers every command with silence is not a host this run can converge,
     and a run that reported [Ok] against one would have stopped believing what
     it read -- which would make the counts below a count of a different run
     from the one this case is about. *)
  check bool "the run reported what it could not converge" true
    (Result.is_error outcome);
  check bool "the run made more than one remote call" true
    (List.length staged > 1);
  check int "over one staged key" 1
    (List.length (List.sort_uniq String.compare staged))

(* The report [setup] ends on is taken after the run and over its own
   connections: the four reads of a reading, the orchestrator's own two, and a
   bounded wait for every container the inspection says has a check to answer
   for. Those reads stay independent of what [setup_server] decided -- a read
   that failed is a cell in the report and never an early return -- but
   independence is a fact about what a read may change, not about how many
   times key material reaches disk, and the latter is the whole of what the
   session is for.

   Two stagings is the whole of what one server's run may cost: one for the
   convergence and one for the report after it. The report's is a second
   session on purpose, because the run's is closed before the report is taken
   -- that is what lets a run which stopped part-way still be reported on.

   Both numbers are asserted, for the reason the case above gives: "two
   distinct paths" is also true of a report whose reads never ran. *)
let test_a_servers_report_shares_one_staged_key () =
  let outcome, staged =
    Client_fixtures.staged_keys_during (fun () ->
        Setup.setup_and_report
          ~fetch:(fun ?session server ->
            Status_cmd.orchestrator_reading ?session ~service_name:None server)
          (Client_fixtures.mk_config ())
          unroutable_server)
  in
  check bool "the run reported what it could not converge" true
    (Result.is_error outcome.Setup.converged);
  check bool "the run and the report made more than two remote calls" true
    (List.length staged > 2);
  check int "over one staged key for the run and one for the report" 2
    (List.length (List.sort_uniq String.compare staged))

(* A stub that answers every command by exiting zero and saying nothing, which
   is what a host reports for a container it does not hold. It is the same
   answer for both cases below, so what separates them is whether the phase
   asked at all: a phase that read the policy reports that it could not be
   read, and a phase that skipped the reading reports nothing. Without that
   asymmetry the [Ok] case would be green against a phase which had stopped
   reading entirely, which is the whole of what these two cases are about.

   The stub drains its standard input before exiting: the runner writes the
   command there, and a stub that exits without reading leaves the writer
   holding a closed pipe. *)
let silent_ssh_stub = "#!/bin/sh\ncat > /dev/null\nexit 0\n"

(* The `--restart` flag on the `docker run` this tool issues is a request. What
   the daemon applied is only ever visible from an inspect -- which is the same
   reasoning the convergence itself already rests on, where three containers
   created with the flag were found at `no` on a live box. So the run that
   creates the container is not exempt from the reading; it is the run whose
   policy nobody has ever inspected, and it used to be the only run that never
   asked. *)
let test_restart_policy_converges_where_docker_was_not_installed () =
  Client_fixtures.with_ssh_stub silent_ssh_stub (fun () ->
      match
        Setup.converge_restart_policy unroutable_server
          ~docker_status:
            (Setup.Docker_not_installed "bash: docker: command not found")
      with
      | Ok () ->
          Alcotest.fail
            "the run that installed Docker returned without reading the \
             orchestrator's restart policy"
      | Error message ->
          check bool "the failure names the reading that was taken" true
            (contains ~needle:"restart policy" message))

(* A Docker state nobody could read is not a state to act on. An inspect issued
   here would be issued against a host whose version probe never answered, so
   it would fail on the transport and report that as a policy the run could not
   converge -- a second failure describing the first one badly. The case above
   shares this fixture and does report a failure, so this [Ok] is the reading
   being skipped rather than the phase having stopped reading altogether. *)
let test_restart_policy_is_not_read_where_docker_was_undetermined () =
  Client_fixtures.with_ssh_stub silent_ssh_stub (fun () ->
      match
        Setup.converge_restart_policy unroutable_server
          ~docker_status:(Setup.Docker_undetermined "connection timed out")
      with
      | Ok () -> ()
      | Error message ->
          Alcotest.fail
            (Printf.sprintf
               "a Docker state that could not be read was acted on anyway: %s"
               message))

let () =
  run "Setup.plan"
    [
      ( "EnsureDocker",
        [
          test_case "always included" `Quick
            test_plan_always_includes_ensure_docker;
        ] );
      ( "docker observation",
        [
          test_case "a failed probe is undetermined" `Quick
            test_docker_probe_error_is_undetermined;
          test_case "command not found is a positive absence" `Quick
            test_docker_probe_command_not_found_is_not_installed;
          test_case "a version string is an installed Docker" `Quick
            test_docker_probe_version_output_is_installed;
          test_case "absence is the exit status, not the wording" `Quick
            test_docker_probe_absence_is_the_exit_status_not_the_wording;
          test_case "a transport failure saying not found is undetermined"
            `Quick
            test_docker_probe_transport_failure_that_says_not_found_is_undetermined;
          test_case "plan_for_config aborts on an undetermined probe" `Quick
            test_plan_for_config_aborts_on_undetermined_docker;
          test_case "the abort names the transport error" `Quick
            test_plan_for_config_abort_names_the_transport_error;
          test_case "an absent Docker is still installed" `Quick
            test_plan_for_config_still_installs_when_docker_is_absent;
        ] );
      ( "docker install verdict",
        [
          test_case "a failed probe is a failure, not an install" `Quick
            test_ensure_docker_probe_error_is_a_failure_not_an_install;
          test_case "installs only when Docker is absent" `Quick
            test_ensure_docker_verdict_installs_only_when_absent;
          test_case "satisfied when Docker is installed" `Quick
            test_ensure_docker_verdict_is_satisfied_when_installed;
        ] );
      ( "ACME",
        [
          test_case "skipped when no user_service" `Quick
            test_plan_no_user_service_skips_acme;
          test_case "included when user_service present" `Quick
            test_plan_with_user_service_includes_acme;
          test_case "skipped when cron-only" `Quick test_plan_cron_only_no_acme;
        ] );
      ( "server",
        [
          test_case "skips when up-to-date and no cron" `Quick
            test_plan_skip_server_when_up_to_date;
          test_case "runs on fresh install" `Quick
            test_plan_fresh_install_runs_server;
          test_case "stops and runs on version mismatch" `Quick
            test_plan_version_mismatch_stops_and_runs;
          test_case "restarts when adding cron jobs" `Quick
            test_plan_cron_jobs_force_restart;
          test_case "removes an exited orchestrator before running" `Quick
            test_plan_exited_orchestrator_is_removed_before_running;
          test_case "removes a running orchestrator after stopping it" `Quick
            test_plan_running_orchestrator_is_removed_after_stopping;
          test_case "the preserve copy precedes the orchestrator recreate"
            `Quick test_plan_preserve_precedes_the_orchestrator_recreate;
          test_case "no preserve action for a box without a section" `Quick
            test_plan_no_preserve_without_a_section;
          test_case "the preserve copy precedes a stopped container's recreate"
            `Quick test_plan_preserve_precedes_a_stopped_orchestrator_recreate;
          test_case "a crontab that could not be understood is still copied out"
            `Quick test_plan_preserve_for_a_crontab_that_could_not_be_understood;
          test_case "a held section mounts the payload directory" `Quick
            test_run_command_mounts_the_payload_directory_for_a_held_section;
          test_case "no payload mount without a section or a declared job"
            `Quick test_run_command_omits_the_payload_mount_without_cron;
          test_case "the reading asks about cron wherever the run converges it"
            `Quick
            test_the_reading_asks_about_cron_wherever_the_run_converges_it;
        ] );
      ( "orchestrator observation",
        [
          test_case "an exited container is not read as running" `Quick
            test_exited_orchestrator_is_not_read_as_running;
          test_case "a running container reports its version" `Quick
            test_running_orchestrator_reports_its_version;
          test_case "a running container from another image reports it" `Quick
            test_running_orchestrator_from_another_image_reports_the_image;
          test_case "no container is absent" `Quick
            test_no_orchestrator_container_is_absent;
          test_case "created, restarting, paused and dead are not serving"
            `Quick test_non_running_states_are_not_serving;
          test_case "a failed listing is undetermined" `Quick
            test_orchestrator_probe_error_is_undetermined;
        ] );
      ( "probe aborts",
        [
          test_case "an unread orchestrator listing is rejected" `Quick
            test_plan_for_config_aborts_on_undetermined_orchestrator;
          test_case "an unread alloy listing is rejected" `Quick
            test_plan_for_config_aborts_on_undetermined_alloy;
          test_case "an unread alloy listing with no alloy declared proceeds"
            `Quick
            test_plan_for_config_allows_undetermined_alloy_without_declaration;
          test_case "listings that answered are planned from" `Quick
            test_plan_for_config_proceeds_when_probes_succeed;
        ] );
      ("order", [ test_case "action order" `Quick test_plan_action_order ]);
      ( "cron docker",
        [
          test_case "required when cron jobs are declared" `Quick
            test_plan_requires_cron_docker_when_cron_jobs_declared;
          test_case "omitted without cron jobs" `Quick
            test_plan_omits_cron_docker_check_without_cron_jobs;
          test_case "a failed probe is not an absent docker" `Quick
            test_cron_docker_probe_error_is_not_an_absent_docker;
          test_case "resolved and unresolved are told apart" `Quick
            test_cron_docker_probe_reports_what_the_host_resolved;
          test_case "an answer with no marker is undetermined" `Quick
            test_cron_docker_probe_without_a_marker_is_undetermined;
          test_case "the command asks cron's question" `Quick
            test_cron_docker_probe_command_clears_the_environment;
        ] );
      ( "cron curl",
        [
          test_case "required when cron jobs are declared" `Quick
            test_plan_requires_curl_when_cron_jobs_declared;
          test_case "omitted without cron jobs" `Quick
            test_plan_omits_curl_check_without_cron_jobs;
          test_case "a failed probe is not curl's answer" `Quick
            test_cron_curl_probe_error_is_not_curls_answer;
          test_case "what the host said about curl is" `Quick
            test_cron_curl_host_answers_are_curls_answer;
          test_case "absence is the exit status, not the wording" `Quick
            test_cron_curl_absence_is_the_exit_status_not_the_wording;
          test_case "a transport failure saying not found is undetermined"
            `Quick
            test_cron_curl_transport_failure_that_says_not_found_is_undetermined;
        ] );
      ( "acme probe",
        [
          test_case "a failed probe is not an absent file" `Quick
            test_acme_probe_error_is_not_an_absent_file;
          test_case "present and absent are told apart" `Quick
            test_acme_probe_reports_what_the_host_said;
          test_case "an answer with no marker is undetermined" `Quick
            test_acme_probe_without_a_marker_is_undetermined;
          test_case "the command asks for both answers" `Quick
            test_acme_probe_command_asks_for_both_answers;
        ] );
      ( "orchestrator readiness",
        [
          test_case "the phase waits for running and then reads once" `Quick
            test_the_orchestrator_phase_waits_for_running_then_reads_once;
          test_case "the log stream is read after the reading, not before"
            `Quick test_the_log_stream_is_read_after_the_reading_not_before;
          test_case "each reading collapses to go on or stop with a sentence"
            `Quick test_each_reading_collapses_to_go_on_or_stop_with_a_sentence;
          test_case "an image below the command-surface floor is refused" `Quick
            test_an_image_below_the_command_surface_floor_is_refused;
          test_case "an image at the floor still runs the server" `Quick
            test_an_image_at_the_command_surface_floor_still_runs_the_server;
          test_case
            "a rejected reading reports the account and the skipped phases"
            `Quick
            test_a_rejected_reading_reports_the_account_and_the_phases_left_unrun;
        ] );
      ( "network",
        [
          test_case "planned for the shared network" `Quick
            test_setup_plans_ensure_network;
          test_case "precedes joining actions" `Quick
            test_setup_plan_ensure_network_precedes_joining_actions;
        ] );
      ( "managed",
        [
          test_case "absent plans run" `Quick test_managed_absent_plans_run;
          test_case "hash mismatch plans recreate" `Quick
            test_managed_hash_mismatch_plans_recreate;
          test_case "converged plans nothing" `Quick
            test_managed_converged_plans_nothing;
          test_case "stopped container still observed" `Quick
            test_managed_stopped_container_still_observed;
          test_case "undeclared plans removal" `Quick
            test_managed_undeclared_plans_removal;
          test_case "ignores unsafe observed names" `Quick
            test_managed_ignores_unsafe_observed_names;
          test_case "ignores malformed ps lines" `Quick
            test_managed_ignores_malformed_ps_lines;
          test_case "multiple mixed states" `Quick
            test_multiple_managed_mixed_states;
          test_case "plan_for_config reads declared containers" `Quick
            test_plan_for_config_reads_declared_containers;
          test_case "plan_for_config surfaces an invalid declaration" `Quick
            test_plan_for_config_surfaces_invalid_declaration;
          test_case "plan_for_config rejects an unobserved lookup" `Quick
            test_plan_for_config_rejects_unobserved_with_declarations;
          test_case "plan_for_config allows unobserved with no declarations"
            `Quick test_plan_for_config_allows_unobserved_without_declarations;
        ] );
      ( "alloy",
        [
          test_case "enabled" `Quick test_plan_alloy_enabled;
          test_case "disabled" `Quick test_plan_alloy_disabled;
          test_case "removed" `Quick test_plan_alloy_removed;
          test_case "a declared image converges like the default" `Quick
            test_plan_alloy_declared_image_converges_like_the_default;
          test_case "already running converges" `Quick
            test_plan_alloy_already_running;
          test_case "a stopped container is removed before running" `Quick
            test_plan_alloy_stopped_is_removed_before_running;
          test_case "an absent container runs without removing" `Quick
            test_plan_alloy_absent_runs_without_removing;
          test_case "withdrawal removes a stopped container" `Quick
            test_plan_alloy_withdrawn_stopped_is_removed;
          test_case "the credentials file is written before the run" `Quick
            test_alloy_env_is_planned_before_the_run;
          test_case "withdrawal removes the directory holding the credentials"
            `Quick test_withdrawn_alloy_still_removes_the_config_directory;
          test_case "withdrawal removes the directory with no container seen"
            `Quick
            test_withdrawn_alloy_removes_the_directory_with_no_container_observed;
          test_case "withdrawal plans nothing against an unread listing" `Quick
            test_withdrawn_alloy_plans_nothing_against_a_listing_that_never_ran;
        ] );
      ( "alloy observation",
        [
          test_case "a stopped container is present, not absent" `Quick
            test_alloy_stopped_container_is_present_not_absent;
          test_case "a running container is present" `Quick
            test_alloy_running_container_is_present;
          test_case "no container is absent" `Quick
            test_alloy_no_container_is_absent;
          test_case "a failed listing is undetermined" `Quick
            test_alloy_probe_error_is_undetermined;
        ] );
      ( "excluded_containers_from_config",
        [
          test_case "no service" `Quick test_excluded_containers_no_service;
          test_case "logs=true" `Quick test_excluded_containers_logs_true;
          test_case "logs=None" `Quick test_excluded_containers_logs_none;
          test_case "logs=false" `Quick test_excluded_containers_logs_false;
        ] );
      ( "a server's run",
        [
          test_case "a server's setup run stages the key once" `Quick
            test_a_servers_setup_run_stages_the_key_once;
          test_case "a server's report shares one staged key" `Quick
            test_a_servers_report_shares_one_staged_key;
        ] );
      ( "restart policy",
        [
          test_case
            "the restart policy converges on a host where Docker was not \
             installed"
            `Quick test_restart_policy_converges_where_docker_was_not_installed;
          test_case "a Docker state that could not be read is not acted on"
            `Quick test_restart_policy_is_not_read_where_docker_was_undetermined;
        ] );
      ( "alloy_river_config",
        [
          test_case "defaults" `Quick test_alloy_river_config_defaults;
          test_case "services_only collect" `Quick
            test_alloy_river_config_services_only;
          test_case "with labels" `Quick test_alloy_river_config_with_labels;
          test_case "excludes service with logs=false" `Quick
            test_alloy_river_config_excludes_service;
        ] );
    ]
