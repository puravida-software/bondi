module Run = Bondi_server__Run
module Handler_error = Bondi_server__Handler_error
module Docker = Bondi_server__Docker__Client
module Alert = Bondi_common.Alert

let outcome_testable =
  let pp fmt = function
    | Alert.Exited code -> Format.fprintf fmt "Exited %d" code
    | Alert.Start_failed msg -> Format.fprintf fmt "Start_failed %S" msg
  in
  Alcotest.testable pp ( = )

let show_networking_conf = function
  | None -> "None"
  | Some conf ->
      Docker.networking_config_to_yojson conf |> Yojson.Safe.to_string

let check_networking_conf msg ~expected ~actual =
  Alcotest.check Alcotest.string msg
    (show_networking_conf expected)
    (show_networking_conf actual)

let endpoint_on network : Docker.networking_config =
  let endpoint : Docker.endpoint_config =
    { aliases = None; ipv4_address = None }
  in
  { endpoints_config = Some [ (network, endpoint) ] }

let mk_payload ?network () : Run.run_payload =
  {
    job = "nightly";
    image = "myapp:v1";
    network;
    env_vars = None;
    alert_sinks = None;
    exit_code_severities = None;
  }

let test_networking_conf_from_network () =
  check_networking_conf "network produces one endpoint entry"
    ~expected:(Some (endpoint_on "bondi-network"))
    ~actual:(Run.networking_conf_of_network (Some "bondi-network"))

let test_run_opts_carries_network () =
  let opts : Docker.run_image_options =
    Run.run_opts ~container_name:"nightly-1" ~full_image:"myapp:v1"
      (mk_payload ~network:"bondi-network" ())
  in
  check_networking_conf "payload network reaches the run options"
    ~expected:(Some (endpoint_on "bondi-network"))
    ~actual:opts.networking_conf

let test_run_opts_absent_network () =
  let opts : Docker.run_image_options =
    Run.run_opts ~container_name:"nightly-1" ~full_image:"myapp:v1"
      (mk_payload ())
  in
  check_networking_conf "absent payload network reaches the run options"
    ~expected:None ~actual:opts.networking_conf

let show_restart_policy (host_config : Docker.host_config option) =
  match host_config with
  | None -> "no host config"
  | Some config -> (
      match config.restart_policy with
      | None -> "host config without a restart policy"
      | Some policy -> "restart policy " ^ policy.name)

let test_cron_run_container_declares_no_restart_policy () =
  let opts : Docker.run_image_options =
    Run.run_opts ~container_name:"nightly-1" ~full_image:"myapp:v1"
      (mk_payload ~network:"bondi-network" ())
  in
  (* Affirmative arm on the same value: if the cron labels are there, the
     options really were built by [run_opts] for a cron container, so the
     absence asserted below is a property of the planner and not of a fixture
     that quietly stopped reaching it. *)
  (match opts.config.labels with
  | None -> Alcotest.fail "expected cron labels on the run options"
  | Some labels ->
      Alcotest.check Alcotest.bool "planned as a cron container" true
        (List.mem ("bondi.type", "cron") labels));
  Alcotest.check Alcotest.string
    "a one-shot cron container carries no restart policy"
    "host config without a restart policy"
    (show_restart_policy opts.host_config)

(* A cron pass can exit before Alloy's Docker discovery ever lists it, so its
   lines must leave through the journal instead: the journald driver, tagged
   with the job so a pass's timestamped name never splits the stream, and
   carrying the four bondi.* labels the Alloy relabel rules read. The expected
   strings are written out, not derived from the labels [run_opts] sets, so a
   change to which labels reach the journal fails here and is seen. *)
