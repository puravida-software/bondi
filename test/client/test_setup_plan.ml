open Alcotest
module Config_file = Bondi_client.Config_file
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
  | Setup.RunServer -> "RunServer"
  | Setup.EnsureAlloyConfig -> "EnsureAlloyConfig"
  | Setup.RunAlloy -> "RunAlloy"
  | Setup.StopAlloy -> "StopAlloy"
  | Setup.RemoveAlloy -> "RemoveAlloy"
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
  | Setup.RunServer
  | Setup.EnsureAlloyConfig
  | Setup.RunAlloy
  | Setup.StopAlloy
  | Setup.RemoveAlloy
  | Setup.WriteManagedEnv _
  | Setup.RunManaged _
  | Setup.StopManaged _
  | Setup.RemoveManaged _
  | Setup.CleanManagedConfig _ ->
      false

(* An action that starts a container on the shared network. EnsureNetwork must
   precede every one of these (FR-8). *)
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
  | Setup.EnsureAlloyConfig
  | Setup.StopAlloy
  | Setup.RemoveAlloy
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
  | Setup.RunServer
  | Setup.EnsureAlloyConfig
  | Setup.RunAlloy
  | Setup.StopAlloy
  | Setup.RemoveAlloy ->
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
    Config_file.bondi_server = { Config_file.version };
    Config_file.traefik = None;
    Config_file.cron_jobs;
    Config_file.alloy;
    managed_containers;
  }

let ctx ?(alloy_state = Setup.Alloy_not_running)
    ?(managed = Setup.Managed_observed []) ~running_version ~docker_installed
    ~acme_exists () =
  {
    Setup.docker_status =
      (if docker_installed then `Installed "Docker version 24.0"
       else `NotInstalled "command not found");
    Setup.acme_file_exists = acme_exists;
    Setup.running_version;
    Setup.alloy_state;
    Setup.managed;
  }

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

let test_plan_always_includes_ensure_docker () =
  let config =
    make_config ~user_service:None ~cron_jobs:None ~version:"1.0.0" ()
  in
  let context =
    ctx ~running_version:None ~docker_installed:true ~acme_exists:false ()
  in
  let actions = plan config context in
  check bool "EnsureDocker is first" (List.hd actions = Setup.EnsureDocker) true

let test_plan_no_user_service_skips_acme () =
  let config =
    make_config ~user_service:None ~cron_jobs:None ~version:"1.0.0" ()
  in
  let context =
    ctx ~running_version:None ~docker_installed:true ~acme_exists:false ()
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
    ctx ~running_version:None ~docker_installed:true ~acme_exists:false ()
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
    ctx ~running_version:(Some "1.0.0") ~docker_installed:true
      ~acme_exists:false ()
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
    ctx ~running_version:None ~docker_installed:true ~acme_exists:false ()
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
    ctx ~running_version:(Some "0.9.0") ~docker_installed:true
      ~acme_exists:false ()
  in
  let actions = plan config context in
  check bool "StopOrchestrator on version mismatch"
    (List.mem Setup.StopOrchestrator actions)
    true;
  check bool "RunServer after version mismatch"
    (List.mem Setup.RunServer actions)
    true

