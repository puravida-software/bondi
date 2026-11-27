module Deploy = Bondi_server__Deploy
module Handler_error = Bondi_server__Handler_error
module Docker = Bondi_server__Docker__Client
module Simple = Bondi_server__Strategy__Simple
module Proxy = Bondi_server__Proxy
module Crontab = Bondi_server__Crontab
module Run = Bondi_server__Run
module Payload_codec = Bondi_server__Payload_codec
module Alert = Bondi_common.Alert
module Client_deploy = Bondi_client.Cmd.Deploy
module Client_config = Bondi_client.Config_file

let minimal_input =
  {
    Simple.service_name = Some (Test_helpers.router_name "my-service");
    image = Some (Test_helpers.image_reference "myapp:v1");
    port = Some 8080;
    registry_user = None;
    registry_pass = None;
    env_vars = None;
    traefik_domain_name = Some "example.com";
    traefik_image = Some (Test_helpers.image_reference "traefik:v3.3.0");
    traefik_acme_email = Some "admin@example.com";
    traefik_acme_ca_server = None;
    force_traefik_redeploy = None;
    cron_jobs = None;
    drain_grace_period = None;
    deployment_strategy = None;
    health_timeout = None;
    poll_interval = None;
    logs = None;
    volumes = None;
  }

(* The action carries no name, so the one network it may ever create is printed
   from the same constant the planner compares against. *)
let action_string = function
  | Deploy.EnsureCronNetwork ->
      "EnsureCronNetwork(" ^ Bondi_common.Defaults.network_name ^ ")"
  | Deploy.UpsertCrontab jobs -> (
      match jobs with
      | None -> "UpsertCrontab(None)"
      | Some jobs -> "UpsertCrontab(" ^ string_of_int (List.length jobs) ^ ")")
  | Deploy.UpdateRestartPolicy { container_id; restart_policy } ->
      "UpdateRestartPolicy(" ^ container_id ^ "," ^ restart_policy.Docker.name
      ^ ")"

(* The plan helpers below that take no [~managed_containers] plan for a box
   holding no managed container, said here once rather than at every call. *)
let planned_actions_on ~managed_containers ~context input =
  match Deploy.cron_plan ~managed_containers ~box_services:[] input with
  | Error err ->
      Alcotest.fail
        (context ^ ": cron_plan failed: " ^ Handler_error.message err)
  | Ok actions -> List.map action_string actions

let planned_actions ~context input =
  planned_actions_on ~managed_containers:[] ~context input

(* The names UpsertCrontab carries, which is what the interpreter writes both
   files from. action_string reports only how many there are, and a plan that
   dropped one job and kept another of the same count would read as correct. *)
let upsert_job_names ~context input =
  match Deploy.cron_plan ~managed_containers:[] ~box_services:[] input with
  | Error err ->
      Alcotest.fail
        (context ^ ": cron_plan failed: " ^ Handler_error.message err)
  | Ok actions ->
      List.concat_map
        (fun action ->
          match action with
          | Deploy.UpsertCrontab (Some jobs) ->
              List.map (fun (job : Simple.cron_job) -> job.name) jobs
          | Deploy.UpsertCrontab None
          | Deploy.EnsureCronNetwork
          | Deploy.UpdateRestartPolicy _ ->
              [])
        actions

let plan_error_on ~managed_containers ~context input =
  match Deploy.cron_plan ~managed_containers ~box_services:[] input with
  | Ok actions ->
      Alcotest.fail
        (Printf.sprintf "%s: expected an error, planned [%s]" context
           (String.concat "; " (List.map action_string actions)))
  | Error err -> err

let plan_error ~context input =
  plan_error_on ~managed_containers:[] ~context input

let result_testable ok_t =
  Alcotest.testable
    (fun fmt r ->
      match r with
      | Ok v -> Fmt.pf fmt "Ok(%a)" (Alcotest.pp ok_t) v
      | Error msg -> Fmt.pf fmt "Error(%s)" msg)
    (fun a b ->
      match (a, b) with
      | Ok a, Ok b -> Alcotest.equal ok_t a b
      | Error a, Error b -> String.equal a b
      | Ok _, Error _
      | Error _, Ok _ ->
          false)

(* The AuthConfig a registry auth header carries, decoded back from the header
   the engine is handed, read with the base64url alphabet the header is
   written in. *)