let test_run_opts_uses_journald_driver () =
  let opts : Docker.run_image_options =
    Run.run_opts ~container_name:"nightly-1759312345.123" ~full_image:"myapp:v1"
      (mk_payload ())
  in
  match opts.host_config with
  | None -> Alcotest.fail "expected a host config on the run options"
  | Some { log_config = None; _ } ->
      Alcotest.fail "expected a log config on the host config"
  | Some { log_config = Some log_config; _ } ->
      Alcotest.check Alcotest.string "log driver" "journald" log_config.type_;
      Alcotest.check
        Alcotest.(option string)
        "tag is the job, not the temporary container name" (Some "nightly")
        (List.assoc_opt "tag" log_config.config);
      Alcotest.check
        Alcotest.(option string)
        "labels names the four bondi.* keys"
        (Some "bondi.managed,bondi.type,bondi.logs,bondi.name")
        (List.assoc_opt "labels" log_config.config);
      (* The two present options above are this absence's affirmative arm:
         the same options map is read, and it is not empty. Disabling the
         driver's cache would leave docker logs on the container empty. *)
      Alcotest.check
        Alcotest.(option string)
        "the dual-logging cache stays on" None
        (List.assoc_opt "cache-disabled" log_config.config)

(* A cron pass runs under a timestamped temporary name, so the container name
   differs on every pass. The workload's name must reach the labels from the
   payload's job, never from that temporary name. *)
let test_run_opts_labels_cron_with_job_name () =
  let opts : Docker.run_image_options =
    Run.run_opts ~container_name:"nightly-1759312345.123" ~full_image:"myapp:v1"
      (mk_payload ())
  in
  match opts.config.labels with
  | None -> Alcotest.fail "expected cron labels on the run options"
  | Some labels ->
      Alcotest.check
        Alcotest.(option string)
        "bondi.name is the job, not the temporary container name"
        (Some "nightly")
        (List.assoc_opt "bondi.name" labels)

let test_networking_conf_none_when_network_absent () =
  check_networking_conf "absent network produces no networking config"
    ~expected:None
    ~actual:(Run.networking_conf_of_network None)

let test_run_response_with_warning_json () =
  let response : Run.run_response =
    { exit_code = 1; warning = Some "failed to remove old container" }
  in
  let json = Run.run_response_to_yojson response in
  let expected =
    `Assoc
      [
        ("exit_code", `Int 1);
        ("warning", `String "failed to remove old container");
      ]
  in
  Alcotest.check Alcotest.string "run_response with warning"
    (Yojson.Safe.to_string expected)
    (Yojson.Safe.to_string json)

let test_run_response_without_warning_json () =
  let response : Run.run_response = { exit_code = 0; warning = None } in
  let json = Run.run_response_to_yojson response in
  let expected = `Assoc [ ("exit_code", `Int 0) ] in
  Alcotest.check Alcotest.string "run_response without warning"
    (Yojson.Safe.to_string expected)
    (Yojson.Safe.to_string json)

let sinks_of pairs =
  match Alert.sinks_of_yojson (`Assoc pairs) with
  | Ok s -> s
  | Error e -> Alcotest.fail e

let failure_sinks () =
  sinks_of [ ("failure", `List [ `String "https://sink.example.com/x" ]) ]

let critical_sinks () =
  sinks_of [ ("critical", `List [ `String "https://page.example.com/x" ]) ]

let critical_map () =
  match
    Alert.severity_map_of_yojson (`Assoc [ ("critical", `List [ `Int 42 ]) ])
  with
  | Ok m -> m
  | Error e -> Alcotest.fail (Alert.severity_map_error_to_string e)

let test_plan_for_payload_unconfigured_dispatches_nothing () =
  Alcotest.(check bool)
    "an unconfigured payload routes nowhere" true
    (Run.plan_for_payload (mk_payload ()) (Alert.Exited 1) ~timestamp:0.0 = None)

let test_plan_for_payload_failure_targets_configured_sinks () =
  let payload =
    { (mk_payload ()) with alert_sinks = Some (failure_sinks ()) }
  in
  match Run.plan_for_payload payload (Alert.Exited 1) ~timestamp:0.0 with
  | None -> Alcotest.fail "a failure with configured sinks should dispatch"
  | Some dispatch ->
      Alcotest.(check (list string))
        "targets the configured failure sink"
        [ "https://sink.example.com/x" ]
        (List.map Alert.sink_url dispatch.Alert.targets)

let test_plan_for_payload_success_dispatches_nothing () =
  let payload =
    { (mk_payload ()) with alert_sinks = Some (failure_sinks ()) }
  in
  Alcotest.(check bool)
    "a success outcome routes nowhere even with sinks" true
    (Run.plan_for_payload payload (Alert.Exited 0) ~timestamp:0.0 = None)

let test_plan_for_payload_critical_map_targets_critical_sinks () =
  let payload =
    {
      (mk_payload ()) with
      alert_sinks = Some (critical_sinks ());
      exit_code_severities = Some (critical_map ());
    }
  in
  match Run.plan_for_payload payload (Alert.Exited 42) ~timestamp:0.0 with
  | None -> Alcotest.fail "a mapped critical code should dispatch"
  | Some dispatch ->
      Alcotest.(check (list string))
        "targets the configured critical sink"
        [ "https://page.example.com/x" ]
        (List.map Alert.sink_url dispatch.Alert.targets)

(* The pre-start half of the run subcommand. [Run.prepare] is the seam these
   exercise because everything past it needs a Docker client and an Eio net;
   the two classification cases assert the failure classifier, which is what
   the subcommand's exit code is taken from. *)

let alerting_sinks_json =
  `Assoc
    [
      ("critical", `List [ `String "https://page.example.com/x" ]);
      ("failure", `List [ `String "https://sink.example.com/x" ]);
    ]

let run_body ?(job = "nightly") ?alert_sinks ~image () =
  let fields =
    [ ("job", `String job); ("image", `String image) ]
    @
    match alert_sinks with
    | None -> []
    | Some sinks -> [ ("alert_sinks", sinks) ]
  in
  Yojson.Safe.to_string (`Assoc fields)

let recording_deliver dispatched ~targets ~payload:_ =
  dispatched := !dispatched @ [ List.map Alert.sink_url targets ]

let prepare_must_fail ~deliver body =
  match Run.prepare ~deliver body with
  | Ok _ -> Alcotest.fail ("prepare accepted a body it must reject: " ^ body)
  | Error err -> err

(* Without this the dispatch tests are vacuous in the same direction: a fixture
   the decoder rejected would also dispatch nothing, and the absence arm would
   pass for the wrong reason. *)
let check_untagged_image_failure err =
  Alcotest.(check bool)
    "the failure is the untagged image, not an earlier rejection" true
    (Bondi_common.String_utils.contains ~needle:"has no tag"
       (Handler_error.message err))

let test_prepare_accepts_a_tagged_image () =
  let dispatched = ref [] in
  match
    Run.prepare
      ~deliver:(recording_deliver dispatched)
      (run_body ~alert_sinks:alerting_sinks_json ~image:"myapp:v1" ())
  with
  | Error err ->
      Alcotest.fail
        ("prepare rejected a valid body: " ^ Handler_error.message err)
  | Ok (payload, full_image) ->
      Alcotest.(check string) "the tagged image survives" "myapp:v1" full_image;
      Alcotest.(check string) "the job name survives" "nightly" payload.Run.job;
      Alcotest.(check (list (list string)))
        "a run that is about to start dispatches nothing" [] !dispatched

(* A cron job's image behind a registry port, or pinned by digest, is run as
   written. Split at every colon, both fail to parse and the job never starts. *)
let test_prepare_accepts_a_registry_port_and_a_digest () =
  let full_image_of image =
    match
      Run.prepare
        ~deliver:(fun ~targets:_ ~payload:_ -> ())
        (run_body ~image ())
    with
    | Error err ->
        Alcotest.fail
          ("prepare rejected a valid body: " ^ Handler_error.message err)
    | Ok (_payload, full_image) -> full_image
  in
  let behind_port = "registry:5000/app:1.2.3" in
  let pinned = behind_port ^ "@sha256:" ^ String.make 64 'a' in
  Alcotest.(check string)
    "a registry port is kept" behind_port
    (full_image_of behind_port);
  Alcotest.(check string) "a digest is kept" pinned (full_image_of pinned)

(* The refusal reaches standard error, cron mail and the diagnostics stream,
   and an image that did not parse is unvalidated text that may hold a pasted
   credential, so it names the field without carrying what the payload held. *)
let test_prepare_refuses_a_malformed_image_without_echoing_it () =
  let rejected = "Registry.Example/APP:token=s3cret" in
  let message =
    Handler_error.message
      (prepare_must_fail
         ~deliver:(fun ~targets:_ ~payload:_ -> ())
         (run_body ~image:rejected ()))
  in
  Alcotest.(check bool)
    "the refusal names the image field" true
    (Bondi_common.String_utils.contains ~needle:"image" message);
  Alcotest.(check bool)
    "and does not carry the rejected text" false
    (Bondi_common.String_utils.contains ~needle:"s3cret" message)

let test_run_dispatches_alert_on_image_parse_failure () =
  let dispatched = ref [] in
  let body = run_body ~alert_sinks:alerting_sinks_json ~image:"myapp" () in
  check_untagged_image_failure
    (prepare_must_fail ~deliver:(recording_deliver dispatched) body);
  (* Only the failure sink: a job that never started routes to [Failure], so a
     dispatch reaching the critical sink would be a mis-route, not a pass. *)
  Alcotest.(check (list (list string)))
    "one alert, routed to the configured failure sink"
    [ [ "https://sink.example.com/x" ] ]
    !dispatched

let test_run_dispatches_no_alert_when_unconfigured () =
  let dispatched = ref [] in
  let body = run_body ~image:"myapp" () in
  check_untagged_image_failure
    (prepare_must_fail ~deliver:(recording_deliver dispatched) body);
  Alcotest.(check (list (list string)))
    "the same failure with no sinks configured dispatches nothing" []
    !dispatched

let test_run_exit_code_for_malformed_body () =
  let dispatched = ref [] in
  let err =
    prepare_must_fail ~deliver:(recording_deliver dispatched) "{\"job\": "
  in
  Alcotest.(check int)
    "a malformed body is the caller's mistake, not a bondi fault" 2
    (Handler_error.exit_code err);
  Alcotest.(check (list (list string)))
    "a body that names no job has no sinks to alert to" [] !dispatched

(* The ppx names only the type that failed, so on its own the message cannot
   tell a misspelled key from a missing one. The keys that arrived are named to
   close that gap; their values never are, because a run payload carries
   env_vars and sink URLs that may embed credentials and this message is
   returned over HTTP and mailed by cron. *)
let test_run_decode_error_names_keys_not_values () =
  let dispatched = ref [] in
  let body =
    Yojson.Safe.to_string
      (`Assoc
         [
           ("job", `String "nightly");
           ("imag", `String "myapp:v1");
           ("env_vars", `Assoc [ ("TOKEN", `String "s3cr3t") ]);
         ])
  in
  let msg =
    Handler_error.message
      (prepare_must_fail ~deliver:(recording_deliver dispatched) body)
  in
  List.iter
    (fun needle ->
      Alcotest.(check bool)
        (Printf.sprintf "the message names the key %s: %s" needle msg)
        true
        (Bondi_common.String_utils.contains ~needle msg))
    [ "job"; "imag"; "env_vars" ];
  Alcotest.(check bool)
    ("no value from the rejected body is echoed: " ^ msg)
    false
    (Bondi_common.String_utils.contains ~needle:"s3cr3t" msg)