let test_plan_cron_jobs_force_restart () =
  let cron_job =
    {
      Config_file.name = "backup";
      Config_file.image = "backup:v1";
      Config_file.schedule = "0 0 * * *";
      Config_file.network = None;
      Config_file.env_vars = None;
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
    ctx ~running_version:(Some "1.0.0") ~docker_installed:true
      ~acme_exists:false ()
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
    ctx ~running_version:(Some "0.9.0") ~docker_installed:true
      ~acme_exists:false ()
  in
  let actions = plan config context in
  check_actions
    ~expected:
      [
        "EnsureDocker";
        "EnsureNetwork bondi-network";
        "EnsureAcmeFile";
        "StopOrchestrator";
        "RunServer";
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
    ctx ~running_version:None ~docker_installed:true ~acme_exists:false ()
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
    ctx ~running_version:None ~docker_installed:true ~acme_exists:false ()
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
    ctx ~running_version:None ~docker_installed:true ~acme_exists:true ()
  in
  check bool "no curl requirement without cron jobs"
    (List.mem Setup.RequireCronCurl (plan config context))
    false

let test_setup_plans_ensure_network () =
  let config =
    make_config ~user_service:None ~cron_jobs:None ~version:"1.0.0" ()
  in
  let context =
    ctx ~running_version:None ~docker_installed:true ~acme_exists:false ()
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
    ctx ~running_version:(Some "0.9.0") ~docker_installed:true
      ~acme_exists:false ()
  in
  let actions = plan config ~specs:(specs_of_entries entries) context in
  let joining = indices_where joins_network actions in
  (* Affirmative arm: without this the ordering assertion below would hold
     vacuously on a plan that starts no containers at all. *)
  check (list string) "plan starts containers"
    [ "RunServer"; "RunAlloy"; "RunManaged gateway" ]
    (List.map (fun index -> action_string (List.nth actions index)) joining);
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
    ctx ~managed:observed_managed ~running_version:(Some "1.0.0")
      ~docker_installed:true ~acme_exists:false ()
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

(* FR-5: a container that restarts itself is still observed, because the gather
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
          (ctx ~managed ~running_version:(Some "1.0.0") ~docker_installed:true
             ~acme_exists:false ())
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
    ctx ~running_version:(Some "1.0.0") ~docker_installed:true
      ~acme_exists:false ()
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
    ctx ~running_version:(Some "1.0.0") ~docker_installed:true
      ~acme_exists:false ()
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
      ~running_version:(Some "1.0.0") ~docker_installed:true ~acme_exists:false
      ()
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
      ~running_version:(Some "1.0.0") ~docker_installed:true ~acme_exists:false
      ()
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
    ctx ~running_version:None ~docker_installed:true ~acme_exists:false ()
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
    ctx ~running_version:None ~docker_installed:true ~acme_exists:false ()
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
    ctx
      ~alloy_state:
        (Setup.Alloy_running { image = Bondi_common.Defaults.alloy_image })
      ~running_version:(Some "1.0.0") ~docker_installed:true ~acme_exists:false
      ()
  in
  let actions = plan config context in
  check bool "StopAlloy when alloy removed from config"
    (List.mem Setup.StopAlloy actions)
    true;
  check bool "RemoveAlloy when alloy removed from config"
    (List.mem Setup.RemoveAlloy actions)
    true

let test_plan_alloy_version_change () =
  let alloy_with_custom_image =
    { minimal_alloy with Config_file.image = Some "grafana/alloy:v2.0.0" }
  in
  let config =
    make_config ~alloy:(Some alloy_with_custom_image) ~user_service:None
      ~cron_jobs:None ~version:"1.0.0" ()
  in
  let context =
    ctx
      ~alloy_state:(Setup.Alloy_running { image = "grafana/alloy:v1.8.0" })
      ~running_version:(Some "1.0.0") ~docker_installed:true ~acme_exists:false
      ()
  in
  let actions = plan config context in
  check bool "StopAlloy on version change"
    (List.mem Setup.StopAlloy actions)
    true;
  check bool "RemoveAlloy on version change"
    (List.mem Setup.RemoveAlloy actions)
    true;
  check bool "EnsureAlloyConfig on version change"
    (List.mem Setup.EnsureAlloyConfig actions)
    true;
  check bool "RunAlloy on version change" (List.mem Setup.RunAlloy actions) true

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
  let desired_image =
    Option.value minimal_alloy.image ~default:Bondi_common.Defaults.alloy_image
  in
  let context =
    ctx
      ~alloy_state:(Setup.Alloy_running { image = desired_image })
      ~running_version:(Some "1.0.0") ~docker_installed:true ~acme_exists:false
      ()
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
        ] );
      ("order", [ test_case "action order" `Quick test_plan_action_order ]);
      ( "cron curl",
        [
          test_case "required when cron jobs are declared" `Quick
            test_plan_requires_curl_when_cron_jobs_declared;
          test_case "omitted without cron jobs" `Quick
            test_plan_omits_curl_check_without_cron_jobs;
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
          test_case "version change" `Quick test_plan_alloy_version_change;
          test_case "already running converges" `Quick
            test_plan_alloy_already_running;
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