let auth_config_of_header header =
  match Base64.decode ~pad:true ~alphabet:Base64.uri_safe_alphabet header with
  | Ok json -> Yojson.Safe.from_string json
  | Error (`Msg msg) -> Alcotest.failf "the header is not base64url: %s" msg

let field name json =
  match Yojson.Safe.Util.member name json with
  | `String value -> value
  | other ->
      Alcotest.failf "AuthConfig field %s is not a string: %s" name
        (Yojson.Safe.to_string other)

(* The registry is read from the reference, so a registry behind a port is
   named with its port, where splitting the text at its first colon finds no
   registry at all and sends no credentials. A reference that names no registry
   still sends none, and neither does a reference with half a credential. *)
let test_registry_auth_serveraddress_from_reference () =
  let auth ?(user = Some "deployer") ?(pass = Some "s3cret") image =
    Deploy.registry_auth (Test_helpers.image_reference image) ~user ~pass
  in
  (match auth "registry:5000/app:1.2.3" with
  | None ->
      Alcotest.fail "credentials for a registry behind a port must be sent"
  | Some header ->
      let config = auth_config_of_header header in
      Alcotest.(check string)
        "serveraddress is the registry, port included" "registry:5000"
        (field "serveraddress" config);
      Alcotest.(check string)
        "the credentials are the ones declared" "deployer"
        (field "username" config));
  (match auth "registry.gitlab.com/org/repo:v1.2.3" with
  | None -> Alcotest.fail "credentials for a named registry must be sent"
  | Some header ->
      Alcotest.(check string)
        "serveraddress is the registry host" "registry.gitlab.com"
        (field "serveraddress" (auth_config_of_header header)));
  (* A reference that names no registry but has a namespace keeps what earlier
     releases sent: the credentials, with the first path component as
     serveraddress, so the Engine is handed them for the Docker Hub pull exactly
     as before. A single-component name never sent any, and still sends
     none. *)
  let namespace_serveraddress image =
    match auth image with
    | None ->
        Alcotest.fail
          (image
         ^ ": credentials for a namespaced Docker Hub image must be sent")
    | Some header -> field "serveraddress" (auth_config_of_header header)
  in
  Alcotest.(check string)
    "a namespace/name image sends the namespace as serveraddress" "myorg"
    (namespace_serveraddress "myorg/app:1.2.3");
  Alcotest.(check string)
    "a deeper path sends its first component" "myorg"
    (namespace_serveraddress "myorg/team/app:1.2.3");
  Alcotest.(check string)
    "a digest-pinned namespaced image sends its first component" "old"
    (namespace_serveraddress ("old/worker@sha256:" ^ String.make 64 'a'));
  Alcotest.(check (option string))
    "a single-component image sends no credentials" None (auth "nginx:1.27");
  Alcotest.(check (option string))
    "an untagged single-component image sends no credentials" None
    (auth "nginx");
  Alcotest.(check (option string))
    "no password, no credentials" None
    (auth ~pass:None "registry:5000/app:1.2.3");
  Alcotest.(check (option string))
    "no user, no credentials, for a namespaced image too" None
    (auth ~user:None "myorg/app:1.2.3")

(* The Engine API reads X-Registry-Auth as base64url-encoded JSON. A password
   is chosen whose standard encoding carries both characters the two alphabets
   disagree on: the '~' of "abc~" encodes to '+', and the '?' encodes to '/'.
   The expected header is Python's encoding of the same JSON, padding kept,
   produced by:

   python3 -c 'import base64; print(base64.urlsafe_b64encode(b"{\"serveraddress\":\"registry:5000\",\"username\":\"use\",\"password\":\"abc~ab?\"}").decode())' *)
let test_registry_auth_base64url () =
  let json =
    {|{"serveraddress":"registry:5000","username":"use","password":"abc~ab?"}|}
  in
  let standard =
    Base64.encode_string ~pad:true ~alphabet:Base64.default_alphabet json
  in
  Alcotest.(check bool)
    "the fixture's standard encoding carries a '+'" true
    (String.contains standard '+');
  Alcotest.(check bool)
    "the fixture's standard encoding carries a '/'" true
    (String.contains standard '/');
  match
    Deploy.registry_auth
      (Test_helpers.image_reference "registry:5000/app:1.2.3")
      ~user:(Some "use") ~pass:(Some "abc~ab?")
  with
  | None -> Alcotest.fail "credentials for a registry behind a port are sent"
  | Some header ->
      Alcotest.(check string)
        "the header is the base64url encoding Python gives for the same JSON"
        "eyJzZXJ2ZXJhZGRyZXNzIjoicmVnaXN0cnk6NTAwMCIsInVzZXJuYW1lIjoidXNlIiwicGFzc3dvcmQiOiJhYmN-YWI_In0="
        header;
      Alcotest.(check bool)
        "the header carries no '+'" false
        (String.contains header '+');
      Alcotest.(check bool)
        "the header carries no '/'" false
        (String.contains header '/')

let test_tag_from_image () =
  Alcotest.check Alcotest.string "extracts tag" "v1.2.3"
    (Deploy.tag_from_image
       (Test_helpers.image_reference "registry.example.com/app:v1.2.3"));
  Alcotest.check Alcotest.string "unknown when no tag" "unknown"
    (Deploy.tag_from_image
       (Test_helpers.image_reference "registry.example.com/app"))

(* A digest pins the image as exactly as a tag does, so it is pulled by its
   digest rather than refused; only an image naming neither is refused. The
   repository and the [tag] query are what the pull sends for the reference
   that passes. *)
let test_require_tag_or_digest () =
  let name_and_tag image =
    Payload_codec.require_tag_or_digest (Test_helpers.image_reference image)
    |> Result.map (fun pinned ->
        ( Bondi_common.Image_reference.name pinned,
          Bondi_common.Image_reference.pull_tag pinned ))
  in
  let digest = "sha256:" ^ String.make 64 'a' in
  Alcotest.check
    (result_testable (Alcotest.pair Alcotest.string Alcotest.string))
    "name and tag"
    (Ok ("backup", "v1"))
    (name_and_tag "backup:v1");
  Alcotest.check
    (result_testable (Alcotest.pair Alcotest.string Alcotest.string))
    "a registry behind a port stays in the name"
    (Ok ("registry:5000/backup", "v1"))
    (name_and_tag "registry:5000/backup:v1");
  Alcotest.check
    (result_testable (Alcotest.pair Alcotest.string Alcotest.string))
    "a digest-pinned image is pulled by its digest"
    (Ok ("old/worker", digest))
    (name_and_tag ("old/worker@" ^ digest));
  match name_and_tag "backup" with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "expected error for missing tag"

let test_build_response () =
  let input =
    {
      minimal_input with
      image = Some (Test_helpers.image_reference "app:v2.0");
    }
  in
  let response =
    Deploy.build_response ~strategy:Deploy.Simple
      ~strategy_reason:"image has no HEALTHCHECK" input
  in
  Alcotest.check Alcotest.string "status" "Deploy initiated" response.status;
  Alcotest.check Alcotest.string "tag" "v2.0" response.tag;
  Alcotest.check Alcotest.string "strategy" "simple" response.strategy;
  Alcotest.check Alcotest.string "strategy_reason" "image has no HEALTHCHECK"
    response.strategy_reason

(* One builder for every cron-plan network arm, so the three arms differ in the
   declared network and nothing else. *)
let cron_job_on_network ~name ~network : Simple.cron_job =
  {
    name;
    image = Test_helpers.image_reference "backup:v1";
    schedule = Test_helpers.cron_schedule "0 0 * * *";
    network;
    env_vars = None;
    secret_env_vars = None;
    registry_user = None;
    registry_pass = None;
    alert_sinks = None;
    exit_code_severities = None;
  }

let test_cron_plan_empty_cron_jobs () =
  let input = { minimal_input with cron_jobs = Some [] } in
  Alcotest.check
    (Alcotest.list Alcotest.string)
    "no cron actions when cron_jobs is empty" []
    (planned_actions ~context:"empty cron jobs" input)

let test_cron_plan_with_cron_jobs () =
  let cron = cron_job_on_network ~name:"backup" ~network:None in
  let input = { minimal_input with cron_jobs = Some [ cron ] } in
  Alcotest.check
    (Alcotest.list Alcotest.string)
    "plans the crontab write and no pull" [ "UpsertCrontab(1)" ]
    (planned_actions ~context:"one cron job" input)

(* A job declaring the network Bondi owns gets it ensured on the deploy path,
   because a deploy cannot assume setup has run. The ensure precedes the pull so
   the network exists before anything can reference it. *)
let test_cron_plan_ensures_shared_network () =
  let cron =
    cron_job_on_network ~name:"backup"
      ~network:(Some Bondi_common.Defaults.network_name)
  in
  let input = { minimal_input with cron_jobs = Some [ cron ] } in
  Alcotest.check
    (Alcotest.list Alcotest.string)
    "ensures the shared network before pulling"
    [ "EnsureCronNetwork(bondi-network)"; "UpsertCrontab(1)" ]
    (planned_actions ~context:"job on the shared network" input);
  (* The ensure is idempotent and there is only one name it can carry, so two
     jobs declaring it plan one action, not two. *)
  let two_jobs =
    {
      minimal_input with
      cron_jobs =
        Some
          [
            cron;
            cron_job_on_network ~name:"report"
              ~network:(Some Bondi_common.Defaults.network_name);
          ];
    }
  in
  Alcotest.check
    (Alcotest.list Alcotest.string)
    "two jobs on the shared network ensure it once"
    [ "EnsureCronNetwork(bondi-network)"; "UpsertCrontab(2)" ]
    (planned_actions ~context:"two jobs on the shared network" two_jobs)

(* Creating a typo'd network would hand the job an empty network it cannot reach
   anything through — the silent failure this feature removes.

   The check is over the declared name alone, against a constant accepted set,
   so every remedy the message offers must be one the operator can apply in
   bondi.yaml. Creating the network with Docker is not such a remedy: this
   function receives only the cron jobs, so a network created out of band stays
   invisible to it and the next deploy fails identically. *)
let test_cron_plan_rejects_unknown_network () =
  let cron =
    cron_job_on_network ~name:"backup" ~network:(Some "bondi-netwrok")
  in
  let input = { minimal_input with cron_jobs = Some [ cron ] } in
  let msg =
    Handler_error.message
      (plan_error ~context:"job on an unmanaged network" input)
  in
  Alcotest.check Alcotest.bool
    ("error names the declared network: " ^ msg)
    true
    (Bondi_common.String_utils.contains ~needle:"bondi-netwrok" msg);
  (* The affirmative arm for the negative check below: the one accepted value is
     named, so "no docker remedy" cannot pass by naming no remedy at all. *)
  Alcotest.check Alcotest.bool
    ("error names the network bondi accepts: " ^ msg)
    true
    (Bondi_common.String_utils.contains
       ~needle:Bondi_common.Defaults.network_name msg);
  Alcotest.check Alcotest.bool
    ("error prescribes no docker-level remedy it cannot observe: " ^ msg)
    false
    (Bondi_common.String_utils.contains ~needle:"docker network create" msg)

(* The whole declared set is in hand and the check is pure, so reporting only
   the first offender would make the operator rediscover the next bad name on
   the next deploy. Each offending job is named alongside the network it
   declared, so a two-job message is not ambiguous about which is which. *)
let test_cron_plan_rejects_every_unknown_network () =
  let input =
    {
      minimal_input with
      cron_jobs =
        Some
          [
            cron_job_on_network ~name:"backup" ~network:(Some "bondi-netwrok");
            cron_job_on_network ~name:"report" ~network:(Some "reporting-net");
          ];
    }
  in
  let msg =
    Handler_error.message
      (plan_error ~context:"two jobs on unmanaged networks" input)
  in
  List.iter
    (fun needle ->
      Alcotest.check Alcotest.bool
        (Printf.sprintf "error names %s: %s" needle msg)
        true
        (Bondi_common.String_utils.contains ~needle msg))
    [ "backup"; "bondi-netwrok"; "report"; "reporting-net" ]

(* A network name bondi does not manage is a value the operator wrote, so the
   failure is classified as the caller's mistake rather than as a bondi fault.
   The exit code is where an operator meets that classification, so it is what
   the classification is asserted through. This is the classification the
   sibling run command already uses. *)
let test_deploy_exit_code_for_invalid_request () =
  let cron =
    cron_job_on_network ~name:"backup" ~network:(Some "bondi-netwrok")
  in
  let input = { minimal_input with cron_jobs = Some [ cron ] } in
  let err = plan_error ~context:"job on an unmanaged network" input in
  Alcotest.check Alcotest.int "declared-network rejection exits 2" 2
    (Handler_error.exit_code err)

(* The affirmative arm for the test above: without it, a classifier that called
   every failure the caller's mistake would pass. *)
let test_deploy_exit_code_for_orchestrator_failure () =
  Alcotest.check Alcotest.int "an orchestrator fault exits 1" 1
    (Handler_error.exit_code
       (Handler_error.Orchestrator_failure "docker daemon unreachable"))

(* The affirmative arm above with the network field removed — a job declaring
   none plans exactly what it planned before the network check existed. *)
let test_cron_plan_without_network_unchanged () =
  let cron = cron_job_on_network ~name:"backup" ~network:None in
  let input = { minimal_input with cron_jobs = Some [ cron ] } in
  Alcotest.check
    (Alcotest.list Alcotest.string)
    "no network action for a job declaring none" [ "UpsertCrontab(1)" ]
    (planned_actions ~context:"job declaring no network" input)

(* The job's name is interpolated into the path of the run file the crontab line
   reads and into the path Cron_secrets writes beside it, so a name carrying a
   separator or a leading dot could name its way out of its own directory. The
   refusal belongs in the plan: deploy.mli says the cron plan is the one step
   that may answer Invalid_request, and the interpreter that writes those files
   carries no check of its own.

   The accepted job in the same request is the affirmative arm — a message that
   named every job would pass a "names the offender" check while telling the
   operator nothing about which one to fix. *)
let test_cron_plan_refuses_an_unsafe_job_name () =
  let input =
    {
      minimal_input with
      cron_jobs =
        Some
          [
            cron_job_on_network ~name:"../etc/backup" ~network:None;
            cron_job_on_network ~name:"report" ~network:None;
          ];
    }
  in
  let err = plan_error ~context:"a job named out of its directory" input in
  Alcotest.check Alcotest.int "an unsafe job name exits 2" 2
    (Handler_error.exit_code err);
  let msg = Handler_error.message err in
  (* The exact sentence the client prints for the same names: both read it from
     Bondi_common.Cron_job_name. *)
  Alcotest.check Alcotest.string "the sentence is the client's"
    "cron job names must be safe to place in a file path (\"../etc/backup\"). \
     A name must begin with a letter or a digit and may hold only letters, \
     digits, '.', '_' and '-': rename these jobs in bondi.yaml"
    msg;
  Alcotest.check Alcotest.bool
    ("error names the offending job: " ^ msg)
    true
    (Bondi_common.String_utils.contains ~needle:"../etc/backup" msg);
  Alcotest.check Alcotest.bool
    ("error does not name the job it accepts: " ^ msg)
    false
    (Bondi_common.String_utils.contains ~needle:"report" msg)

(* Every declared job reaches the action that writes the crontab and the run
   files, in the order it was declared. The check added above is a refusal, not
   a filter: a plan that dropped the jobs it did not like would leave the box
   firing a section that does not match what was deployed, and it would do so
   silently. The names here sit on the boundary of what Cron_secrets.is_valid_name
   accepts — a dot, a hyphen, a digit — so a check that is stricter than the one
   guarding the path fails this rather than passing unnoticed. *)
let test_cron_plan_upsert_carries_every_declared_job () =
  let declared = [ "db.backup-2"; "report"; "cleanup9" ] in
  let input =
    {
      minimal_input with
      cron_jobs =
        Some
          (List.map
             (fun name -> cron_job_on_network ~name ~network:None)
             declared);
    }
  in
  Alcotest.check
    (Alcotest.list Alcotest.string)
    "every declared job reaches UpsertCrontab, in order" declared
    (upsert_job_names ~context:"three declared jobs" input)

(* --- Cron job names already in use, and secret entries --- *)

let contains needle haystack =
  Bondi_common.String_utils.contains ~needle haystack

let cron_jobs_named names =
  List.map (fun name -> cron_job_on_network ~name ~network:None) names

let web_input jobs =
  {
    minimal_input with
    service_name = Some (Test_helpers.router_name "web");
    cron_jobs = Some jobs;
  }

(* A refusal the caller can fix in bondi.yaml, whose message carries every
   fragment in [expected]. *)
let check_refused_naming ~context ~managed_containers ~expected input =
  let err = plan_error_on ~managed_containers ~context input in
  Alcotest.check Alcotest.int
    (context ^ ": a name already in use exits 2")
    2
    (Handler_error.exit_code err);
  let msg = Handler_error.message err in
  List.iter
    (fun fragment ->
      Alcotest.check Alcotest.bool
        (Printf.sprintf "%s: the message names %s: %s" context fragment msg)
        true (contains fragment msg))
    expected

(* One payload per class of holder, each naming the job and what holds its
   name, then all of them at once, in one message. The service is [web]; the
   expected fragments are written from the names Bondi runs its containers
   under, not read from the module that reserves them. *)
let test_cron_plan_refuses_collision_per_holder () =
  let cases =
    [
      ("the service", [ "web" ], [ {|cron job "web"|}; {|service "web"|} ]);
      ( "the blue-green candidate",
        [ "web-new" ],
        [ {|cron job "web-new"|}; {|candidate "web-new"|} ] );
      ( "the orchestrator",
        [ "bondi-orchestrator" ],
        [
          {|cron job "bondi-orchestrator"|};
          {|built-in container "bondi-orchestrator"|};
        ] );
      ( "Traefik",
        [ "bondi-traefik" ],
        [ {|cron job "bondi-traefik"|}; {|built-in container "bondi-traefik"|} ]
      );
      ( "Alloy",
        [ "bondi-alloy" ],
        [ {|cron job "bondi-alloy"|}; {|built-in container "bondi-alloy"|} ] );
      ( "a duplicate pair",
        [ "report"; "report" ],
        [ {|cron job "report"|}; {|another cron job "report"|} ] );
    ]
  in
  List.iter
    (fun (context, jobs, expected) ->
      check_refused_naming ~context ~managed_containers:[] ~expected
        (web_input (cron_jobs_named jobs)))
    cases;
  check_refused_naming ~context:"every clash at once" ~managed_containers:[]
    ~expected:(List.concat_map (fun (_, _, expected) -> expected) cases)
    (web_input
       (cron_jobs_named (List.concat_map (fun (_, jobs, _) -> jobs) cases)));
  (* The same service with jobs that only resemble its names plans the write:
     the refusals above are made on the name, not on the fixture. *)
  Alcotest.check
    (Alcotest.list Alcotest.string)
    "names that only resemble a holder are accepted" [ "UpsertCrontab(3)" ]
    (planned_actions ~context:"near misses"
       (web_input (cron_jobs_named [ "web-old"; "bondi-web"; "report" ])))

(* The deploy payload carries no managed containers, so the orchestrator learns
   them from the box. The same payload is accepted on a box holding none and
   refused on a box holding [bondi-db]: the clash is found only through what
   the box reports, never through the client. *)
let test_cron_plan_managed_clash_only_from_box () =
  let input = web_input (cron_jobs_named [ "bondi-db" ]) in
  Alcotest.check
    (Alcotest.list Alcotest.string)
    "a box with no managed container accepts the job" [ "UpsertCrontab(1)" ]
    (planned_actions_on ~managed_containers:[] ~context:"no managed container"
       input);
  check_refused_naming ~context:"the box holds bondi-db"
    ~managed_containers:[ "bondi-db" ]
    ~expected:[ {|cron job "bondi-db"|}; {|managed container "bondi-db"|} ]
    input

(* The listing names containers with a leading [/], and only the label marks a
   managed container: a cron run's container and an unlabelled one hold names
   too, but a cron job's own container is its to replace, and an unlabelled one
   is not Bondi's to reserve. *)
let test_managed_container_names_reads_labels () =
  let containers =
    [
      Server_test_helpers.mk_container ~id:"m1" ~image:"postgres:16"
        ~names:[ "/bondi-db" ]
        ~labels:(Some [ ("bondi.type", "managed"); ("bondi.name", "db") ])
        ();
      Server_test_helpers.mk_container ~id:"c1" ~image:"backup:v1"
        ~names:[ "/backup" ]
        ~labels:(Some [ ("bondi.type", "cron"); ("bondi.name", "backup") ])
        ();
      Server_test_helpers.mk_container ~id:"u1" ~image:"nginx:1"
        ~names:[ "/stray" ] ~labels:None ();
    ]
  in
  Alcotest.check
    (Alcotest.list Alcotest.string)
    "only the managed container, without its leading slash" [ "bondi-db" ]
    (Deploy.managed_container_names containers)

(* The service container carries [bondi.type=service] and [bondi.name]; the
   blue-green candidate is the same container under a temporary name, so the
   label gives the service for both. A managed container, a cron run's container
   and an unlabelled one are not the service, and a name that is no router name
   is not one either. *)
let test_service_names_of_reads_labels () =
  let labelled ~id ~names labels =
    Server_test_helpers.mk_container ~id ~image:"img:1" ~names
      ~labels:(Some labels) ()
  in
  let containers =
    [
      labelled ~id:"s1" ~names:[ "/orders" ]
        [ ("bondi.type", "service"); ("bondi.name", "orders") ];
      labelled ~id:"s2" ~names:[ "/billing-new" ]
        [ ("bondi.type", "service"); ("bondi.name", "billing") ];
      labelled ~id:"m1" ~names:[ "/bondi-db" ]
        [ ("bondi.type", "managed"); ("bondi.name", "db") ];
      labelled ~id:"c1" ~names:[ "/backup" ]
        [ ("bondi.type", "cron"); ("bondi.name", "backup") ];
      labelled ~id:"s3" ~names:[ "/Bad_Name" ]
        [ ("bondi.type", "service"); ("bondi.name", "Bad_Name") ];
      labelled ~id:"s4" ~names:[ "/noname" ] [ ("bondi.type", "service") ];
      Server_test_helpers.mk_container ~id:"u1" ~image:"nginx:1"
        ~names:[ "/stray" ] ~labels:None ();
    ]
  in
  Alcotest.check
    (Alcotest.list Alcotest.string)
    "only the service containers, by their bondi.name" [ "orders"; "billing" ]
    (List.map Bondi_common.Router_name.to_string
       (Deploy.service_names_of containers))

(* A cron-only deploy carries no service_name, so the client cannot have told
   the orchestrator which names the service holds. The payload below is the raw
   JSON of such a request, decoded and planned: the service on the box is read
   from the listing, and a job named after it or its candidate is refused. *)
let test_cron_plan_cron_only_payload_sees_box_service () =
  let body_of job =
    Printf.sprintf
      {|{"cron_jobs":[{"name":%S,"image":"nightly:v1","schedule":"0 0 * * *"}]}|}
      job
  in
  let plan job ~box_services =
    match Deploy.decode_input (body_of job) with
    | Error e ->
        Alcotest.failf "the cron-only payload was refused at decode: %s"
          (Handler_error.message e)
    | Ok (input : Simple.deploy_input) ->
        Alcotest.check
          (Alcotest.option Alcotest.string)
          "the payload carries no service name" None
          (Option.map Bondi_common.Router_name.to_string input.service_name);
        Deploy.cron_plan ~managed_containers:[] ~box_services input
  in
  let box_services = [ Test_helpers.router_name "orders" ] in
  let refused ~expected job =
    match plan job ~box_services with
    | Ok _ -> Alcotest.failf "job %s was planned on a box holding orders" job
    | Error err ->
        Alcotest.check Alcotest.string "the refusal, exactly" expected
          (Handler_error.message err)
  in
  refused
    ~expected:
      "cron jobs cannot take names already in use (cron job \"orders\" cannot \
       take that name: the service \"orders\" already runs under it, and a \
       cron job's container is named after the job): rename these jobs in \
       bondi.yaml"
    "orders";
  refused
    ~expected:
      "cron jobs cannot take names already in use (cron job \"orders-new\" \
       cannot take that name: the service's blue-green candidate \
       \"orders-new\" already runs under it, and a cron job's container is \
       named after the job): rename these jobs in bondi.yaml"
    "orders-new";
  match plan "nightly" ~box_services with
  | Ok actions ->
      Alcotest.check
        (Alcotest.list Alcotest.string)
        "a job named after nothing on the box is planned" [ "UpsertCrontab(1)" ]
        (List.filter
           (fun a ->
             a
             <> "EnsureCronNetwork(" ^ Bondi_common.Defaults.network_name ^ ")")
           (List.map action_string actions))
  | Error err ->
      Alcotest.failf "a free name was refused: %s" (Handler_error.message err)

(* A secret value is written as one line of the job's env file, so a newline in
   it is a second entry: [a\nB=c] would hand the job a [B] it never declared.
   The entry is refused naming the job and the key. The refusal's error type has
   no slot for the value, so the absence checks below pin the message's shape;
   the exact naming checks are what show the right entries were refused. *)
let test_cron_plan_refuses_secret_control_character () =
  let job ~name secrets =
    { (cron_job_on_network ~name ~network:None) with secret_env_vars = secrets }
  in
  let probe = "a\nB=c" in
  let input =
    web_input
      [
        job ~name:"backup" (Some [ ("K", probe); ("OK", "x=y") ]);
        job ~name:"report" (Some [ ("BAD=KEY", "v") ]);
        job ~name:"cleanup" None;
      ]
  in
  let err = plan_error ~context:"a newline in a secret value" input in
  Alcotest.check Alcotest.int "a bad secret entry exits 2" 2
    (Handler_error.exit_code err);
  let msg = Handler_error.message err in
  List.iter
    (fun fragment ->
      Alcotest.check Alcotest.bool
        (Printf.sprintf "the message names %s: %s" fragment msg)
        true (contains fragment msg))
    [ {|"backup"|}; {|"K"|}; {|"report"|}; {|"BAD=KEY"|} ];
  List.iter
    (fun fragment ->
      Alcotest.check Alcotest.bool
        (Printf.sprintf "the message does not carry %S: %s" fragment msg)
        false (contains fragment msg))
    [ probe; "B=c"; {|"OK"|}; {|"cleanup"|} ];
  (* The same jobs with entries the env file can hold are planned. *)
  Alcotest.check
    (Alcotest.list Alcotest.string)
    "entries without a control character are accepted" [ "UpsertCrontab(3)" ]
    (planned_actions ~context:"clean secrets"
       (web_input
          [
            job ~name:"backup" (Some [ ("K", "a=B=c"); ("OK", "x=y") ]);
            job ~name:"report" (Some [ ("KEY", "") ]);
            job ~name:"cleanup" None;
          ]))

module Gen = QCheck2.Gen

(* Names over a three-letter alphabet, so random names clash often. Each is a
   router name and safe in a path, so a clash is the only refusal a generated
   payload can meet. *)
let small_name =
  Gen.string_size ~gen:(Gen.oneof_list [ 'a'; 'b'; '0' ]) (Gen.int_range 2 3)

let builtin_names = [ "bondi-orchestrator"; "bondi-traefik"; "bondi-alloy" ]

let names_payload =
  let open Gen in
  let* service = option small_name in
  let* managed =
    list_size (int_range 0 3) (map (fun n -> "bondi-" ^ n) small_name)
  in
  let seeded =
    List.concat
      [
        builtin_names;
        (match service with
        | None -> []
        | Some s -> [ s; s ^ "-new" ]);
        managed;
      ]
  in
  let+ jobs =
    list_size (int_range 0 6) (oneof [ oneof_list seeded; small_name ])
  in
  (service, managed, jobs)

let print_names_payload (service, managed, jobs) =
  let strings xs = String.concat "; " (List.map (Printf.sprintf "%S") xs) in
  Printf.sprintf "service=%s managed=[%s] jobs=[%s]"
    (match service with
    | None -> "None"
    | Some s -> Printf.sprintf "%S" s)
    (strings managed) (strings jobs)

(* Written from the rule, without Cron_job_name: no two jobs share a name, and
   no job takes a built-in name, the service's, its candidate's or a managed
   container's. *)
let names_free ~service ~managed jobs =
  let taken =
    List.concat
      [
        builtin_names;
        (match service with
        | None -> []
        | Some s -> [ s; s ^ "-new" ]);
        managed;
      ]
  in
  let rec distinct = function
    | [] -> true
    | job :: rest -> (not (List.mem job rest)) && distinct rest
  in
  distinct jobs && List.for_all (fun job -> not (List.mem job taken)) jobs

(* [small_name] is in the router-name grammar and is not a reserved router
   name, so the refusal cannot happen. *)
let generated_router_name s =
  match Bondi_common.Router_name.of_string ~field:"service" s with
  | Ok r -> r
  | Error e ->
      Alcotest.failf "generator: unreachable — small_name is valid: %s" e

(* Whenever the plan accepts, the names are free by the oracle. The converse is
   checked too, so a plan that refused every payload would fail rather than
   pass vacuously. *)
let prop_accepted_payload_names_unique =
  QCheck_alcotest.to_alcotest ~speed_level:`Quick
    (QCheck2.Test.make ~count:2000
       ~name:"an accepted payload's cron names are unique and free"
       ~print:print_names_payload names_payload (fun (service, managed, jobs) ->
         let input =
           {
             minimal_input with
             service_name = Option.map generated_router_name service;
             cron_jobs = Some (cron_jobs_named jobs);
           }
         in
         let free = names_free ~service ~managed jobs in
         match
           Deploy.cron_plan ~managed_containers:managed ~box_services:[] input
         with
         | Ok _ -> free
         | Error (Handler_error.Invalid_request _) -> not free
         | Error (Handler_error.Orchestrator_failure _)
         | Error (Handler_error.Not_ready _) ->
             false))

(* The client emits this shape from its own deploy_cron_job type; the two are
   structural duplicates, so the wire key is pinned on both sides. *)
let test_cron_job_decodes_network_from_wire () =
  let json =
    Yojson.Safe.from_string
      {|{"name":"backup","image":"backup:v1","schedule":"0 0 * * *","network":"bondi-network"}|}
  in
  match Simple.cron_job_of_yojson json with
  | Error msg -> Alcotest.fail ("cron job rejected: " ^ msg)
  | Ok (job : Simple.cron_job) ->
      Alcotest.check
        (Alcotest.option Alcotest.string)
        "network decoded from the wire" (Some "bondi-network") job.network

let test_cron_job_decodes_absent_network () =
  let json =
    Yojson.Safe.from_string
      {|{"name":"backup","image":"backup:v1","schedule":"0 0 * * *"}|}
  in
  match Simple.cron_job_of_yojson json with
  | Error msg -> Alcotest.fail ("cron job rejected: " ^ msg)
  | Ok (job : Simple.cron_job) ->
      Alcotest.check
        (Alcotest.option Alcotest.string)
        "absent network decodes to None" None job.network

(* Copied verbatim from what the client's own encoder emits in
   test/client/test_deploy_helpers.ml's wire-key test, embedded in a deploy
   payload. Hand-writing it would let the two halves of the wire contract
   drift. *)
let wire_cron_job_json =
  {|{"name":"backup","image":"img:v1","schedule":"* * * * *","alert_sinks":{"critical":["https://pager.example.com/hook"],"failure":["https://dash.example.com/hook"]},"exit_code_severities":{"critical":[70]}}|}

let alerting_deploy_payload_json =
  {|{"cron_jobs":[|} ^ wire_cron_job_json ^ {|]}|}

(* The rejected payload travels with the message: the ppx reports only which
   type failed, which on a key-name change reads as "Simple.cron_job" and names
   nothing useful. *)
let cron_job_from_deploy_json json_str : Simple.cron_job =
  match Simple.deploy_input_of_yojson (Yojson.Safe.from_string json_str) with
  | Error msg ->
      Alcotest.fail
        (Printf.sprintf "deploy payload rejected: %s; payload: %s" msg json_str)
  | Ok (input : Simple.deploy_input) -> (
      match input.cron_jobs with
      | None -> Alcotest.fail "deploy payload decoded with no cron jobs"
      | Some [ job ] -> job
      | Some jobs ->
          Alcotest.fail
            (Printf.sprintf "expected exactly one cron job, got %d"
               (List.length jobs)))

(* The configured values the fixture carries. Both the decode test and the
   composition test end here; only the path they take to get here differs. The
   severity map is observed through the classifier because it is abstract: 70 is
   the configured override and 1 still falls to the default, so a map landing in
   the wrong slot cannot pass. *)
let check_alert_config ~context ~(alert_sinks : Alert.sinks option)
    ~(exit_code_severities : Simple.exit_code_severities option) =
  (match alert_sinks with
  | None -> Alcotest.fail (context ^ ": alert_sinks did not arrive")
  | Some Alert.{ critical; failure } ->
      Alcotest.check
        (Alcotest.list Alcotest.string)
        (context ^ ": critical sinks")
        [ "https://pager.example.com/hook" ]
        (List.map Alert.sink_url critical);
      Alcotest.check
        (Alcotest.list Alcotest.string)
        (context ^ ": failure sinks")
        [ "https://dash.example.com/hook" ]
        (List.map Alert.sink_url failure));
  match exit_code_severities with
  | None -> Alcotest.fail (context ^ ": exit_code_severities did not arrive")
  | Some map ->
      Alcotest.check Alcotest.bool
        (context ^ ": code 70 is critical")
        true
        (Alert.severity_of_exit_code map 70 = Alert.Critical);
      Alcotest.check Alcotest.bool
        (context ^ ": code 1 falls to the default failure")
        true
        (Alert.severity_of_exit_code map 1 = Alert.Failure)

let test_deploy_input_decodes_alert_config () =
  let job = cron_job_from_deploy_json alerting_deploy_payload_json in
  check_alert_config ~context:"decoded deploy payload"
    ~alert_sinks:job.alert_sinks ~exit_code_severities:job.exit_code_severities

(* The end of the path the defect broke: the sink URLs must reach the run
   payload the orchestrator writes beside the crontab line, not merely the
   decoded record. The crontab line itself no longer carries them -- that is
   the point of the file -- so the payload is where this arm now looks. *)
let test_run_payload_carries_alert_config_from_deploy_json () =
  let payload =
    Yojson.Safe.to_string
      (Crontab.run_payload_of_cron_job
         (cron_job_from_deploy_json alerting_deploy_payload_json))
  in
  Alcotest.check Alcotest.bool "critical sink URL reaches the run payload" true
    (Bondi_common.String_utils.contains ~needle:"https://pager.example.com/hook"
       payload);
  Alcotest.check Alcotest.bool "failure sink URL reaches the run payload" true
    (Bondi_common.String_utils.contains ~needle:"https://dash.example.com/hook"
       payload)

let alerting_config_cron_job () : Client_config.cron_job =
  let sink url =
    match Alert.sink_of_string url with
    | Ok s -> s
    | Error e ->
        Alcotest.fail ("bad sink fixture: " ^ Alert.sink_error_to_string e)
  in
  let severities =
    match
      Alert.severity_map_of_yojson
        (Yojson.Safe.from_string {|{"critical":[70]}|})
    with
    | Ok m -> m
    | Error e ->
        Alcotest.fail
          ("bad severity fixture: " ^ Alert.severity_map_error_to_string e)
  in
  {
    name = "backup";
    image = Test_helpers.image_reference "img";
    schedule = Test_helpers.cron_schedule "* * * * *";
    network = None;
    env_vars = None;
    secret_env_vars = None;
    registry_user = None;
    registry_pass = None;
    alert_sinks =
      Some
        {
          critical = [ sink "https://pager.example.com/hook" ];
          failure = [ sink "https://dash.example.com/hook" ];
        };
    exit_code_severities = Some severities;
    server = { ip_address = "1.2.3.4"; ssh = None; port = None };
  }

(* The seam itself: the client's encoder feeds the server's decoder with no JSON
   literal and no field name written down in between, so a rename or a dropped
   field on either side fails this by construction. The two tests above cannot
   have that property — they start from bytes the client has already produced,
   which is where the original defect was invisible.

   No failure below prints the payload. It is the job, and a test failure is
   read in CI logs and in a terminal that scrolls into a scrollback file. *)
let test_config_to_run_payload_carries_alert_config () =
  let wire =
    Client_deploy.cron_job_to_deploy
      (alerting_config_cron_job ())
      ~image:"img:v1"
  in
  let encoded = Client_deploy.deploy_cron_job_to_yojson wire in
  match Simple.cron_job_of_yojson encoded with
  | Error _ -> Alcotest.fail "the server rejected the client's cron job"
  | Ok (job : Simple.cron_job) -> (
      match Run.run_payload_of_yojson (Crontab.run_payload_of_cron_job job) with
      | Error _ ->
          Alcotest.fail "the run decoder rejected the generated run payload"
      | Ok (payload : Run.run_payload) ->
          check_alert_config
            ~context:"config through the wire to the run payload"
            ~alert_sinks:payload.alert_sinks
            ~exit_code_severities:payload.exit_code_severities)

let test_cron_plan_no_cron_jobs () =
  Alcotest.check
    (Alcotest.list Alcotest.string)
    "no cron actions when cron_jobs is None" []
    (planned_actions ~context:"no cron jobs" minimal_input)

let test_deploy_response_with_strategy_json () =
  let response : Deploy.deploy_response =
    {
      status = "Deploy initiated";
      tag = "v2.0";
      strategy = "blue-green";
      strategy_reason = "image has HEALTHCHECK";
    }
  in
  let json = Deploy.deploy_response_to_yojson response in
  let strategy =
    Yojson.Safe.Util.member "strategy" json |> Yojson.Safe.Util.to_string
  in
  let strategy_reason =
    Yojson.Safe.Util.member "strategy_reason" json |> Yojson.Safe.Util.to_string
  in
  Alcotest.check Alcotest.string "strategy field" "blue-green" strategy;
  Alcotest.check Alcotest.string "strategy_reason field" "image has HEALTHCHECK"
    strategy_reason

let test_deploy_response_simple_strategy_json () =
  let response : Deploy.deploy_response =
    {
      status = "Deploy initiated";
      tag = "v1.0";
      strategy = "simple";
      strategy_reason = "image has no HEALTHCHECK";
    }
  in
  let json = Deploy.deploy_response_to_yojson response in
  let strategy =
    Yojson.Safe.Util.member "strategy" json |> Yojson.Safe.Util.to_string
  in
  let strategy_reason =
    Yojson.Safe.Util.member "strategy_reason" json |> Yojson.Safe.Util.to_string
  in
  Alcotest.check Alcotest.string "strategy field" "simple" strategy;
  Alcotest.check Alcotest.string "strategy_reason field"
    "image has no HEALTHCHECK" strategy_reason

let test_deployment_strategy_of_string_blue_green () =
  Alcotest.check
    (Alcotest.option Alcotest.string)
    "blue-green parses" (Some "blue-green")
    (Option.map Deploy.string_of_deployment_strategy
       (Deploy.deployment_strategy_of_string "blue-green"))

let test_deployment_strategy_of_string_simple () =
  Alcotest.check
    (Alcotest.option Alcotest.string)
    "simple parses" (Some "simple")
    (Option.map Deploy.string_of_deployment_strategy
       (Deploy.deployment_strategy_of_string "simple"))

let test_deployment_strategy_of_string_unknown () =
  Alcotest.check
    (Alcotest.option Alcotest.string)
    "unknown returns None" None
    (Option.map Deploy.string_of_deployment_strategy
       (Deploy.deployment_strategy_of_string "unknown"))

let test_string_of_deployment_strategy () =
  Alcotest.check Alcotest.string "Simple to string" "simple"
    (Deploy.string_of_deployment_strategy Deploy.Simple);
  Alcotest.check Alcotest.string "Blue_green to string" "blue-green"
    (Deploy.string_of_deployment_strategy Deploy.Blue_green)

(* An image inspect whose [Config] carries exactly the health check given and
   no labels. *)
let image_with_healthcheck healthcheck : Docker.image_inspect_response =
  { config = { healthcheck; labels = None } }

let auto_strategy_of healthcheck =
  Deploy.string_of_deployment_strategy
    (Deploy.auto_strategy (image_with_healthcheck healthcheck))

(* The two forms of [Test] that run a probe: an exec form and a shell form. *)
let test_auto_picks_blue_green_for_cmd_healthcheck () =
  Alcotest.check Alcotest.string "CMD" "blue-green"
    (auto_strategy_of
       (Some { test = [ "CMD"; "curl"; "-f"; "http://localhost:8080/health" ] }));
  Alcotest.check Alcotest.string "CMD-SHELL" "blue-green"
    (auto_strategy_of
       (Some { test = [ "CMD-SHELL"; "curl -f http://localhost:8080/health" ] }))

(* [HEALTHCHECK NONE] reports a [Test] of [["NONE"]]: the key is present but no
   probe runs, so blue-green would wait for a health it never gets. An empty
   [Test] runs no probe either. The CMD forms resolving to blue-green above are
   this test's affirmative arm. *)
let test_auto_picks_simple_for_none_and_absent () =
  Alcotest.check Alcotest.string "NONE" "simple"
    (auto_strategy_of (Some { test = [ "NONE" ] }));
  Alcotest.check Alcotest.string "absent" "simple" (auto_strategy_of None);
  Alcotest.check Alcotest.string "empty Test" "simple"
    (auto_strategy_of (Some { test = [] }))

(* --- Deploy.strategy_choice --- *)

(* A service with no proxy: every Traefik field is absent, as the client sends
   it when [bondi.yaml] has no [traefik:] block. *)
let proxyless_input =
  {
    minimal_input with
    traefik_domain_name = None;
    traefik_image = None;
    traefik_acme_email = None;
    traefik_acme_ca_server = None;
    force_traefik_redeploy = None;
    deployment_strategy = None;
  }

let cmd_healthcheck_image =
  image_with_healthcheck
    (Some { test = [ "CMD"; "curl"; "-f"; "http://localhost:8080/health" ] })

(* The strategy and reason the choice gives for an image, or a failure naming
   the refusal it made instead. *)
let chosen ~context input inspect =
  match Deploy.strategy_choice input with
  | Ok choose ->
      let strategy, reason = choose inspect in
      (Deploy.string_of_deployment_strategy strategy, reason)
  | Error e ->
      Alcotest.failf "%s: refused: %s" context (Handler_error.message e)

let strategy_and_reason = Alcotest.(pair string string)

(* Blue-green switches traffic through the proxy, so a service declaring it
   with no proxy is the caller's mistake, refused naming the service. The
   affirmative arm is the same service declaring simple, which is accepted. *)
let test_strategy_choice_proxyless_blue_green_refused () =
  (match
     Deploy.strategy_choice
       { proxyless_input with deployment_strategy = Some "blue-green" }
   with
  | Error (Handler_error.Invalid_request msg as e) ->
      Alcotest.(check bool)
        ("the refusal names the service: " ^ msg)
        true
        (Bondi_common.String_utils.contains ~needle:"my-service" msg);
      Alcotest.(check bool)
        ("the refusal names the missing block: " ^ msg)
        true
        (Bondi_common.String_utils.contains ~needle:"traefik:" msg);
      Alcotest.check Alcotest.int "the caller's mistake exits 2" 2
        (Handler_error.exit_code e)
  | Error (Handler_error.Orchestrator_failure msg | Handler_error.Not_ready msg)
    ->
      Alcotest.failf "refused in a class that is not the caller's: %s" msg
  | Ok _ -> Alcotest.fail "blue-green with no proxy was accepted");
  Alcotest.check strategy_and_reason "the same service declaring simple"
    ("simple", "configured in bondi.yaml")
    (chosen ~context:"declared simple"
       { proxyless_input with deployment_strategy = Some "simple" }
       cmd_healthcheck_image)

(* Left to choose, a service with no proxy runs under simple even though its
   image has a health check, and the reason says why: blue-green has no proxy
   to switch. *)
let test_strategy_choice_proxyless_auto_is_simple () =
  Alcotest.check strategy_and_reason "auto with no proxy"
    ("simple", "no traefik: block")
    (chosen ~context:"auto, no proxy" proxyless_input cmd_healthcheck_image)

(* With a proxy declared nothing changes: the image's health check still picks
   blue-green, and a declared strategy is still the one that runs. *)
let test_strategy_choice_with_domain_unchanged () =
  Alcotest.check strategy_and_reason "auto with a proxy"
    ("blue-green", "image has HEALTHCHECK")
    (chosen ~context:"auto, proxy" minimal_input cmd_healthcheck_image);
  Alcotest.check strategy_and_reason "declared simple with a proxy"
    ("simple", "configured in bondi.yaml")
    (chosen ~context:"declared simple, proxy"
       { minimal_input with deployment_strategy = Some "simple" }
       cmd_healthcheck_image);
  Alcotest.check strategy_and_reason "declared blue-green with a proxy"
    ("blue-green", "configured in bondi.yaml")
    (chosen ~context:"declared blue-green, proxy"
       { minimal_input with deployment_strategy = Some "blue-green" }
       cmd_healthcheck_image)

(* A domain with no Traefik image adopts the box's proxy, and the choice treats
   it as proxied, as the workload plan does: auto reads the image, and
   blue-green is accepted. The affirmative arm is the same request with no
   domain, which the choice treats as proxy-less. *)
let test_strategy_choice_domain_without_image_has_a_proxy () =
  let domain_only = { minimal_input with traefik_image = None } in
  Alcotest.check strategy_and_reason "auto"
    ("blue-green", "image has HEALTHCHECK")
    (chosen ~context:"auto, domain only" domain_only cmd_healthcheck_image);
  Alcotest.check strategy_and_reason "declared blue-green"
    ("blue-green", "configured in bondi.yaml")
    (chosen ~context:"blue-green, domain only"
       { domain_only with deployment_strategy = Some "blue-green" }
       cmd_healthcheck_image);
  Alcotest.check strategy_and_reason "no domain, the same request"
    ("simple", "no traefik: block")
    (chosen ~context:"auto, no domain"
       { domain_only with traefik_domain_name = None }
       cmd_healthcheck_image)

(* A strategy that is not one is refused as it always was, with or without a
   proxy, and the unknown name is not mistaken for blue-green's refusal. *)
let test_strategy_choice_unknown_strategy_keeps_its_refusal () =
  List.iter
    (fun (context, input) ->
      match
        Deploy.strategy_choice
          { input with deployment_strategy = Some "rolling" }
      with
      | Error (Handler_error.Orchestrator_failure msg) ->
          Alcotest.check Alcotest.string context
            "unknown deployment_strategy: rolling (valid values: blue-green, \
             simple)"
            msg
      | Error (Handler_error.Invalid_request msg | Handler_error.Not_ready msg)
        ->
          Alcotest.failf "%s: refused in another class: %s" context msg
      | Ok _ -> Alcotest.failf "%s: an unknown strategy was accepted" context)
    [ ("with a proxy", minimal_input); ("with no proxy", proxyless_input) ]

let test_deploy_input_logs_flag () =
  let input = { minimal_input with logs = Some false } in
  Alcotest.check
    (Alcotest.option Alcotest.bool)
    "logs is Some false" (Some false) input.logs;
  (* Round-trip through yojson *)
  let json = Simple.deploy_input_to_yojson input in
  let decoded =
    match Simple.deploy_input_of_yojson json with
    | Ok v -> v
    | Error msg -> Alcotest.fail ("unexpected error: " ^ msg)
  in
  Alcotest.check
    (Alcotest.option Alcotest.bool)
    "logs survives JSON round-trip" (Some false) decoded.logs;
  (* Default when absent *)
  let input_no_logs = { minimal_input with logs = None } in
  let json2 = Simple.deploy_input_to_yojson input_no_logs in
  let decoded2 =
    match Simple.deploy_input_of_yojson json2 with
    | Ok v -> v
    | Error msg -> Alcotest.fail ("unexpected error: " ^ msg)
  in
  Alcotest.check
    (Alcotest.option Alcotest.bool)
    "logs defaults to None" None decoded2.logs

(* ------------------------------------------------------------------------- *)
(* Volumes on the wire                                                       *)
(* ------------------------------------------------------------------------- *)

let mount_fields = Test_helpers.mount_fields

(* The body is what the client's own encoder emits for a payload declaring two
   mounts, so the decoder is asked to read the client's wire shape rather than
   one this file wrote. *)
let test_decode_input_accepts_volumes () =
  let mount = Test_helpers.bind_mount in
  let payload : Client_deploy.deploy_payload =
    {
      service_name = Some "my-service";
      image = Some "myapp:v1";
      port = Some 8080;
      env_vars = [];
      traefik_domain_name = Some "example.com";
      traefik_image = None;
      traefik_acme_email = None;
      traefik_acme_ca_server = None;
      registry_user = None;
      registry_pass = None;
      force_traefik_redeploy = None;
      cron_jobs = None;
      deployment_strategy = None;
      health_timeout = None;
      poll_interval = None;
      logs = None;
      volumes =
        Some
          [
            mount ~host:"/srv/myapp/invoices" ~container:"/app/invoices"
              ~read_only:false;
            mount ~host:"/etc/myapp" ~container:"/app/config" ~read_only:true;
          ];
    }
  in
  let body =
    Yojson.Safe.to_string (Client_deploy.deploy_payload_to_yojson payload)
  in
  match Deploy.decode_input body with
  | Error e ->
      Alcotest.failf "the client's payload was refused: %s"
        (Handler_error.message e)
  | Ok (input : Simple.deploy_input) ->
      Alcotest.(check (option (list (triple string string bool))))
        "both mounts, in order, with their flags"
        (Some
           [
             ("/srv/myapp/invoices", "/app/invoices", false);
             ("/etc/myapp", "/app/config", true);
           ])
        (Option.map (List.map mount_fields) input.volumes)

(* A malformed volume is refused as the caller's mistake. The message says
   which field was at fault but not what it held: a refusal's message never
   carries a value from the payload, on any error branch. *)
let check_volume_refused ~what ~leaked body =
  match Deploy.decode_input body with
  | Ok _ -> Alcotest.failf "%s was accepted" what
  | Error (Handler_error.Orchestrator_failure msg) ->
      Alcotest.failf
        "a malformed volume is the caller's mistake, but it answered \
         Orchestrator_failure: %s"
        msg
  | Error (Handler_error.Not_ready msg) ->
      Alcotest.failf
        "a malformed volume is the caller's mistake, but it answered \
         Not_ready: %s"
        msg
  | Error (Handler_error.Invalid_request msg) ->
      Alcotest.(check bool)
        (what ^ ": the message names the field at fault")
        true
        (Bondi_common.String_utils.contains ~needle:"volumes" msg);
      List.iter
        (fun needle ->
          Alcotest.(check bool)
            (what ^ ": the message does not echo " ^ needle)
            false
            (Bondi_common.String_utils.contains ~needle msg))
        leaked

let test_decode_input_rejects_relative_volume () =
  check_volume_refused ~what:"a relative host path" ~leaked:[ "myapp" ]
    {|{"service_name":"my-service","volumes":[{"host":"srv/myapp/invoices","container":"/app/invoices","read_only":false}]}|}

let test_decode_input_rejects_duplicate_container_path () =
  check_volume_refused ~what:"a duplicate container path"
    ~leaked:[ "/app/dupe"; "myapp" ]
    {|{"service_name":"my-service","volumes":[{"host":"/srv/myapp/a","container":"/app/dupe","read_only":false},{"host":"/srv/myapp/b","container":"/app/dupe","read_only":true}]}|}

let test_decode_input_rejects_unknown_volume_key () =
  check_volume_refused ~what:"an unknown entry key"
    ~leaked:[ "myapp"; "/app/invoices"; "sekrit_key" ]
    {|{"service_name":"my-service","volumes":[{"host":"/srv/myapp/invoices","container":"/app/invoices","read_only":false,"sekrit_key":true}]}|}

let test_decode_input_rejects_control_character_volume () =
  check_volume_refused ~what:"a control character in a path"
    ~leaked:[ "myapp"; "/app/invoices" ]
    {|{"service_name":"my-service","volumes":[{"host":"/srv/myapp\u0001/invoices","container":"/app/invoices","read_only":false}]}|}

(* A field that does not decode is refused at decode, before any plan exists,
   as the caller's mistake. The message names the field and restates the
   grammar but does not carry what the field held: a refusal's message never
   carries a value from the payload, and a reference that failed to parse is
   unvalidated text that may hold a pasted credential. *)
let check_field_refused ~what ~field ~leaked body =
  match Deploy.decode_input body with
  | Ok _ -> Alcotest.failf "%s was accepted" what
  | Error (Handler_error.Orchestrator_failure msg) ->
      Alcotest.failf
        "%s is the caller's mistake, but it answered Orchestrator_failure: %s"
        what msg
  | Error (Handler_error.Not_ready msg) ->
      Alcotest.failf "%s is the caller's mistake, but it answered Not_ready: %s"
        what msg
  | Error (Handler_error.Invalid_request msg) ->
      Alcotest.(check bool)
        (Printf.sprintf "%s: the message names the field %s (got %S)" what field
           msg)
        true
        (String.starts_with
           ~prefix:("invalid deploy payload: " ^ field ^ ": ")
           msg);
      List.iter
        (fun needle ->
          Alcotest.(check bool)
            (what ^ ": the message does not echo " ^ needle)
            false
            (Bondi_common.String_utils.contains ~needle msg))
        leaked

(* Credentials pasted into a reference: the registry's port is not a number, so
   it does not parse. *)
let pasted_credentials = "deployer:t0ken@registry.example.com/app:1.0"

let test_decode_refuses_bad_reference () =
  let leaked = [ "t0ken"; "deployer"; "registry.example.com" ] in
  check_field_refused ~what:"a bad service image" ~field:"image" ~leaked
    (Printf.sprintf {|{"service_name":"my-service","image":%S}|}
       pasted_credentials);
  check_field_refused ~what:"an untagged service image" ~field:"image"
    ~leaked:[]
    {|{"service_name":"my-service","image":"registry.example.com/app"}|};
  check_field_refused ~what:"a bad Traefik image" ~field:"traefik_image" ~leaked
    (Printf.sprintf {|{"traefik_image":%S}|} pasted_credentials);
  check_field_refused ~what:"a bad cron image" ~field:"cron_jobs[].image"
    ~leaked
    (Printf.sprintf
       {|{"cron_jobs":[{"name":"backup","image":%S,"schedule":"0 * * * *"}]}|}
       pasted_credentials)

(* A service name becomes the segment of its router's label keys. Traefik drops
   a container whose label key holds a [.] and Docker refuses a one-character
   container name, so either is refused at decode, before anything is stopped,
   rather than deployed to a service that is never served. *)
let test_decode_refuses_unroutable_service_name () =
  check_field_refused ~what:"a service name holding a dot" ~field:"service_name"
    ~leaked:[ "shop.example" ]
    {|{"service_name":"shop.example","image":"myapp:v1","port":8080,"traefik_domain_name":"example.com"}|};
  check_field_refused ~what:"a one-character service name" ~field:"service_name"
    ~leaked:[ {|"q"|} ]
    {|{"service_name":"q","image":"myapp:v1","port":8080,"traefik_domain_name":"example.com"}|};
  check_field_refused ~what:"a service name with an uppercase letter"
    ~field:"service_name" ~leaked:[ "Shop" ]
    {|{"service_name":"Shop","image":"myapp:v1","port":8080,"traefik_domain_name":"example.com"}|};
  check_field_refused ~what:"a service name Bondi's Traefik container defines"
    ~field:"service_name" ~leaked:[ "acme-http" ]
    {|{"service_name":"acme-http","image":"myapp:v1","port":8080,"traefik_domain_name":"example.com"}|};
  check_field_refused ~what:"a service name that is not a string"
    ~field:"service_name" ~leaked:[ "4242" ]
    {|{"service_name":4242,"image":"myapp:v1","port":8080,"traefik_domain_name":"example.com"}|}

(* The schedule is written into root's crontab as the start of the job's line,
   so one that is not five fields is refused at decode, naming the job it
   belongs to. The message carries the job's name and no other value from the
   payload: neither the image nor what the schedule held. The newline case is
   the probe that would have started a second crontab line running as root. *)
let test_decode_refuses_bad_schedule_naming_job () =
  List.iter
    (fun (what, schedule, leaked) ->
      let body =
        Printf.sprintf
          {|{"cron_jobs":[{"name":"nightly","image":"backup:v1","schedule":%s}]}|}
          (Yojson.Safe.to_string (`String schedule))
      in
      check_field_refused ~what ~field:"cron_jobs[].schedule"
        ~leaked:("backup:v1" :: leaked) body;
      match Deploy.decode_input body with
      | Ok _ -> Alcotest.failf "%s was accepted" what
      | Error e ->
          Alcotest.(check bool)
            (Printf.sprintf "%s: the message names the job (got %S)" what
               (Handler_error.message e))
            true
            (Bondi_common.String_utils.contains ~needle:"nightly"
               (Handler_error.message e)))
    [
      ("an empty schedule", "", []);
      ("a four-field schedule", "* * * *", [ "* * * *" ]);
      ( "a schedule holding a newline",
        "not a schedule\n* * * * * root reboot",
        [ "not a schedule"; "root reboot" ] );
    ]

(* A schedule sent as a number is refused naming the job, and the message
   does not echo the value. *)
let test_decode_refuses_non_string_schedule () =
  let body =
    {|{"cron_jobs":[{"name":"nightly","image":"backup:v1","schedule":5}]}|}
  in
  match Deploy.decode_input body with
  | Ok _ -> Alcotest.fail "a numeric schedule was accepted"
  | Error e ->
      Alcotest.(check string)
        "the refusal names the field and the job"
        ("invalid deploy payload: cron_jobs[].schedule: job nightly: the \
          schedule is not a string: " ^ Bondi_common.Cron_schedule.grammar)
        (Handler_error.message e)

(* Common schedules decode, and each is read back as it was written: the
   crontab line starts with these bytes, so a decode that reshaped one would
   rewrite that box's line on its next deploy. *)
let test_decode_accepts_common_schedules () =
  List.iter
    (fun schedule ->
      match
        Deploy.decode_input
          (Printf.sprintf
             {|{"cron_jobs":[{"name":"nightly","image":"backup:v1","schedule":%S}]}|}
             schedule)
      with
      | Error e ->
          Alcotest.failf "the schedule %S was refused: %s" schedule
            (Handler_error.message e)
      | Ok (input : Simple.deploy_input) ->
          Alcotest.(check (option (list string)))
            (Printf.sprintf "%S is read as written" schedule)
            (Some [ schedule ])
            (Option.map
               (List.map (fun (job : Simple.cron_job) ->
                    Bondi_common.Cron_schedule.to_string job.schedule))
               input.cron_jobs))
    [ "17 * * * *"; "* * * * *"; "30 3 * * *" ]

(* The certificate server arrives as [traefik_acme_ca_server]. An https URL is
   read as written. Anything else is refused at decode as the caller's mistake,
   naming the field without echoing what it held. *)
let test_decode_acme_ca_server () =
  let url = "https://pebble:14000/dir" in
  (match
     Deploy.decode_input (Printf.sprintf {|{"traefik_acme_ca_server":%S}|} url)
   with
  | Error e ->
      Alcotest.failf "an https certificate server was refused: %s"
        (Handler_error.message e)
  | Ok (input : Simple.deploy_input) ->
      Alcotest.(check (option string))
        "the certificate server is read as written" (Some url)
        (Option.map Bondi_common.Acme_ca_server.to_string
           input.traefik_acme_ca_server));
  check_field_refused ~what:"a plain-http certificate server"
    ~field:"traefik_acme_ca_server" ~leaked:[ "ca.example.com" ]
    {|{"traefik_acme_ca_server":"http://ca.example.com/dir"}|}

(* An older client still sends [drain_grace_period], as the float its encoder
   writes. The decoder is strict, so dropping the field here would refuse
   every deploy such a client makes; it is read and then used by nothing. The
   port is asserted so the acceptance is of this body, read whole. *)
let test_input_with_drain_grace_period_accepted () =
  match
    Deploy.decode_input
      {|{"service_name":"web","image":"myapp:v1","port":8080,"drain_grace_period":5.0}|}
  with
  | Error e ->
      Alcotest.failf "a payload carrying drain_grace_period was refused: %s"
        (Handler_error.message e)
  | Ok (input : Simple.deploy_input) ->
      Alcotest.(check (option int))
        "the rest of the payload is read" (Some 8080) input.port

(* ------------------------------------------------------------------------- *)
(* Traefik restart policy                                                    *)
(* ------------------------------------------------------------------------- *)

(* The running proxy as the container listing reports it, with the policy the
   daemon says it applied. Every arm below is this fixture; only the image tag,
   the applied policy and the request differ, so an absence assertion cannot
   pass by failing to reach the proxy path at all. *)
let traefik_policy_context ~traefik_image ~policy :
    Deploy.traefik_policy_context =
  {
    traefik =
      Some
        (Server_test_helpers.mk_container ~id:"traefik-1" ~image:traefik_image
           ~names:[ "/bondi-traefik" ] ());
    applied_policy = policy;
  }

(* The Engine always reports MaximumRetryCount, including for a policy that
   cannot carry one [observed — 2026-09-02], so a fixture omitting it would not
   be what plan reads. *)
let applied_policy name : Docker.restart_policy =
  { name; maximum_retry_count = Some 0 }

let policy_actions ?(input = minimal_input) context =
  List.map action_string (Deploy.traefik_policy_plan input context)

let converged = [ "UpdateRestartPolicy(traefik-1,unless-stopped)" ]

let test_traefik_at_the_wrong_policy_plans_an_update () =
  Alcotest.check
    (Alcotest.list Alcotest.string)
    "converges the running proxy in place" converged
    (policy_actions
       (traefik_policy_context ~traefik_image:"traefik:v3.3.0"
          ~policy:(Some (applied_policy "no"))))

(* The daemon reporting no policy at all is a rejection, not agreement: an
   answer that says nothing -- including an inspect that could not be read at
   all -- is not evidence that the container is compliant. *)
let test_traefik_with_no_reported_policy_plans_an_update () =
  Alcotest.check
    (Alcotest.list Alcotest.string)
    "an unreported policy is not a pass" converged
    (policy_actions
       (traefik_policy_context ~traefik_image:"traefik:v3.3.0" ~policy:None))

let test_traefik_at_the_declared_policy_plans_no_update () =
  Alcotest.check
    (Alcotest.list Alcotest.string)
    "leaves a compliant proxy alone" []
    (policy_actions
       (traefik_policy_context ~traefik_image:"traefik:v3.3.0"
          ~policy:(Some (applied_policy "unless-stopped"))))

let test_no_traefik_running_plans_no_update () =
  Alcotest.check
    (Alcotest.list Alcotest.string)
    "nothing to converge" []
    (policy_actions { Deploy.traefik = None; applied_policy = None })

(* The residue of the existing gate, pinned rather than assumed: a bondi.yaml
   that declares no reverse proxy converges none, even on a box that is running
   one. A box in that state is corrected by declaring the proxy again. *)
let test_traefik_not_declared_plans_no_update () =
  Alcotest.check
    (Alcotest.list Alcotest.string)
    "an undeclared proxy is left alone" []
    (policy_actions
       ~input:
         { minimal_input with traefik_image = None; traefik_acme_email = None }
       (traefik_policy_context ~traefik_image:"traefik:v3.3.0"
          ~policy:(Some (applied_policy "no"))))

(* A proxy about to be replaced is left alone, whichever strategy rolls the
   workload forward: the proxy step creates its successor with the policy
   already on it, under every strategy, so the plan takes none. The affirmative
   arm is the same proxy at the requested version, which stays and so is
   corrected in place. *)
let test_traefik_policy_plan_strategy_independent () =
  Alcotest.check
    (Alcotest.list Alcotest.string)
    "a proxy at another version is replaced, not updated" []
    (policy_actions
       (traefik_policy_context ~traefik_image:"traefik:v2.0"
          ~policy:(Some (applied_policy "no"))));
  Alcotest.check
    (Alcotest.list Alcotest.string)
    "a forced redeploy replaces it, so it is not updated" []
    (policy_actions
       ~input:{ minimal_input with force_traefik_redeploy = Some true }
       (traefik_policy_context ~traefik_image:"traefik:v3.3.0"
          ~policy:(Some (applied_policy "no"))));
  Alcotest.check
    (Alcotest.list Alcotest.string)
    "the same proxy at the requested version is updated" converged
    (policy_actions
       (traefik_policy_context ~traefik_image:"traefik:v3.3.0"
          ~policy:(Some (applied_policy "no"))))

(* --- Deploy.pull_plan: every pull the deploy needs, before anything moves --- *)

let pull_string = function
  | Deploy.PullWorkload image ->
      "PullWorkload(" ^ Bondi_common.Image_reference.to_string image ^ ")"
  | Deploy.PullTraefik image ->
      "PullTraefik(" ^ Bondi_common.Image_reference.to_string image ^ ")"
  | Deploy.PullCronImage job -> "PullCronImage(" ^ job.Simple.name ^ ")"

let pulls ?(workload_pulled = false) ?(traefik = None) input =
  List.map pull_string
    (Deploy.pull_plan ~workload_pulled input ~current_traefik:traefik)

let running_traefik image =
  Some
    (Server_test_helpers.mk_container ~id:"traefik-1" ~image
       ~names:[ "/bondi-traefik" ] ())

let two_cron_input =
  {
    minimal_input with
    cron_jobs =
      Some
        [
          cron_job_on_network ~name:"backup" ~network:None;
          cron_job_on_network ~name:"report" ~network:None;
        ];
  }

(* The guarantee, as a plan: a first deploy needs the proxy, the workload and
   every cron image, and the plan names all of them. [deploy] runs this list to
   its end before a restart policy is written, a container is stopped or
   created, or the crontab is touched, so a failure anywhere in it leaves the
   box as it was. *)
let test_pull_plan_names_every_image_a_first_deploy_needs () =
  let names = pulls two_cron_input in
  Alcotest.check
    (Alcotest.list Alcotest.string)
    "proxy, workload, then each cron image"
    [
      "PullTraefik(traefik:v3.3.0)";
      "PullWorkload(myapp:v1)";
      "PullCronImage(backup)";
      "PullCronImage(report)";
    ]
    names

let test_pull_plan_pulls_a_replaced_traefik () =
  Alcotest.check
    (Alcotest.list Alcotest.string)
    "a proxy at another version is replaced, so its image is pulled"
    [ "PullTraefik(traefik:v3.3.0)"; "PullWorkload(myapp:v1)" ]
    (pulls ~traefik:(running_traefik "traefik:v2.0") minimal_input)

let test_pull_plan_leaves_a_kept_traefik_unpulled () =
  Alcotest.check
    (Alcotest.list Alcotest.string)
    "a proxy that stays is not pulled"
    [ "PullWorkload(myapp:v1)" ]
    (pulls ~traefik:(running_traefik "traefik:v3.3.0") minimal_input)

let test_pull_plan_skips_a_workload_already_pulled () =
  Alcotest.check
    (Alcotest.list Alcotest.string)
    "auto selection pulled it to inspect it"
    [
      "PullTraefik(traefik:v3.3.0)";
      "PullCronImage(backup)";
      "PullCronImage(report)";
    ]
    (pulls ~workload_pulled:true two_cron_input)

let test_pull_plan_cron_only_deploy () =
  Alcotest.check
    (Alcotest.list Alcotest.string)
    "no service, so no proxy and no workload"
    [ "PullCronImage(backup)"; "PullCronImage(report)" ]
    (pulls { two_cron_input with service_name = None; image = None })

(* The order of the whole deploy, as a value. Every step that changes the box is
   named here, so "every pull precedes the first change" is a property of the
   plan and not of how [deploy] happens to be written. *)
let mutating = function
  | Deploy.Pull_images
  | Deploy.Check_image_labels
  | Deploy.Validate_workload
  | Deploy.Gather_workload
  | Deploy.Clean_up ->
      false
  | Deploy.Converge_restart_policy
  | Deploy.Snapshot_replaced
  | Deploy.Converge_proxy
  | Deploy.Deploy_workload
  | Deploy.Apply_cron ->
      true

let check_pulls_first ~context ~has_service =
  let steps = Deploy.deploy_steps ~has_service in
  let rec before_first_change = function
    | [] -> Alcotest.fail (context ^ ": no pull step")
    | Deploy.Pull_images :: _ -> ()
    | step :: _ when mutating step ->
        Alcotest.fail (context ^ ": a changing step precedes the pulls")
    | _ :: rest -> before_first_change rest
  in
  before_first_change steps;
  Alcotest.check Alcotest.int
    (context ^ ": pulled once")
    1
    (List.length (List.filter (( = ) Deploy.Pull_images) steps))

(* Simple, blue-green and auto differ in which images [pull_plan] names, pinned
   above, and share this order; a cron-only deploy is the one without a service. *)
let test_every_pull_precedes_the_first_change () =
  check_pulls_first ~context:"a service deploy" ~has_service:true;
  check_pulls_first ~context:"a cron-only deploy" ~has_service:false

let test_the_workload_moves_before_the_crontab () =
  let steps = Deploy.deploy_steps ~has_service:true in
  let index step =
    let rec go i = function
      | [] -> Alcotest.fail "step missing"
      | x :: _ when x = step -> i
      | _ :: rest -> go (i + 1) rest
    in
    go 0 steps
  in
  Alcotest.check Alcotest.bool "workload then crontab" true
    (index Deploy.Deploy_workload < index Deploy.Apply_cron);
  Alcotest.check Alcotest.bool "cleanup last" true
    (index Deploy.Clean_up = List.length steps - 1)

let step_index step steps =
  let rec go i = function
    | [] -> Alcotest.fail "step missing"
    | x :: _ when x = step -> i
    | _ :: rest -> go (i + 1) rest
  in
  go 0 steps

(* The proxy's image is pulled with every other image, before anything moves,
   whenever the proxy will be created or replaced, whichever strategy runs.
   [pull_plan] takes no strategy, so the two ways a deploy arrives at one are
   the two inputs it can see: a strategy the request declares leaves the
   workload to be pulled here, and one the image's health check chose has
   already pulled it. The deploy then converges the proxy in a step of its own,
   ahead of the workload. *)
let test_pull_plan_lists_traefik_under_both_strategies () =
  List.iter
    (fun (workload_pulled, path) ->
      let lists ~traefik =
        pulls ~workload_pulled ~traefik minimal_input
        |> List.mem "PullTraefik(traefik:v3.3.0)"
      in
      Alcotest.check Alcotest.bool
        (path ^ ": a proxy that is created is pulled")
        true (lists ~traefik:None);
      Alcotest.check Alcotest.bool
        (path ^ ": a proxy that is replaced is pulled")
        true
        (lists ~traefik:(running_traefik "traefik:v2.0"));
      Alcotest.check Alcotest.bool
        (path ^ ": a proxy that stays is not pulled")
        false
        (lists ~traefik:(running_traefik "traefik:v3.3.0")))
    [
      (false, "simple or blue-green, declared");
      (true, "blue-green, chosen by the health check");
    ];
  let steps = Deploy.deploy_steps ~has_service:true in
  let at step = step_index step steps in
  Alcotest.check Alcotest.bool "the proxy converges after every pull" true
    (at Deploy.Pull_images < at Deploy.Converge_proxy);
  Alcotest.check Alcotest.bool "and before the workload moves" true
    (at Deploy.Converge_proxy < at Deploy.Deploy_workload);
  (* The snapshot records the image the running proxy holds, so it is taken
     before the proxy is replaced and the old proxy's image reaches cleanup. *)
  Alcotest.check Alcotest.bool "after the snapshot of what it replaces" true
    (at Deploy.Snapshot_replaced < at Deploy.Converge_proxy)

let proxy_action_string = function
  | Proxy.CreateNetwork { network_name } ->
      "CreateNetwork(" ^ network_name ^ ")"
  | Proxy.PullImage { image } ->
      "PullImage(" ^ Bondi_common.Image_reference.to_string image ^ ")"
  | Proxy.StopAndRemove { container_id } ->
      "StopAndRemove(" ^ container_id ^ ")"
  | Proxy.EnsureTraefik { traefik_config } ->
      "EnsureTraefik("
      ^ Option.value ~default:"<no image>" traefik_config.container_config.image
      ^ ")"

let proxy_steps ~traefik input =
  List.map proxy_action_string
    (Deploy.proxy_plan input ~current_traefik:traefik)

let replaced_proxy =
  [
    "CreateNetwork(bondi-network)";
    "PullImage(traefik:v3.3.0)";
    "StopAndRemove(traefik-1)";
    "EnsureTraefik(traefik:v3.3.0)";
  ]

let pebble_url = "https://pebble:14000/dir"

let pebble =
  match Bondi_common.Acme_ca_server.of_string pebble_url with
  | Ok server -> server
  | Error msg -> Alcotest.failf "the fixture URL was refused: %s" msg

(* A request that declares blue-green converges the proxy from the same fields
   a simple one does: a changed image replaces it, and so does the redeploy
   flag, which is how a changed certificate server reaches it. The certificate
   server is carried into the command of the Traefik the plan creates. The twin
   is the same box with nothing changed and nothing forced, which keeps it. *)
let test_blue_green_replaces_traefik_on_image_ca_server_or_force () =
  let blue_green =
    { minimal_input with deployment_strategy = Some "blue-green" }
  in
  let unchanged = running_traefik "traefik:v3.3.0" in
  Alcotest.check
    (Alcotest.list Alcotest.string)
    "a changed image replaces the proxy" replaced_proxy
    (proxy_steps ~traefik:(running_traefik "traefik:v2.0") blue_green);
  Alcotest.check
    (Alcotest.list Alcotest.string)
    "the redeploy flag replaces it" replaced_proxy
    (proxy_steps ~traefik:unchanged
       { blue_green with force_traefik_redeploy = Some true });
  let with_ca =
    {
      blue_green with
      traefik_acme_ca_server = Some pebble;
      force_traefik_redeploy = Some true;
    }
  in
  let planned = Deploy.proxy_plan with_ca ~current_traefik:unchanged in
  Alcotest.check
    (Alcotest.list Alcotest.string)
    "a changed certificate server, with the flag, replaces it" replaced_proxy
    (List.map proxy_action_string planned);
  Alcotest.check
    (Alcotest.list Alcotest.bool)
    "the created Traefik is sent the certificate server" [ true ]
    (List.filter_map
       (function
         | Proxy.EnsureTraefik { traefik_config } ->
             Some
               (List.mem
                  ("--certificatesResolvers.bondi_resolver.acme.caServer="
                 ^ pebble_url)
                  (Option.value ~default:[] traefik_config.container_config.cmd))
         | Proxy.CreateNetwork _
         | Proxy.PullImage _
         | Proxy.StopAndRemove _ ->
             None)
       planned);
  Alcotest.check
    (Alcotest.list Alcotest.string)
    "nothing changed and nothing forced keeps it"
    [ "CreateNetwork(bondi-network)" ]
    (proxy_steps ~traefik:unchanged blue_green)

(* A request with no [traefik:] block converges no proxy: nothing is created,
   pulled or stopped, even on a box running a proxy at another version. The
   affirmative arm is the same box with the block declared, which replaces it. *)
let test_no_traefik_block_no_proxy_step () =
  let undeclared =
    {
      minimal_input with
      traefik_domain_name = None;
      traefik_image = None;
      traefik_acme_email = None;
    }
  in
  let running = running_traefik "traefik:v2.0" in
  Alcotest.check
    (Alcotest.list Alcotest.string)
    "no proxy step on a box running one" []
    (proxy_steps ~traefik:running undeclared);
  Alcotest.check
    (Alcotest.list Alcotest.string)
    "no proxy step on a box without one" []
    (proxy_steps ~traefik:None undeclared);
  Alcotest.check
    (Alcotest.list Alcotest.string)
    "and no proxy pull"
    [ "PullWorkload(myapp:v1)" ]
    (pulls ~traefik:running undeclared);
  Alcotest.check
    (Alcotest.list Alcotest.string)
    "the block declared replaces the same proxy" replaced_proxy
    (proxy_steps ~traefik:running minimal_input);
  Alcotest.check
    (Alcotest.list Alcotest.string)
    "and pulls its image"
    [ "PullTraefik(traefik:v3.3.0)"; "PullWorkload(myapp:v1)" ]
    (pulls ~traefik:running minimal_input)

(* The three proxy fields are declared together or not at all. Each partial
   combination converges no proxy, even on a box running one; the affirmative
   arm is the complete set, which replaces it. *)
let test_partial_proxy_declaration_no_proxy_step () =
  let image = Some (Test_helpers.image_reference "traefik:v3.3.0") in
  let domain = Some "example.com" in
  let email = Some "ops@example.com" in
  let running = running_traefik "traefik:v2.0" in
  let declared i d e =
    {
      minimal_input with
      traefik_image = i;
      traefik_domain_name = d;
      traefik_acme_email = e;
    }
  in
  List.iter
    (fun (what, input) ->
      Alcotest.check
        (Alcotest.list Alcotest.string)
        ("no proxy step with only " ^ what)
        []
        (proxy_steps ~traefik:running input))
    [
      ("an image", declared image None None);
      ("a domain", declared None domain None);
      ("an email", declared None None email);
      ("an image and a domain", declared image domain None);
      ("an image and an email", declared image None email);
      ("a domain and an email", declared None domain email);
    ];
  Alcotest.check
    (Alcotest.list Alcotest.string)
    "the complete set replaces the same proxy" replaced_proxy
    (proxy_steps ~traefik:running (declared image domain email))

(* --- Deploy.deploy: the composition the plans sit underneath --- *)

(* The service the label capture's image was built for: its [Config.Labels]
   holds [traefik.http.routers.obsapp.middlewares]. *)
let obsapp_input =
  { minimal_input with service_name = Some (Test_helpers.router_name "obsapp") }

let label_check_message ~context inspect =
  match Deploy.image_label_check obsapp_input inspect with
  | Error (Handler_error.Invalid_request msg) -> msg
  | Error (Handler_error.Orchestrator_failure msg)
  | Error (Handler_error.Not_ready msg) ->
      Alcotest.failf
        "%s: an image declaring the label is the caller's to fix, but it \
         answered another class: %s"
        context msg
  | Ok () -> Alcotest.failf "%s: the image declaring the label passed" context

(* A label set at create replaces the image's, so the retry middleware Bondi
   writes on the router would silently drop the middlewares the image declares
   [observed -- 2026-11-22, Docker Engine 29.10.0: created with Bondi's labels
   the container carried Bondi's value; created with none, the image's]. The
   deploy is refused instead, ahead of every step that changes the box, and the
   order is the same whichever strategy runs, so nothing is stopped or removed
   under either. Affirmative arm: the same service with an image that declares
   no labels passes, and its router carries the retry middleware. *)
let test_image_declaring_router_middlewares_is_refused () =
  List.iter
    (fun version ->
      let context = "the label capture at " ^ version in
      let msg =
        label_check_message ~context
          (Server_test_helpers.image_inspect_capture
             ~kind:"router_middlewares_label" ~version)
      in
      Alcotest.(check bool)
        (context ^ ": the refusal names the label")
        true
        (Bondi_common.String_utils.contains
           ~needle:"traefik.http.routers.obsapp.middlewares" msg);
      Alcotest.(check bool)
        (context ^ ": the refusal names the image")
        true
        (Bondi_common.String_utils.contains ~needle:"myapp:v1" msg))
    Server_test_helpers.capture_versions;
  let steps = Deploy.deploy_steps ~has_service:true in
  let check_at = step_index Deploy.Check_image_labels steps in
  List.iteri
    (fun i step ->
      if mutating step then
        Alcotest.(check bool)
          "the check precedes every step that changes the box" true
          (check_at < i))
    steps;
  Alcotest.(check bool)
    "the check reads an image that has been pulled" true
    (step_index Deploy.Pull_images steps < check_at);
  List.iter
    (fun version ->
      Alcotest.(check (result unit string))
        ("an image declaring no labels, at " ^ version ^ ", passes")
        (Ok ())
        (Result.map_error Handler_error.message
           (Deploy.image_label_check obsapp_input
              (Server_test_helpers.image_inspect_capture ~kind:"healthcheck_cmd"
                 ~version))))
    Server_test_helpers.capture_versions;
  match Simple.service_config obsapp_input with
  | Error e -> Alcotest.fail ("service_config refused: " ^ e)
  | Ok (_, { Docker.labels; _ }) ->
      Alcotest.(check (option string))
        "and its router carries the retry middleware" (Some "obsapp-retry")
        (Option.bind labels
           (List.assoc_opt "traefik.http.routers.obsapp.middlewares"))

(* Every refusal and every read the workload plans from precedes the first step
   that changes the box, the restart-policy write and the proxy included. *)
let test_workload_refusals_and_reads_precede_every_change () =
  let steps = Deploy.deploy_steps ~has_service:true in
  List.iter
    (fun step ->
      Alcotest.(check bool)
        "a refusal or a read follows the label check" true
        (step_index Deploy.Check_image_labels steps < step_index step steps);
      List.iteri
        (fun i later ->
          if mutating later then
            Alcotest.(check bool)
              "and precedes every step that changes the box" true
              (step_index step steps < i))
        steps)
    [ Deploy.Validate_workload; Deploy.Gather_workload ]

(* [deploy]'s catch-all is reachable through no pure seam: [cron_plan] answers
   with a value, and everything after it is Docker. The Engine is reached over
   [net], so a net that raises is what makes a strategy throw. *)
exception Docker_socket_unreachable

let unreachable_docker_net () =
  let net = Eio_mock.Net.make "docker" in
  Eio_mock.Net.on_getaddrinfo net [ `Raise Docker_socket_unreachable ];
  Eio_mock.Net.on_connect net [ `Raise Docker_socket_unreachable ];
  net

let test_deploy_reports_an_escaping_exception () =
  Eio_mock.Backend.run @@ fun () ->
  let net = unreachable_docker_net () in
  let clock = Eio_mock.Clock.make () in
  match Deploy.deploy ~clock ~net minimal_input with
  | Ok _ ->
      Alcotest.fail
        "a deploy whose Engine calls raise must not report a deployed tag"
  | Error (Handler_error.Invalid_request msg) ->
      Alcotest.failf
        "an exception out of a strategy is Bondi's fault, not the caller's, \
         but it answered Invalid_request: %s"
        msg
  | Error (Handler_error.Not_ready msg) ->
      Alcotest.failf
        "an exception out of a strategy is a fault during a request on a box \
         that was ready, but it answered Not_ready: %s"
        msg
  | Error (Handler_error.Orchestrator_failure msg) ->
      Alcotest.(check bool)
        "the failure carries the exception that escaped" true
        (Bondi_common.String_utils.contains ~needle:"Docker_socket_unreachable"
           msg)

(* --- Deploy.deploy against a scripted Engine --- *)

module Fake_engine = Server_test_helpers.Fake_engine

let request_moves_the_box (meth, target) =
  let has needle = Bondi_common.String_utils.contains ~needle target in
  match meth with
  | "DELETE" -> true
  | "POST" -> has "/containers/"
  | _ -> false

let describe_requests requests =
  String.concat "; " (List.map (fun (m, t) -> m ^ " " ^ t) requests)

let check_nothing_moved ~context engine =
  match List.filter request_moves_the_box (Fake_engine.calls engine) with
  | [] -> ()
  | moved ->
      Alcotest.failf "%s: the deploy moved the box before it was refused: %s"
        context (describe_requests moved)

let ends_with_json target =
  let path =
    match String.index_opt target '?' with
    | Some i -> String.sub target 0 i
    | None -> target
  in
  String.ends_with ~suffix:"/json" path

let engine_with ~containers ~image_inspect ~container_inspect meth target =
  let has needle = Bondi_common.String_utils.contains ~needle target in
  match (meth, has "/version") with
  | _, true -> (500, "no negotiation")
  | "POST", _ when has "/images/create" ->
      (200, "{\"status\":\"Status: Image is up to date for myapp:v1\"}\r\n")
  | "GET", _ when has "/containers/json" -> (200, containers)
  | "GET", _ when has "/images/" && ends_with_json target -> image_inspect
  | "GET", _ when has "/containers/" && ends_with_json target ->
      container_inspect target
  | _ -> (200, "{}")

let ok_image_inspect () =
  ( 200,
    Server_test_helpers.image_inspect_capture_body ~kind:"no_healthcheck"
      ~version:"v1.45" )

let traefik_container_listing =
  {|[{"Id":"t1","Image":"traefik:v3.0.0","ImageID":"sha256:old","Names":["/bondi-traefik"],"State":"running"}]|}

let run_deploy ~respond input =
  let engine, net = Fake_engine.make ~respond in
  let clock = Eio_mock.Clock.make () in
  let result = Deploy.deploy ~clock ~net input in
  (engine, result)

let refusal_message ~context = function
  | Error (Handler_error.Orchestrator_failure msg) -> msg
  | Error (Handler_error.Invalid_request msg)
  | Error (Handler_error.Not_ready msg) ->
      Alcotest.failf "%s: answered a class this refusal does not carry: %s"
        context msg
  | Ok _ -> Alcotest.failf "%s: the deploy was accepted" context

(* A request that decodes but that the workload cannot be built from (here, no
   port) is refused before the proxy is touched: [Converge_proxy] can remove the
   running Traefik, which interrupts every site on the box, so every refusal the
   request can meet is made before it. The box holds a Traefik at another image
   and an unreadable policy, so both the policy write and the replacement would
   be recorded had the deploy reached them. *)
let test_a_refused_workload_is_refused_before_the_proxy_moves () =
  Eio_mock.Backend.run @@ fun () ->
  List.iter
    (fun strategy ->
      let context = "strategy " ^ strategy in
      let engine, result =
        run_deploy
          ~respond:
            (engine_with ~containers:traefik_container_listing
               ~image_inspect:(ok_image_inspect ()) ~container_inspect:(fun _ ->
                 (500, "unreadable")))
          {
            minimal_input with
            port = None;
            deployment_strategy = Some strategy;
          }
      in
      let msg = refusal_message ~context result in
      Alcotest.(check bool)
        (context ^ ": the refusal names the port")
        true
        (Bondi_common.String_utils.contains ~needle:"port is required" msg);
      Alcotest.(check bool)
        (context ^ ": the images were pulled, so the arm reached the steps")
        true
        (List.exists
           (fun (m, t) ->
             m = "POST"
             && Bondi_common.String_utils.contains ~needle:"/images/create" t)
           (Fake_engine.calls engine));
      check_nothing_moved ~context engine;
      Alcotest.(check bool)
        (context ^ ": no restart policy was written")
        false
        (List.exists
           (fun (_, t) ->
             Bondi_common.String_utils.contains ~needle:"/update" t)
           (Fake_engine.calls engine)))
    [ "simple"; "blue-green" ]

(* The same read decides the strategy and the label check, so a failure of it
   is one failure: the deploy stops as Bondi's fault, with nothing moved,
   whether the request declared a strategy or left the image to choose one. *)
let test_a_failed_image_inspect_fails_the_deploy_before_anything_moves () =
  Eio_mock.Backend.run @@ fun () ->
  List.iter
    (fun strategy ->
      let context =
        match strategy with
        | Some s -> "declared " ^ s
        | None -> "chosen by the image"
      in
      let engine, result =
        run_deploy
          ~respond:
            (engine_with ~containers:traefik_container_listing
               ~image_inspect:(500, "inspect refused")
               ~container_inspect:(fun _ -> (500, "unreadable")))
          { minimal_input with deployment_strategy = strategy }
      in
      let msg = refusal_message ~context result in
      Alcotest.(check bool)
        (context ^ ": the failure carries the Engine's answer")
        true
        (Bondi_common.String_utils.contains ~needle:"inspect refused" msg);
      (match result with
      | Error e ->
          Alcotest.check Alcotest.int
            (context ^ ": an Engine failure exits 1")
            1
            (Handler_error.exit_code e)
      | Ok _ -> ());
      check_nothing_moved ~context engine)
    [ None; Some "simple"; Some "blue-green" ]

(* An interrupted blue-green deploy can leave [<name>-new], and what it is
   decides what the next deploy does, so it is read before anything moves,
   proxy included. A read that fails stops the deploy where it stands. *)
let test_a_failed_temp_container_inspect_stops_before_anything_moves () =
  Eio_mock.Backend.run @@ fun () ->
  let containers =
    {|[{"Id":"t1","Image":"traefik:v3.0.0","ImageID":"sha256:old","Names":["/bondi-traefik"],"State":"running"},{"Id":"n1","Image":"myapp:v0","ImageID":"sha256:o","Names":["/my-service-new"],"State":"running"}]|}
  in
  let engine, result =
    run_deploy
      ~respond:
        (engine_with ~containers ~image_inspect:(ok_image_inspect ())
           ~container_inspect:(fun target ->
             if Bondi_common.String_utils.contains ~needle:"/n1/" target then
               (500, "temp inspect refused")
             else (500, "unreadable")))
      { minimal_input with deployment_strategy = Some "blue-green" }
  in
  let msg = refusal_message ~context:"temp inspect" result in
  Alcotest.(check bool)
    "the failure carries the Engine's answer" true
    (Bondi_common.String_utils.contains ~needle:"temp inspect refused" msg);
  check_nothing_moved ~context:"temp inspect" engine;
  Alcotest.(check bool)
    "and no restart policy was written" false
    (List.exists
       (fun (_, t) -> Bondi_common.String_utils.contains ~needle:"/update" t)
       (Fake_engine.calls engine))

(* A box Bondi never set up: no container, no network, an image whose health
   check would pick blue-green if a proxy were declared. It answers every
   request a proxy-less simple deploy makes, so a deploy that it carries to the
   end shows which requests were made. *)
let proxyless_engine =
  let base =
    engine_with ~containers:"[]"
      ~image_inspect:
        ( 200,
          Server_test_helpers.image_inspect_capture_body ~kind:"healthcheck_cmd"
            ~version:"v1.45" )
      ~container_inspect:(fun _ -> (404, "{\"message\":\"no such container\"}"))
  in
  fun meth target ->
    let has needle = Bondi_common.String_utils.contains ~needle target in
    match meth with
    | "POST" when has "/networks/create" -> (201, "{\"Id\":\"n1\"}")
    | "GET" when has "/networks" -> (200, "[]")
    | "POST" when has "/containers/create" ->
        (201, "{\"Id\":\"svc1\",\"Warnings\":[]}")
    | _ -> base meth target

let has_target ~meth ~needle requests =
  List.exists
    (fun (m, t) -> m = meth && Bondi_common.String_utils.contains ~needle t)
    requests

(* Blue-green with no proxy is refused before the image is pulled, so a request
   that cannot run fetches nothing and moves nothing. The affirmative arm is
   the same request declaring simple on the same box, which pulls. *)
let test_proxyless_blue_green_refused_before_the_pull () =
  Eio_mock.Backend.run @@ fun () ->
  let context = "proxy-less blue-green" in
  let engine, result =
    run_deploy ~respond:proxyless_engine
      { proxyless_input with deployment_strategy = Some "blue-green" }
  in
  (match result with
  | Error (Handler_error.Invalid_request msg as e) ->
      Alcotest.(check bool)
        ("the refusal names the service: " ^ msg)
        true
        (Bondi_common.String_utils.contains ~needle:"my-service" msg);
      Alcotest.check Alcotest.int "the caller's mistake exits 2" 2
        (Handler_error.exit_code e)
  | Error (Handler_error.Orchestrator_failure msg | Handler_error.Not_ready msg)
    ->
      Alcotest.failf "%s: refused in a class that is not the caller's: %s"
        context msg
  | Ok _ -> Alcotest.failf "%s: the deploy was accepted" context);
  Alcotest.(check bool)
    "nothing was pulled" false
    (has_target ~meth:"POST" ~needle:"/images/create" (Fake_engine.calls engine));
  check_nothing_moved ~context engine;
  let engine, declared_simple =
    run_deploy ~respond:proxyless_engine
      { proxyless_input with deployment_strategy = Some "simple" }
  in
  (match declared_simple with
  | Ok response ->
      Alcotest.check Alcotest.string "and it deploys under simple" "simple"
        response.strategy
  | Error e ->
      Alcotest.failf "the same request declaring simple failed: %s"
        (Handler_error.message e));
  Alcotest.(check bool)
    "the same request declaring simple pulls" true
    (has_target ~meth:"POST" ~needle:"/images/create" (Fake_engine.calls engine))

(* A proxy-less service left to choose is deployed under simple on a box with
   no proxy and no network: the network is made, the service container is
   created with Bondi's labels and none of Traefik's, and Traefik is never
   asked for. *)
let test_proxyless_simple_deploy_creates_service () =
  Eio_mock.Backend.run @@ fun () ->
  let engine, result = run_deploy ~respond:proxyless_engine proxyless_input in
  (match result with
  | Ok response ->
      Alcotest.check strategy_and_reason "the response names simple and why"
        ("simple", "no traefik: block")
        (response.strategy, response.strategy_reason)
  | Error e ->
      Alcotest.failf "the proxy-less deploy failed: %s"
        (Handler_error.message e));
  let calls = Fake_engine.calls engine in
  Alcotest.(check bool)
    "the network is created" true
    (has_target ~meth:"POST" ~needle:"/networks/create" calls);
  let create_body =
    List.find_map
      (fun (m, t, body) ->
        if
          m = "POST"
          && Bondi_common.String_utils.contains ~needle:"/containers/create" t
          && Bondi_common.String_utils.contains ~needle:"my-service" t
        then Some body
        else None)
      (Fake_engine.calls_with_bodies engine)
  in
  match create_body with
  | None ->
      Alcotest.failf "the service container was not created: %s"
        (describe_requests calls)
  | Some body ->
      Alcotest.(check bool)
        ("the service carries bondi.type=service: " ^ body)
        true
        (Bondi_common.String_utils.contains ~needle:"\"bondi.type\":\"service\""
           body);
      Alcotest.(check bool)
        ("the service is opted out of Traefik, with no router: " ^ body)
        true
        (Bondi_common.String_utils.contains
           ~needle:"\"traefik.enable\":\"false\"" body
        && not
             (Bondi_common.String_utils.contains ~needle:"\"traefik.http." body)
        );
      Alcotest.(check bool)
        ("no request names bondi-traefik: " ^ describe_requests calls)
        false
        (List.exists
           (fun (_, t) ->
             Bondi_common.String_utils.contains ~needle:"bondi-traefik" t)
           calls);
      (* The needle is one a proxied deploy through the same engine matches. *)
      let proxied_engine, _ =
        run_deploy ~respond:proxyless_engine minimal_input
      in
      Alcotest.(check bool)
        "a proxied deploy names bondi-traefik" true
        (List.exists
           (fun (_, t) ->
             Bondi_common.String_utils.contains ~needle:"bondi-traefik" t)
           (Fake_engine.calls proxied_engine))

(* The words of a [Test] other than the two that run a probe are not all
   "no HEALTHCHECK": [NONE] and an empty [Test] are, and a word Bondi does not
   know is something else the operator needs to see named. *)
let test_an_unrecognised_health_check_is_named () =
  let reason healthcheck =
    snd (Deploy.auto_selection (image_with_healthcheck healthcheck))
  in
  Alcotest.check Alcotest.string "NONE" "image has no HEALTHCHECK"
    (reason (Some { test = [ "NONE" ] }));
  Alcotest.check Alcotest.string "absent" "image has no HEALTHCHECK"
    (reason None);
  Alcotest.check Alcotest.string "CMD" "image has HEALTHCHECK"
    (reason (Some { test = [ "CMD"; "true" ] }));
  let unknown = Some { Docker.test = [ "GRPC"; "x" ] } in
  Alcotest.check Alcotest.string "an unknown word selects simple" "simple"
    (Deploy.string_of_deployment_strategy
       (fst (Deploy.auto_selection (image_with_healthcheck unknown))));
  Alcotest.(check bool)
    "and its reason names the word" true
    (Bondi_common.String_utils.contains
       ~needle:"unrecognised health check `GRPC`" (reason unknown))

(* A cron-only deploy of one job named like a managed container. Nothing in the
   payload says the box holds one, so only the listing [deploy] makes can find
   the clash. *)
let cron_only_input_named name =
  {
    minimal_input with
    service_name = None;
    image = None;
    port = None;
    traefik_domain_name = None;
    traefik_image = None;
    traefik_acme_email = None;
    cron_jobs = Some (cron_jobs_named [ name ]);
  }

let managed_db_listing =
  {|[{"Id":"m1","Image":"postgres:16","ImageID":"sha256:pg","Names":["/bondi-db"],"State":"running","Labels":{"bondi.type":"managed","bondi.name":"db"}}]|}

let test_deploy_refuses_a_job_named_like_a_managed_container_on_the_box () =
  Eio_mock.Backend.run @@ fun () ->
  let engine, result =
    run_deploy
      ~respond:
        (engine_with ~containers:managed_db_listing
           ~image_inspect:(ok_image_inspect ()) ~container_inspect:(fun _ ->
             (500, "unreadable")))
      (cron_only_input_named "bondi-db")
  in
  (match result with
  | Error (Handler_error.Invalid_request msg) ->
      Alcotest.(check bool)
        ("the refusal names the managed container: " ^ msg)
        true
        (contains {|managed container "bondi-db"|} msg)
  | Error (Handler_error.Orchestrator_failure msg)
  | Error (Handler_error.Not_ready msg) ->
      Alcotest.failf "a name the box holds is the caller's to fix, got: %s" msg
  | Ok _ -> Alcotest.fail "a job named like a managed container was deployed");
  check_nothing_moved ~context:"a name the box holds" engine

(* A box whose containers cannot be listed cannot be checked, and the deploy
   stops with nothing moved rather than planning as if the box held none. *)
let test_a_failed_container_listing_stops_a_cron_deploy () =
  Eio_mock.Backend.run @@ fun () ->
  let respond meth target =
    match contains "/containers/json" target with
    | true -> (500, {|{"message":"listing refused"}|})
    | false ->
        engine_with ~containers:"[]" ~image_inspect:(ok_image_inspect ())
          ~container_inspect:(fun _ -> (500, "unreadable"))
          meth target
  in
  let engine, result = run_deploy ~respond (cron_only_input_named "backup") in
  let context = "a failed listing" in
  let msg = refusal_message ~context result in
  Alcotest.(check bool)
    ("the failure carries the Engine's answer: " ^ msg)
    true
    (contains "listing refused" msg);
  check_nothing_moved ~context engine

let () =
  Alcotest.run "Deploy"
    [
      ( "pure helpers",
        [
          Alcotest.test_case "registry auth serveraddress from reference" `Quick
            test_registry_auth_serveraddress_from_reference;
          Alcotest.test_case "registry auth is base64url" `Quick
            test_registry_auth_base64url;
          Alcotest.test_case "tag_from_image" `Quick test_tag_from_image;
          Alcotest.test_case "require_tag_or_digest" `Quick
            test_require_tag_or_digest;
          Alcotest.test_case "build_response" `Quick test_build_response;
        ] );
      ( "cron plan",
        [
          Alcotest.test_case "pull plan names every image" `Quick
            test_pull_plan_names_every_image_a_first_deploy_needs;
          Alcotest.test_case "pull plan pulls a replaced proxy" `Quick
            test_pull_plan_pulls_a_replaced_traefik;
          Alcotest.test_case "pull plan leaves a kept proxy" `Quick
            test_pull_plan_leaves_a_kept_traefik_unpulled;
          Alcotest.test_case "pull plan skips a pulled workload" `Quick
            test_pull_plan_skips_a_workload_already_pulled;
          Alcotest.test_case "every pull precedes the first change" `Quick
            test_every_pull_precedes_the_first_change;
          Alcotest.test_case "workload before crontab" `Quick
            test_the_workload_moves_before_the_crontab;
          Alcotest.test_case "pull plan cron-only" `Quick
            test_pull_plan_cron_only_deploy;
          Alcotest.test_case "pull plan lists the proxy under both strategies"
            `Quick test_pull_plan_lists_traefik_under_both_strategies;
          Alcotest.test_case "no cron jobs" `Quick test_cron_plan_no_cron_jobs;
          Alcotest.test_case "empty cron jobs" `Quick
            test_cron_plan_empty_cron_jobs;
          Alcotest.test_case "with cron jobs" `Quick
            test_cron_plan_with_cron_jobs;
          Alcotest.test_case "ensures the shared network" `Quick
            test_cron_plan_ensures_shared_network;
          Alcotest.test_case "rejects an unknown network" `Quick
            test_cron_plan_rejects_unknown_network;
          Alcotest.test_case "rejects every unknown network" `Quick
            test_cron_plan_rejects_every_unknown_network;
          Alcotest.test_case "no network declared is unchanged" `Quick
            test_cron_plan_without_network_unchanged;
          Alcotest.test_case "refuses an unsafe job name" `Quick
            test_cron_plan_refuses_an_unsafe_job_name;
          Alcotest.test_case "upsert carries every declared job" `Quick
            test_cron_plan_upsert_carries_every_declared_job;
          Alcotest.test_case "refuses a name in use, per holder" `Quick
            test_cron_plan_refuses_collision_per_holder;
          Alcotest.test_case "a managed clash is found only from the box" `Quick
            test_cron_plan_managed_clash_only_from_box;
          Alcotest.test_case "managed container names read the label" `Quick
            test_managed_container_names_reads_labels;
          Alcotest.test_case "service names read the label" `Quick
            test_service_names_of_reads_labels;
          Alcotest.test_case "a cron-only payload sees the box's service" `Quick
            test_cron_plan_cron_only_payload_sees_box_service;
          Alcotest.test_case "refuses a control character in a secret" `Quick
            test_cron_plan_refuses_secret_control_character;
          prop_accepted_payload_names_unique;
        ] );
      ( "failure classification",
        [
          Alcotest.test_case "invalid request" `Quick
            test_deploy_exit_code_for_invalid_request;
          Alcotest.test_case "orchestrator failure" `Quick
            test_deploy_exit_code_for_orchestrator_failure;
        ] );
      ( "cron job wire shape",
        [
          Alcotest.test_case "decodes network" `Quick
            test_cron_job_decodes_network_from_wire;
          Alcotest.test_case "decodes absent network" `Quick
            test_cron_job_decodes_absent_network;
          Alcotest.test_case "decodes alert config" `Quick
            test_deploy_input_decodes_alert_config;
          Alcotest.test_case "run payload carries alert config" `Quick
            test_run_payload_carries_alert_config_from_deploy_json;
          Alcotest.test_case "config through wire to run payload" `Quick
            test_config_to_run_payload_carries_alert_config;
        ] );
      ( "response",
        [
          Alcotest.test_case "response with strategy fields" `Quick
            test_deploy_response_with_strategy_json;
          Alcotest.test_case "simple strategy response" `Quick
            test_deploy_response_simple_strategy_json;
        ] );
      ( "logs flag",
        [
          Alcotest.test_case "deploy_input logs flag" `Quick
            test_deploy_input_logs_flag;
        ] );
      ( "volumes",
        [
          Alcotest.test_case "decode input accepts volumes" `Quick
            test_decode_input_accepts_volumes;
          Alcotest.test_case "decode input rejects a relative volume" `Quick
            test_decode_input_rejects_relative_volume;
          Alcotest.test_case "decode input rejects a duplicate container path"
            `Quick test_decode_input_rejects_duplicate_container_path;
          Alcotest.test_case "decode input rejects an unknown volume key" `Quick
            test_decode_input_rejects_unknown_volume_key;
          Alcotest.test_case "decode input rejects a control character" `Quick
            test_decode_input_rejects_control_character_volume;
        ] );
      ( "image references",
        [
          Alcotest.test_case "decode refuses a bad reference" `Quick
            test_decode_refuses_bad_reference;
          Alcotest.test_case "decode refuses an unroutable service name" `Quick
            test_decode_refuses_unroutable_service_name;
          Alcotest.test_case "decode refuses a bad schedule, naming the job"
            `Quick test_decode_refuses_bad_schedule_naming_job;
          Alcotest.test_case "decode refuses a schedule that is not a string"
            `Quick test_decode_refuses_non_string_schedule;
          Alcotest.test_case "decode accepts common schedules" `Quick
            test_decode_accepts_common_schedules;
          Alcotest.test_case "decode reads and refuses the certificate server"
            `Quick test_decode_acme_ca_server;
          Alcotest.test_case "decode accepts an input with drain_grace_period"
            `Quick test_input_with_drain_grace_period_accepted;
        ] );
      ( "strategy dispatch",
        [
          Alcotest.test_case "deployment_strategy_of_string blue-green" `Quick
            test_deployment_strategy_of_string_blue_green;
          Alcotest.test_case "deployment_strategy_of_string simple" `Quick
            test_deployment_strategy_of_string_simple;
          Alcotest.test_case "deployment_strategy_of_string unknown" `Quick
            test_deployment_strategy_of_string_unknown;
          Alcotest.test_case "string_of_deployment_strategy roundtrip" `Quick
            test_string_of_deployment_strategy;
          Alcotest.test_case "auto picks blue-green for a CMD health check"
            `Quick test_auto_picks_blue_green_for_cmd_healthcheck;
          Alcotest.test_case "auto picks simple for NONE and absent" `Quick
            test_auto_picks_simple_for_none_and_absent;
        ] );
      ( "strategy choice",
        [
          Alcotest.test_case "proxy-less blue-green is refused" `Quick
            test_strategy_choice_proxyless_blue_green_refused;
          Alcotest.test_case "proxy-less auto is simple" `Quick
            test_strategy_choice_proxyless_auto_is_simple;
          Alcotest.test_case "with a domain the choice is unchanged" `Quick
            test_strategy_choice_with_domain_unchanged;
          Alcotest.test_case "a domain without an image has a proxy" `Quick
            test_strategy_choice_domain_without_image_has_a_proxy;
          Alcotest.test_case "an unknown strategy keeps its refusal" `Quick
            test_strategy_choice_unknown_strategy_keeps_its_refusal;
        ] );
      ( "traefik restart policy",
        [
          Alcotest.test_case "the wrong policy plans an update" `Quick
            test_traefik_at_the_wrong_policy_plans_an_update;
          Alcotest.test_case "no reported policy plans an update" `Quick
            test_traefik_with_no_reported_policy_plans_an_update;
          Alcotest.test_case "the declared policy plans no update" `Quick
            test_traefik_at_the_declared_policy_plans_no_update;
          Alcotest.test_case "no proxy running plans no update" `Quick
            test_no_traefik_running_plans_no_update;
          Alcotest.test_case "an undeclared proxy plans no update" `Quick
            test_traefik_not_declared_plans_no_update;
          Alcotest.test_case "the policy plan is strategy-independent" `Quick
            test_traefik_policy_plan_strategy_independent;
        ] );
      ( "proxy convergence",
        [
          Alcotest.test_case
            "blue-green replaces the proxy on image, ca server or force" `Quick
            test_blue_green_replaces_traefik_on_image_ca_server_or_force;
          Alcotest.test_case "no traefik block, no proxy step" `Quick
            test_no_traefik_block_no_proxy_step;
          Alcotest.test_case "a partial proxy declaration plans no step" `Quick
            test_partial_proxy_declaration_no_proxy_step;
        ] );
      ( "image labels",
        [
          Alcotest.test_case
            "an image declaring the router's middlewares is refused" `Quick
            test_image_declaring_router_middlewares_is_refused;
        ] );
      ( "deploy",
        [
          Alcotest.test_case
            "a refused workload is refused before the proxy moves" `Quick
            test_a_refused_workload_is_refused_before_the_proxy_moves;
          Alcotest.test_case
            "a failed image inspect fails the deploy before anything moves"
            `Quick
            test_a_failed_image_inspect_fails_the_deploy_before_anything_moves;
          Alcotest.test_case
            "a failed temp container inspect stops before anything moves" `Quick
            test_a_failed_temp_container_inspect_stops_before_anything_moves;
          Alcotest.test_case "proxy-less blue-green is refused before the pull"
            `Quick test_proxyless_blue_green_refused_before_the_pull;
          Alcotest.test_case "a proxy-less simple deploy creates the service"
            `Quick test_proxyless_simple_deploy_creates_service;
          Alcotest.test_case "workload refusals and reads precede every change"
            `Quick test_workload_refusals_and_reads_precede_every_change;
          Alcotest.test_case "an unrecognised health check is named" `Quick
            test_an_unrecognised_health_check_is_named;
          Alcotest.test_case
            "an escaping exception becomes an orchestrator failure" `Quick
            test_deploy_reports_an_escaping_exception;
          Alcotest.test_case
            "a job named like a managed container on the box is refused" `Quick
            test_deploy_refuses_a_job_named_like_a_managed_container_on_the_box;
          Alcotest.test_case "a failed container listing stops a cron deploy"
            `Quick test_a_failed_container_listing_stops_a_cron_deploy;
        ] );
    ]