(* Cleanup runs only when the container both started and finished. Removing the
   previous container before a failed run has been reported would destroy the
   only copy of what ran last, and renaming a container that never started has
   nothing to rename — so both failure arms skip it and carry no warning. *)
let warning_with ~started ~run_result =
  let cleaned = ref false in
  let warning =
    Run.warning_of_run ~started ~run_result ~cleanup:(fun _container_id ->
        cleaned := true;
        Ok (Some "cleanup ran"))
  in
  (!cleaned, warning)

let cleanup_answer = Alcotest.(result (option string) string)

let test_warning_runs_cleanup_when_the_run_completed () =
  let cleaned, warning =
    warning_with ~started:(Ok "abc123") ~run_result:(Ok 0)
  in
  Alcotest.(check bool) "a completed run cleans up" true cleaned;
  Alcotest.check cleanup_answer "and carries whatever the cleanup reported"
    (Ok (Some "cleanup ran")) warning

let test_warning_skips_cleanup_when_the_wait_failed () =
  let cleaned, warning =
    warning_with ~started:(Ok "abc123") ~run_result:(Error "wait failed")
  in
  Alcotest.(check bool)
    "a run that never finished does not clean up" false cleaned;
  Alcotest.check cleanup_answer "and carries no warning" (Ok None) warning

