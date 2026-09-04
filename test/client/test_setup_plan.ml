open Alcotest
module Config_file = Bondi_client.Config_file
module Remote_exec = Bondi_client.Remote_exec
module Managed_container = Bondi_common.Managed_container
module Setup = Bondi_client.Cmd.Setup

(* Production always passes the declared specs; the existing tests predate them
   and are about the non-managed parts of the plan. *)
let plan ?(specs = []) config context = Setup.plan config ~specs context

let action_string = function
  | Setup.EnsureDocker -> "EnsureDocker"
  | Setup.EnsureAcmeFile -> "EnsureAcmeFile"
  | Setup.EnsureNetwork name -> "EnsureNetwork " ^ name
  | Setup.RequireCronCurl -> "RequireCronCurl"
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
  | Setup.RequireCronCurl
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
  | Setup.RequireCronCurl
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
  | Setup.RequireCronCurl
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
let ctx ?(alloy_state = Setup.Alloy_absent)
    ?(managed = Setup.Managed_observed []) ~orchestrator ~docker_probe () =
  {
    Setup.docker_status = Setup.docker_status_of_probe docker_probe;
    Setup.orchestrator;
    Setup.alloy_state;
    Setup.managed;
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
   status, which is why these carry the failure rather than its rendering.
   [docker_missing_merged] is the same absence from a transport that folds
   stderr into stdout and exits zero. *)
let docker_present = Ok "Docker version 24.0"

let docker_missing =
  Error
    (Remote_exec.Command_failed
       { code = 127; output = "bash: docker: command not found\n" })

let docker_missing_merged = Ok "bash: docker: command not found"
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
          "command failed (255): Connection closed by 203.0.113.9 port 22"))
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
         "command failed (255): Connection closed by 203.0.113.9 port 22")
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

(* A transport that folds stderr into stdout and exits zero reports the same
   absence on the success channel. Both spellings are the host answering. *)
let test_docker_probe_command_not_found_on_stdout_is_not_installed () =
  check_docker_status
    ~expected:(Setup.Docker_not_installed "bash: docker: command not found")
    docker_missing_merged

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
         "command failed (255): sh: line 1: jump-helper: command not found")
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

(* The crontab line uses --fail-with-body, so setup checks the host's curl
   before the orchestrator starts. That check reads a version string, and a
   probe that never ran has no version string in it. Folding the transport's own
   error into curl's output told the operator that the host had reported
   "command failed (255): Connection closed by …" but 7.76.0 is required — a
   failure to ask, dressed up as a fact about curl. *)
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
        "RequireCronCurl";
        "RunServer";
        "CleanAlloyConfig";
      ]
    actions

(* The crontab command the orchestrator writes uses --fail-with-body, which an
   older curl rejects as an unknown option. Verifying the host's curl at setup
   turns that into one loud failure here rather than every scheduled job
   failing at its next tick. The check precedes RunServer, so an unusable host
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
          test_case "command not found on stdout is a positive absence" `Quick
            test_docker_probe_command_not_found_on_stdout_is_not_installed;
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