let test_warning_skips_cleanup_when_the_start_failed () =
  let cleaned, warning =
    warning_with ~started:(Error "no such image")
      ~run_result:(Error "no such image")
  in
  Alcotest.(check bool)
    "a run that never started does not clean up" false cleaned;
  Alcotest.check cleanup_answer "and carries no warning" (Ok None) warning

let test_run_exit_code_for_orchestrator_failure () =
  match
    Run.response_of_run_result ~warning:None
      (Error "docker http 500: internal server error")
  with
  | Ok _ ->
      Alcotest.fail "a Docker-level failure must not answer as a run result"
  | Error err ->
      Alcotest.(check int)
        "an orchestrator fault is a bondi fault, not the caller's mistake" 1
        (Handler_error.exit_code err)

let test_run_outcome_from_exit_code () =
  Alcotest.check outcome_testable "completed run classifies as Exited n"
    (Alert.Exited 137)
    (Run.outcome_of_result (Ok 137))

let test_run_outcome_from_start_failure () =
  Alcotest.check outcome_testable
    "orchestrator-start error classifies as Start_failed"
    (Alert.Start_failed "container never started")
    (Run.outcome_of_result (Error "container never started"))

let test_combine_warnings_none_none () =
  Alcotest.check
    (Alcotest.option Alcotest.string)
    "both None" None
    (Run.combine_warnings None None)

let test_combine_warnings_some_none () =
  Alcotest.check
    (Alcotest.option Alcotest.string)
    "first Some" (Some "a")
    (Run.combine_warnings (Some "a") None)

let test_combine_warnings_none_some () =
  Alcotest.check
    (Alcotest.option Alcotest.string)
    "second Some" (Some "b")
    (Run.combine_warnings None (Some "b"))

let test_combine_warnings_some_some () =
  Alcotest.check
    (Alcotest.option Alcotest.string)
    "both Some" (Some "a; b")
    (Run.combine_warnings (Some "a") (Some "b"))

(* --- The container already under the job's name --- *)

(* A cron run replaces the container under its job's name only when that
   container carries both labels a run writes: bondi.type=cron and bondi.name
   naming this job. Anything else under the name is someone else's, and is
   neither started over nor removed. *)

let existing_testable =
  let pp fmt = function
    | Run.No_container -> Format.fprintf fmt "No_container"
    | Run.Own_cron_container id -> Format.fprintf fmt "Own_cron_container %S" id
    | Run.Foreign name -> Format.fprintf fmt "Foreign %S" name
  in
  Alcotest.testable pp ( = )

let container_named_nightly ~labels : Docker.container =
  {
    id = "abc123";
    image = "someone/else:1";
    image_id = "sha256:0000";
    names = [ "/nightly" ];
    state = Some "running";
    status = Some "Up 2 hours";
    labels;
  }

let check_existing msg ~expected ~labels =
  Alcotest.check existing_testable msg expected
    (Run.existing_of ~job:"nightly" (Some (container_named_nightly ~labels)))

let test_existing_of_unlabelled_is_foreign () =
  check_existing "a container with no labels is foreign"
    ~expected:(Run.Foreign "nightly") ~labels:None;
  check_existing "a container with an empty label set is foreign"
    ~expected:(Run.Foreign "nightly") ~labels:(Some []);
  check_existing "a managed container under the job's name is foreign"
    ~expected:(Run.Foreign "nightly")
    ~labels:(Some [ ("bondi.type", "managed"); ("bondi.name", "nightly") ]);
  check_existing "the job's name label alone is not the cron label"
    ~expected:(Run.Foreign "nightly")
    ~labels:(Some [ ("bondi.name", "nightly") ])

let test_existing_of_other_job_is_foreign () =
  check_existing "another job's cron container is foreign"
    ~expected:(Run.Foreign "nightly")
    ~labels:(Some [ ("bondi.type", "cron"); ("bondi.name", "other") ]);
  check_existing "a cron container naming no job is foreign"
    ~expected:(Run.Foreign "nightly")
    ~labels:(Some [ ("bondi.type", "cron") ])

(* The labels are taken from what a run itself writes, as well as written out:
   a container this job's previous pass left behind must be recognised as its
   own, so the reader and the writer of the labels cannot drift apart. *)
let test_existing_of_own_job () =
  check_existing "the job's own cron container is its own"
    ~expected:(Run.Own_cron_container "abc123")
    ~labels:(Some [ ("bondi.type", "cron"); ("bondi.name", "nightly") ]);
  let written =
    (Run.run_opts ~container_name:"nightly-1759312345.123"
       ~full_image:"myapp:v1" (mk_payload ()))
      .config
      .labels
  in
  check_existing "the labels a run writes mark the container as its own"
    ~expected:(Run.Own_cron_container "abc123") ~labels:written

let test_existing_of_none () =
  Alcotest.check existing_testable "nothing under the name" Run.No_container
    (Run.existing_of ~job:"nightly" None)

(* The seams take the lookup, not its result, so a caller cannot hand one a
   verdict that skips the guard. *)
let test_start_seam_reads_the_name_itself () =
  let started = ref false in
  let refusals = ref [] in
  let start () =
    started := true;
    Ok "new456"
  in
  let refuse msg = refusals := !refusals @ [ msg ] in
  let foreign =
    Run.start_unless_foreign ~refuse
      ~lookup:(fun () -> Ok (Run.Foreign "canary-paper"))
      ~start
  in
  Alcotest.(check bool) "a foreign container starts nothing" false !started;
  Alcotest.(check (list string))
    "the refusal is handed to refuse, once, as answered"
    [ Result.get_error foreign ]
    !refusals;
  let unread =
    Run.start_unless_foreign ~refuse
      ~lookup:(fun () -> Error "docker http 500")
      ~start
  in
  Alcotest.(check bool) "a lookup that fails starts nothing" false !started;
  Alcotest.(check (result string string))
    "and its failure is the answer" (Error "docker http 500") unread;
  let own =
    Run.start_unless_foreign ~refuse
      ~lookup:(fun () -> Ok (Run.Own_cron_container "abc123"))
      ~start
  in
  Alcotest.(check (result string string))
    "the job's own lets it start" (Ok "new456") own

let test_cleanup_seam_reads_the_name_itself () =
  let steps = ref [] in
  let step name =
    steps := !steps @ [ name ];
    None
  in
  let remove old_id = step ("remove " ^ old_id) in
  let rename () = step "rename" in
  let refuse _ = () in
  let own =
    Run.cleanup_of_existing ~refuse ~remove ~rename ~lookup:(fun () ->
        Ok (Run.Own_cron_container "abc123"))
  in
  Alcotest.(check (list string))
    "the old container is removed before the new one takes its name"
    [ "remove abc123"; "rename" ]
    !steps;
  Alcotest.(check (result (option string) string))
    "and nothing is warned" (Ok None) own;
  steps := [];
  let foreign =
    Run.cleanup_of_existing ~refuse ~remove ~rename ~lookup:(fun () ->
        Ok (Run.Foreign "canary-paper"))
  in
  Alcotest.(check (list string)) "a foreign container is not touched" [] !steps;
  Alcotest.(check bool)
    "and the cleanup is refused" true (Result.is_error foreign);
  let unread =
    Run.cleanup_of_existing ~refuse ~remove ~rename ~lookup:(fun () ->
        Error "docker http 500")
  in
  Alcotest.(check (result (option string) string))
    "a name that cannot be read is a warning beside the rename"
    (Ok (Some "docker http 500")) unread

(* --- Run.run against a scripted Engine --- *)

let job = "canary-paper"

let listing_entry ~id =
  Printf.sprintf
    {|{"Id":"%s","Image":"x:1","ImageID":"sha256:x","Names":["/%s"],"State":"exited"}|}
    id job

let foreign_listing = "[" ^ listing_entry ~id:"f1" ^ "]"

let own_listing =
  Printf.sprintf
    {|[{"Id":"old123","Image":"x:1","ImageID":"sha256:x","Names":["/%s"],"State":"exited","Labels":{"bondi.type":"cron","bondi.name":"%s"}}]|}
    job job

let has needle target = Bondi_common.String_utils.contains ~needle target

(* [listings] answers the n-th listing read of the name, the last one repeating,
   so a test can say what the box holds before the pass and after it. *)
let respond ?(remove = (200, "")) ?(rename = (200, "")) ~listings meth target =
  match (meth, target) with
  | _, t when has "/version" t -> (500, "no negotiation")
  | "GET", t when has "/containers/json" t -> listings ()
  | "POST", t when has "/containers/create" t -> (201, {|{"Id":"new456"}|})
  | "POST", t when has "/start" t -> (200, "{}")
  | "POST", t when has "/wait" t -> (200, {|{"StatusCode":0}|})
  | "DELETE", _ -> remove
  | "POST", t when has "/rename" t -> rename
  | _ -> (200, "{}")

let nth_listing sequence =
  let reads = ref 0 in
  fun () ->
    let i = min !reads (List.length sequence - 1) in
    incr reads;
    List.nth sequence i

let run_against ~respond ?alert_sinks () =
  let engine, net = Server_test_helpers.Fake_engine.make ~respond in
  let clock = Eio_mock.Clock.make () in
  let client = Docker.create () in
  let dispatched = ref [] in
  let deliver ~net:_ ~clock:_ ~targets ~payload:_ =
    dispatched := !dispatched @ [ List.map Alert.sink_url targets ]
  in
  let body = run_body ~job ?alert_sinks ~image:"myapp:v1" () in
  let result = Run.run ~clock ~client ~net ~deliver body in
  (Server_test_helpers.Fake_engine.calls engine, result, !dispatched)

let made calls ~meth ~needle =
  List.filter (fun (m, t) -> m = meth && has needle t) calls

let check_untouched ~label calls =
  Alcotest.(check int)
    (label ^ ": nothing was created")
    0
    (List.length (made calls ~meth:"POST" ~needle:"/containers/create"));
  Alcotest.(check int)
    (label ^ ": nothing was removed")
    0
    (List.length (made calls ~meth:"DELETE" ~needle:"/containers/"));
  Alcotest.(check int)
    (label ^ ": nothing was renamed")
    0
    (List.length (made calls ~meth:"POST" ~needle:"/rename"))

let refused_message ~label = function
  | Ok _ -> Alcotest.fail (label ^ ": a foreign container must fail the run")
  | Error err ->
      Alcotest.(check int)
        (label ^ ": the box disagrees with a well-formed request")
        1
        (Handler_error.exit_code err);
      let msg = Handler_error.message err in
      Alcotest.(check bool)
        (label ^ ": the message names the container: " ^ msg)
        true (has job msg);
      msg

let test_foreign_refuses_before_start () =
  Eio_mock.Backend.run @@ fun () ->
  let calls, result, dispatched =
    run_against ~alert_sinks:alerting_sinks_json
      ~respond:(respond ~listings:(nth_listing [ (200, foreign_listing) ]))
      ()
  in
  check_untouched ~label:"before start" calls;
  let msg = refused_message ~label:"before start" result in
  Alcotest.(check bool)
    "the refusal says it is before the start" true
    (has "refusing to run cron job" msg);
  Alcotest.(check (list (list string)))
    "the refusal alerts the failure sinks as a run that never started"
    [ [ "https://sink.example.com/x" ] ]
    dispatched

let test_a_failed_first_lookup_names_the_job () =
  Eio_mock.Backend.run @@ fun () ->
  let calls, result, _ =
    run_against
      ~respond:(respond ~listings:(nth_listing [ (500, "listing refused") ]))
      ()
  in
  check_untouched ~label:"unread name" calls;
  match result with
  | Ok _ -> Alcotest.fail "an unreadable name must not start a run"
  | Error err ->
      Alcotest.(check bool)
        "the failure names the job" true
        (has ("failed to look up container " ^ job) (Handler_error.message err))

let test_own_container_is_replaced_after_the_run () =
  Eio_mock.Backend.run @@ fun () ->
  let calls, result, _ =
    run_against
      ~respond:(respond ~listings:(nth_listing [ (200, own_listing) ]))
      ()
  in
  let order =
    List.filter_map
      (fun (m, t) ->
        if m = "DELETE" && has "/containers/old123" t then Some "remove"
        else if m = "POST" && has "/containers/new456/rename" t then
          Some "rename"
        else None)
      calls
  in
  Alcotest.(check (list string))
    "the old container is removed by id before the new one takes the name"
    [ "remove"; "rename" ] order;
  match result with
  | Ok response ->
      Alcotest.(check int) "the run reports its exit code" 0 response.exit_code;
      Alcotest.(check (option string)) "with no warning" None response.warning
  | Error err -> Alcotest.fail (Handler_error.message err)

(* A container can take the job's name while the pass runs. The name is read
   again at cleanup and judged by the same verdict, so it is not removed, and
   the run that otherwise finished answers the refusal. *)
let test_cleanup_reads_the_name_again () =
  Eio_mock.Backend.run @@ fun () ->
  let calls, result, dispatched =
    run_against ~alert_sinks:alerting_sinks_json
      ~respond:
        (respond
           ~listings:(nth_listing [ (200, "[]"); (200, foreign_listing) ]))
      ()
  in
  Alcotest.(check int)
    "the pass started" 1
    (List.length (made calls ~meth:"POST" ~needle:"/containers/create"));
  Alcotest.(check int)
    "nothing was removed" 0
    (List.length (made calls ~meth:"DELETE" ~needle:"/containers/"));
  Alcotest.(check int)
    "and the pass did not try to take the name" 0
    (List.length (made calls ~meth:"POST" ~needle:"/rename"));
  let msg = refused_message ~label:"at cleanup" result in
  Alcotest.(check bool)
    "the refusal says the pass kept its temporary name" true
    (has "kept its temporary name" msg);
  Alcotest.(check (list (list string)))
    "a run that finished but could not be cleaned up alerts"
    [ [ "https://sink.example.com/x" ] ]
    dispatched

let test_cleanup_warnings_name_the_job_and_container () =
  Eio_mock.Backend.run @@ fun () ->
  let warning_of ?remove ?rename listings =
    let _, result, _ =
      run_against
        ~respond:(respond ?remove ?rename ~listings:(nth_listing listings))
        ()
    in
    match result with
    | Ok response -> response.warning
    | Error err -> Alcotest.fail (Handler_error.message err)
  in
  Alcotest.(check (option string))
    "a lookup that fails at cleanup is a warning, naming the job"
    (Some
       "failed to look up container canary-paper: docker http 500: listing \
        refused")
    (warning_of [ (200, "[]"); (500, "listing refused") ]);
  Alcotest.(check (option string))
    "a failed removal names the container and the job"
    (Some
       "failed to remove old container old123 of cron job canary-paper: docker \
        http 500: remove refused")
    (warning_of ~remove:(500, "remove refused") [ (200, own_listing) ]);
  Alcotest.(check (option string))
    "a failed rename names the container and the job"
    (Some
       "failed to rename container new456 of cron job canary-paper: docker \
        http 500: rename refused")
    (warning_of ~rename:(500, "rename refused") [ (200, "[]") ])

(* --- Run.run: the composition the seams sit underneath --- *)

(* [prepare] takes [deliver] already bound to a net and a clock, so no test of
   it can see where those come from. [run] is where they are bound, and an
   untagged image is the one failure that reaches the dispatch without reaching
   Docker -- which is why this pins the side channel with a client that is never
   called. Pins run.mli's "the net and the clock it needs are bound here rather
   than by the caller". *)
let test_run_binds_its_own_net_and_clock_into_the_alert_channel () =
  Eio_mock.Backend.run @@ fun () ->
  let net = Eio_mock.Net.make "unused" in
  let clock = Eio_mock.Clock.make () in
  let client = Docker.create () in
  let dispatched = ref [] in
  let deliverer_got_runs_own_resources = ref None in
  let deliver ~net:delivered_net ~clock:delivered_clock ~targets ~payload:_ =
    deliverer_got_runs_own_resources :=
      Some (delivered_net == net && delivered_clock == clock);
    dispatched := !dispatched @ [ List.map Alert.sink_url targets ]
  in
  let body = run_body ~alert_sinks:alerting_sinks_json ~image:"myapp" () in
  (match Run.run ~clock ~client ~net ~deliver body with
  | Ok _ ->
      Alcotest.fail "an untagged image must be refused before anything starts"
  | Error err -> check_untagged_image_failure err);
  Alcotest.(check (list (list string)))
    "the alert side channel fires from inside run, not from the subcommand \
     that wraps it"
    [ [ "https://sink.example.com/x" ] ]
    !dispatched;
  Alcotest.(check (option bool))
    "run handed the deliverer its own net and clock, not a rebound pair"
    (Some true)
    !deliverer_got_runs_own_resources

let () =
  Alcotest.run "Run"
    [
      ( "run_response JSON",
        [
          Alcotest.test_case "with warning" `Quick
            test_run_response_with_warning_json;
          Alcotest.test_case "without warning" `Quick
            test_run_response_without_warning_json;
        ] );
      ( "outcome_of_result",
        [
          Alcotest.test_case "exit code" `Quick test_run_outcome_from_exit_code;
          Alcotest.test_case "start failure" `Quick
            test_run_outcome_from_start_failure;
        ] );
      ( "plan_for_payload",
        [
          Alcotest.test_case "unconfigured dispatches nothing" `Quick
            test_plan_for_payload_unconfigured_dispatches_nothing;
          Alcotest.test_case "failure targets configured sinks" `Quick
            test_plan_for_payload_failure_targets_configured_sinks;
          Alcotest.test_case "success dispatches nothing" `Quick
            test_plan_for_payload_success_dispatches_nothing;
          Alcotest.test_case "critical map targets critical sinks" `Quick
            test_plan_for_payload_critical_map_targets_critical_sinks;
        ] );
      ( "prepare",
        [
          Alcotest.test_case "accepts a tagged image" `Quick
            test_prepare_accepts_a_tagged_image;
          Alcotest.test_case "prepare accepts a registry port and a digest"
            `Quick test_prepare_accepts_a_registry_port_and_a_digest;
          Alcotest.test_case
            "prepare refuses a malformed image without echoing it" `Quick
            test_prepare_refuses_a_malformed_image_without_echoing_it;
          Alcotest.test_case "dispatches an alert on image parse failure" `Quick
            test_run_dispatches_alert_on_image_parse_failure;
          Alcotest.test_case "dispatches no alert when unconfigured" `Quick
            test_run_dispatches_no_alert_when_unconfigured;
          Alcotest.test_case "decode error names keys, not values" `Quick
            test_run_decode_error_names_keys_not_values;
        ] );
      ( "run failure classification",
        [
          Alcotest.test_case "malformed body" `Quick
            test_run_exit_code_for_malformed_body;
          Alcotest.test_case "orchestrator failure" `Quick
            test_run_exit_code_for_orchestrator_failure;
        ] );
      ( "warning_of_run",
        [
          Alcotest.test_case "cleans up after a completed run" `Quick
            test_warning_runs_cleanup_when_the_run_completed;
          Alcotest.test_case "skips cleanup when the wait failed" `Quick
            test_warning_skips_cleanup_when_the_wait_failed;
          Alcotest.test_case "skips cleanup when the start failed" `Quick
            test_warning_skips_cleanup_when_the_start_failed;
        ] );
      ( "existing container",
        [
          Alcotest.test_case "unlabelled is foreign" `Quick
            test_existing_of_unlabelled_is_foreign;
          Alcotest.test_case "another job's is foreign" `Quick
            test_existing_of_other_job_is_foreign;
          Alcotest.test_case "the job's own" `Quick test_existing_of_own_job;
          Alcotest.test_case "none" `Quick test_existing_of_none;
          Alcotest.test_case "the start seam reads the name itself" `Quick
            test_start_seam_reads_the_name_itself;
          Alcotest.test_case "the cleanup seam reads the name itself" `Quick
            test_cleanup_seam_reads_the_name_itself;
          Alcotest.test_case "foreign refuses before start" `Quick
            test_foreign_refuses_before_start;
          Alcotest.test_case "a failed first lookup names the job" `Quick
            test_a_failed_first_lookup_names_the_job;
          Alcotest.test_case "own container is replaced after the run" `Quick
            test_own_container_is_replaced_after_the_run;
          Alcotest.test_case "cleanup reads the name again" `Quick
            test_cleanup_reads_the_name_again;
          Alcotest.test_case "cleanup warnings name the job and container"
            `Quick test_cleanup_warnings_name_the_job_and_container;
        ] );
      ( "combine_warnings",
        [
          Alcotest.test_case "None + None" `Quick
            test_combine_warnings_none_none;
          Alcotest.test_case "Some + None" `Quick
            test_combine_warnings_some_none;
          Alcotest.test_case "None + Some" `Quick
            test_combine_warnings_none_some;
          Alcotest.test_case "Some + Some" `Quick
            test_combine_warnings_some_some;
        ] );
      ( "networking_conf_of_network",
        [
          Alcotest.test_case "from network" `Quick
            test_networking_conf_from_network;
          Alcotest.test_case "none when network absent" `Quick
            test_networking_conf_none_when_network_absent;
        ] );
      ( "run_opts",
        [
          Alcotest.test_case "carries network" `Quick
            test_run_opts_carries_network;
          Alcotest.test_case "absent network" `Quick
            test_run_opts_absent_network;
          Alcotest.test_case "cron container declares no restart policy" `Quick
            test_cron_run_container_declares_no_restart_policy;
          Alcotest.test_case "uses the journald driver" `Quick
            test_run_opts_uses_journald_driver;
          Alcotest.test_case "labels a cron container with its job name" `Quick
            test_run_opts_labels_cron_with_job_name;
        ] );
      ( "run",
        [
          Alcotest.test_case
            "binds its own net and clock into the alert channel" `Quick
            test_run_binds_its_own_net_and_clock_into_the_alert_channel;
        ] );
    ]
