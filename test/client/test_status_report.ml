open Alcotest
module Report = Bondi_client.Status_report
module Inventory = Bondi_client.Host_inventory
module Health = Bondi_client.Container_health
module Crontab = Bondi_client.Crontab_listing
module Config_file = Bondi_client.Config_file

let contains = Test_helpers.contains

(* Both constructors named, so a third is a compile error here rather than a
   silently unrendered failure. *)
let unavailability_name
    (unavailability : Bondi_client.Status_report.unavailability) =
  match unavailability with
  | Bondi_client.Status_report.Not_consulted message -> message
  | Bondi_client.Status_report.Not_understood message -> message

(* --- Fixtures ---

   Every test below reads through [report], varying exactly one of its three
   arguments. A row that exists, or a disagreement that is flagged, can then
   only have come from the input the test changed. *)

let created = "2026-08-01T10:00:00.123456789Z"
let mk_config = Client_fixtures.mk_config
let mk_managed_container = Client_fixtures.mk_managed_container

(* The name the setup phase gives a declared container, written the way setup
   writes it rather than as a literal, so the merge fails if either side
   changes its basis. *)
let container_name = Bondi_common.Managed_container.container_name_of

let declared_config =
  mk_config
    ~managed_containers:
      [ mk_managed_container "ibgateway" "ghcr.io/org/ibgateway" "10.48.1e" ]
    ()

let host_container ~name ~image ~tag ~state ~health : Inventory.container =
  {
    name;
    image;
    tag;
    state;
    health;
    restart_count = Some 0;
    created_at = Some created;
  }

let orchestrator_container ~name ~image ~tag ~state : Report.component =
  {
    name;
    observation =
      {
        image;
        tag;
        state;
        (* The orchestrator reports no health of its own: it is Docker over SSH
           that reads what the host recorded, and only a caller that waited over
           SSH has a verdict to carry. *)
        health = None;
        wait = None;
        restart_count = Some 0;
        created_at = Some created;
      };
  }

let orchestrator_on_the_box =
  host_container ~name:"bondi-orchestrator" ~image:"mlopez1506/bondi-server"
    ~tag:"0.10.3" ~state:"running" ~health:Inventory.No_healthcheck

let gateway_on_the_box =
  host_container
    ~name:(container_name "ibgateway")
    ~image:"ghcr.io/org/ibgateway" ~tag:"10.48.1e" ~state:"running"
    ~health:Inventory.Healthy

let orchestrator_over_http =
  orchestrator_container ~name:"bondi-orchestrator"
    ~image:"mlopez1506/bondi-server" ~tag:"0.10.3" ~state:"running"

let gateway_over_http =
  orchestrator_container
    ~name:(container_name "ibgateway")
    ~image:"ghcr.io/org/ibgateway" ~tag:"10.48.1e" ~state:"running"

let both_running =
  Inventory.Observed [ orchestrator_on_the_box; gateway_on_the_box ]

let both_reported = Ok [ orchestrator_over_http; gateway_over_http ]

(* [waits] defaults to nothing waited on, which is [status]'s state on every run
   and [setup]'s on every component that declares no healthcheck. A verdict
   appearing on a row can then only have come from a test that asked for one. *)
let report ?(config = declared_config) ?(docker = both_running)
    ?(orchestrator = both_reported) ?(waits = []) () =
  Report.rows ~config ~docker ~orchestrator ~waits

(* --- Reading a row without reaching for a partial function --- *)

let row_named = Client_fixtures.row_named

let observation_of ~source view =
  match view with
  | Report.Reported observation -> observation
  | Report.Absent ->
      failf "expected %s to have reported an observation, got absent" source
  | Report.Unavailable unavailability ->
      failf "expected %s to have reported an observation, got unavailable: %s"
        source
        (unavailability_name unavailability)

let unavailability_of ~source view =
  match view with
  | Report.Unavailable unavailability -> unavailability_name unavailability
  | Report.Absent -> failf "expected %s to be unavailable, got absent" source
  | Report.Reported _ ->
      failf "expected %s to be unavailable, got a reported observation" source

let check_absent ~source view =
  match view with
  | Report.Absent -> ()
  | Report.Unavailable unavailability ->
      failf
        "expected %s to have answered and found nothing, got unavailable: %s"
        source
        (unavailability_name unavailability)
  | Report.Reported _ ->
      failf "expected %s to have found nothing, got a reported observation"
        source

let health_name (health : Inventory.health) =
  match health with
  | Inventory.Healthy -> "healthy"
  | Inventory.Unhealthy detail -> "unhealthy: " ^ detail
  | Inventory.Starting -> "starting"
  | Inventory.No_healthcheck -> "no healthcheck"
  | Inventory.Not_recorded -> "not recorded"
  | Inventory.Unreadable message -> "unreadable: " ^ message

let health_of ~source (observation : Report.observation) =
  match observation.health with
  | Some health -> health_name health
  | None -> failf "expected %s to carry the health it read" source

(* --- Tests --- *)

(* 1. Every declared and every observed component gets a row when the HTTP
      source could not be consulted at all. The SSH side is on its own here,
      which is the state this report exists for. *)
let test_report_row_exists_without_http () =
  let rows =
    report ~orchestrator:(Error (Report.Not_consulted "connection refused")) ()
  in
  let gateway = row_named (container_name "ibgateway") rows in
  let observation = observation_of ~source:"docker" gateway.docker in
  check string "the row carries what the host said about the image"
    "ghcr.io/org/ibgateway" observation.image;
  check string "the row carries what the host said about the state" "running"
    observation.state;
  check string "the row carries the health the host recorded" "healthy"
    (health_of ~source:"docker" observation);
  check string "the source that could not be consulted says so"
    "connection refused"
    (unavailability_of ~source:"the orchestrator" gateway.orchestrator)

(* 2. The other half of the same requirement: a listing that could not be run
      does not empty the table either. *)
let test_report_row_exists_without_ssh () =
  let rows =
    report ~docker:(Inventory.Unreadable_listing "Missing ssh configuration") ()
  in
  let gateway = row_named (container_name "ibgateway") rows in
  check string "the source that could not be consulted says so"
    "Missing ssh configuration"
    (unavailability_of ~source:"docker" gateway.docker);
  let observation =
    observation_of ~source:"the orchestrator" gateway.orchestrator
  in
  check string "the other source still carries its own reading" "running"
    observation.state

(* 3. The line that cannot be produced today. *)
let test_report_orchestrator_unreachable_row_is_present () =
  let rows =
    report ~orchestrator:(Error (Report.Not_consulted "connection refused")) ()
  in
  let row = row_named "bondi-orchestrator" rows in
  check string "the unreachable orchestrator is a row, not a missing one"
    "connection refused"
    (unavailability_of ~source:"the orchestrator" row.orchestrator)

(* 4. Its affirmative arm on the same fixture: the row is not merely always
      unreachable, it reports the orchestrator when the orchestrator answers. *)
let test_report_orchestrator_reachable_row_is_present () =
  let rows = report () in
  let row = row_named "bondi-orchestrator" rows in
  let observation =
    observation_of ~source:"the orchestrator" row.orchestrator
  in
  check string "a reachable orchestrator reports its own image"
    "mlopez1506/bondi-server" observation.image

(* 5. A declared component neither source reports is a row saying so, and the
      component both sources do report in the same fixture is the arm proving
      the rows are not all absent. *)
let test_report_declared_absent () =
  let config =
    mk_config
      ~managed_containers:
        [
          mk_managed_container "ibgateway" "ghcr.io/org/ibgateway" "10.48.1e";
          mk_managed_container "vaultwarden" "ghcr.io/org/vaultwarden" "1.30.1";
        ]
      ()
  in
  let rows = report ~config () in
  let vaultwarden = row_named (container_name "vaultwarden") rows in
  check_absent ~source:"docker" vaultwarden.docker;
  check_absent ~source:"the orchestrator" vaultwarden.orchestrator;
  let gateway = row_named (container_name "ibgateway") rows in
  let observation = observation_of ~source:"docker" gateway.docker in
  check string "the declared component that is there is still reported"
    "running" observation.state

(* 6. The inverse of "declared but absent": what the next run would remove. *)
let test_report_observed_undeclared_is_flagged () =
  let legacy =
    host_container ~name:"legacy-worker" ~image:"old/worker" ~tag:"1.2"
      ~state:"running" ~health:Inventory.No_healthcheck
  in
  let rows =
    report
      ~docker:
        (Inventory.Observed
           [ orchestrator_on_the_box; gateway_on_the_box; legacy ])
      ()
  in
  let worker = row_named "legacy-worker" rows in
  (match worker.declaration with
  | Report.Undeclared -> ()
  | Report.Declared ->
      fail "a container no configuration declares must be flagged as undeclared");
  (match worker.kind with
  | Report.Infrastructure -> ()
  | Report.Service
  | Report.Cron_job ->
      fail "an undeclared container belongs with the infrastructure it sits in");
  let gateway = row_named (container_name "ibgateway") rows in
  match gateway.declaration with
  | Report.Declared -> ()
  | Report.Undeclared ->
      fail "a declared container must not be flagged as undeclared"

(* 7. The affirmative arm of the disagreement pair: sources that say the same
      thing are not a finding. Without it, [disagrees] returning true always
      would pass every test below. *)
let test_report_agreement_is_not_disagreement () =
  let rows = report () in
  let gateway = row_named (container_name "ibgateway") rows in
  check bool "sources that agree are not a disagreement" false
    (Report.disagrees gateway)

(* 8. Neither source is preferred: both values survive on the row. *)
let test_report_disagreement_keeps_both_values () =
  let drifted =
    orchestrator_container
      ~name:(container_name "ibgateway")
      ~image:"ghcr.io/org/ibgateway" ~tag:"10.47.0" ~state:"running"
  in
  let rows = report ~orchestrator:(Ok [ orchestrator_over_http; drifted ]) () in
  let gateway = row_named (container_name "ibgateway") rows in
  let host = observation_of ~source:"docker" gateway.docker in
  let orchestrator =
    observation_of ~source:"the orchestrator" gateway.orchestrator
  in
  check string "the host's tag is kept" "10.48.1e" host.tag;
  check string "the orchestrator's tag is kept" "10.47.0" orchestrator.tag

(* 9. A component the orchestrator claims to be running from another image is
      drift nothing detects today. *)
let test_report_disagreement_on_image_is_detected () =
  let drifted =
    orchestrator_container
      ~name:(container_name "ibgateway")
      ~image:"ghcr.io/org/ibgateway-old" ~tag:"10.48.1e" ~state:"running"
  in
  let rows = report ~orchestrator:(Ok [ orchestrator_over_http; drifted ]) () in
  check bool "sources naming different images disagree" true
    (Report.disagrees (row_named (container_name "ibgateway") rows));
  check bool "the component they agree on does not" false
    (Report.disagrees (row_named "bondi-orchestrator" rows))

(* 10. And the same for the state, which is the field an operator reads first. *)
let test_report_disagreement_on_state_is_detected () =
  let drifted =
    orchestrator_container
      ~name:(container_name "ibgateway")
      ~image:"ghcr.io/org/ibgateway" ~tag:"10.48.1e" ~state:"exited"
  in
  let rows = report ~orchestrator:(Ok [ orchestrator_over_http; drifted ]) () in
  check bool "sources naming different states disagree" true
    (Report.disagrees (row_named (container_name "ibgateway") rows));
  check bool "the component they agree on does not" false
    (Report.disagrees (row_named "bondi-orchestrator" rows))

(* 11. A source that answered and found nothing, and a source that could not be
       asked, are different facts about the same declared component. The two
       arms differ only in the reading handed in. *)
let test_report_source_absent_is_not_source_unavailable () =
  let answered = report ~docker:(Inventory.Observed []) () in
  let could_not_be_asked =
    report
      ~docker:(Inventory.Unreadable_listing "ssh: connect: no route to host") ()
  in
  check_absent ~source:"docker"
    (row_named (container_name "ibgateway") answered).docker;
  check string "a listing that never ran carries why"
    "ssh: connect: no route to host"
    (unavailability_of ~source:"docker"
       (row_named (container_name "ibgateway") could_not_be_asked).docker)

(* --- Rendering ---

   The renderer is fed rows built by [report] above, so a rendered line can only
   say what the model already held. Reading one row's line out of the output is
   how "the host's account and the orchestrator's are both here" becomes an
   assertion rather than a search of the whole table for two strings that might
   sit on unrelated rows. *)

(* The crontab reading has no absent case: every report is built from a read
   that was taken, so the fixture's default is the outcome of the host having no
   Bondi section rather than of the report having been given nothing. *)
let one_server ?(crontab = Crontab.No_section) ?(warnings = []) rows :
    Report.server_report =
  { address = "1.2.3.4"; rows; crontab; warnings }

let rendered ?crontab ?warnings rows =
  Report.render_table [ one_server ?crontab ?warnings rows ]

(* A row's first rendered line is the one carrying its name; the lines under it
   carry the other source and leave the name column blank. *)
let line_naming name output =
  match
    List.filter
      (fun line -> contains line ~needle:name)
      (String.split_on_char '\n' output)
  with
  | [ line ] -> line
  | [] -> failf "expected a line naming %s, got:\n%s" name output
  | _ :: _ :: _ as lines ->
      failf "expected exactly one line naming %s, got %d:\n%s" name
        (List.length lines) (String.concat "\n" lines)

let cron_config =
  mk_config
    ~cron_jobs:
      [
        {
          name = "daily-close";
          image = "ghcr.io/org/close:v1";
          schedule = "0 0 * * *";
          network = None;
          env_vars = None;
          secret_env_vars = None;
          registry_user = None;
          registry_pass = None;
          alert_sinks = None;
          exit_code_severities = None;
          server = { ip_address = "1.2.3.4"; ssh = None; port = None };
        };
      ]
    ()

let legacy_on_the_box =
  host_container ~name:"legacy-worker" ~image:"old/worker" ~tag:"1.2"
    ~state:"running" ~health:Inventory.No_healthcheck

(* The job's container is gone between runs, so only the orchestrator has it —
   which is the whole reason both sources are read. *)
let daily_close_over_http =
  orchestrator_container ~name:"daily-close" ~image:"ghcr.io/org/close"
    ~tag:"v1" ~state:"completed"

(* 12. Each source is named on the line carrying its own account. The two rows
       differ in which source has them, and nothing else. *)
let test_render_shows_provenance_per_source () =
  let output =
    rendered
      (report ~config:cron_config
         ~docker:(Inventory.Observed [ legacy_on_the_box ])
         ~orchestrator:(Ok [ daily_close_over_http ]) ())
  in
  let host_only = line_naming "legacy-worker" output in
  let orchestrator_only = line_naming "daily-close" output in
  check bool "the host's own reading is named as the host's" true
    (contains host_only ~needle:"docker");
  check bool "and is not attributed to the orchestrator" false
    (contains host_only ~needle:"orch");
  check bool "the orchestrator's reading is named as the orchestrator's" true
    (contains orchestrator_only ~needle:"orch");
  check bool "and is not attributed to the host" false
    (contains orchestrator_only ~needle:"docker")

(* 13. Both accounts survive and the row is flagged. Its affirmative arm is the
       same fixture with the sources agreeing: agreement does collapse to one
       line, so the two lines above are caused by the disagreement rather than
       by a renderer that always prints two. *)
let test_render_disagreement_shows_both_and_flags () =
  let drifted =
    orchestrator_container
      ~name:(container_name "ibgateway")
      ~image:"ghcr.io/org/ibgateway" ~tag:"10.47.0" ~state:"running"
  in
  let disagreeing =
    rendered (report ~orchestrator:(Ok [ orchestrator_over_http; drifted ]) ())
  in
  check bool "the host's tag is rendered" true
    (contains disagreeing ~needle:"10.48.1e");
  check bool "the orchestrator's tag is rendered too" true
    (contains disagreeing ~needle:"10.47.0");
  check bool "and the difference is flagged" true
    (contains
       (line_naming (container_name "ibgateway") disagreeing)
       ~needle:"[disagreement]");
  let agreeing = rendered (report ()) in
  check bool "sources that agree are not flagged" false
    (contains agreeing ~needle:"[disagreement]");
  check bool "and collapse to one account" true
    (contains
       (line_naming (container_name "ibgateway") agreeing)
       ~needle:"both")

(* 14. A container with no healthcheck has passed nothing, and the cell must not
       read as though it had. *)
let test_render_no_healthcheck_is_not_a_positive () =
  let output =
    rendered
      (report
         ~docker:
           (Inventory.Observed
              [
                host_container
                  ~name:(container_name "ibgateway")
                  ~image:"ghcr.io/org/ibgateway" ~tag:"10.48.1e"
                  ~state:"running" ~health:Inventory.No_healthcheck;
              ])
         ())
  in
  let row = line_naming (container_name "ibgateway") output in
  check bool "the row says there is no healthcheck" true
    (contains row ~needle:"no healthcheck defined");
  check bool "and never that the container is healthy" false
    (contains row ~needle:"healthy")

(* 15. Its affirmative arm on the same fixture: a check that did pass renders as
       healthy, so the absence above is caused by the health read rather than by
       a renderer with no health column. *)
let test_render_healthy_renders_as_healthy () =
  let output =
    rendered
      (report
         ~docker:
           (Inventory.Observed
              [
                host_container
                  ~name:(container_name "ibgateway")
                  ~image:"ghcr.io/org/ibgateway" ~tag:"10.48.1e"
                  ~state:"running" ~health:Inventory.Healthy;
              ])
         ())
  in
  check bool "a passing healthcheck renders as healthy" true
    (Test_helpers.contains_word
       (line_naming (container_name "ibgateway") output)
       ~word:"healthy")

(* 16. What the next run would remove is named as such, and what it would keep
       is not. *)
let test_render_undeclared_is_flagged () =
  let output =
    rendered
      (report
         ~docker:(Inventory.Observed [ gateway_on_the_box; legacy_on_the_box ])
         ())
  in
  check bool "a container nothing declares is flagged" true
    (contains (line_naming "legacy-worker" output) ~needle:"[undeclared]");
  check bool "a declared container is not" false
    (contains
       (line_naming (container_name "ibgateway") output)
       ~needle:"[undeclared]")

(* 17. With the host unreadable the orchestrator's rows are all the report has,
       and a reader must not take them for ground truth. The affirmative arm is
       the same fixture with the host readable. *)
let test_render_http_only_rows_flagged_unverified () =
  let unverified =
    rendered
      (report ~docker:(Inventory.Unreadable_listing "ssh: no route to host") ())
  in
  check bool "a row only the orchestrator has is flagged unverified" true
    (contains
       (line_naming (container_name "ibgateway") unverified)
       ~needle:"[unverified]");
  check bool "and the reason the host was not read is on the row" true
    (contains unverified ~needle:"ssh: no route to host");
  let verified = rendered (report ()) in
  check bool "a row the host confirms is not flagged" false
    (contains verified ~needle:"[unverified]")

(* 18. A source that could not be consulted says so on every row it affects,
       including the rows the other source has in full — otherwise a component
       the host confirms reads as though both sources had agreed on it, which is
       the state the orchestrator being down actually produces. Its affirmative
       arm is the same fixture with the orchestrator answering. *)
let test_render_unreachable_source_is_a_line () =
  let unreachable =
    rendered
      (report ~orchestrator:(Error (Report.Not_consulted "connection refused"))
         ())
  in
  check bool "the source that could not be consulted says why" true
    (contains unreachable ~needle:"not reachable: connection refused");
  check bool "without displacing the account the host did give" true
    (contains
       (line_naming "bondi-orchestrator" unreachable)
       ~needle:"mlopez1506/bondi-server");
  let reachable = rendered (report ()) in
  check bool "a source that answered says nothing of the kind" false
    (contains reachable ~needle:"not reachable")

(* 18b. A transport's own message is free text and arrives across several lines
        — Eio words a refused connection that way, and merged stderr does too. A
        cell holding one stops being a cell: its tail lands in the name column and
        reads as a row of its own, on the very output an operator turns to when
        the orchestrator is down. Its affirmative arm is the same fixture with a
        message that was already one line. *)
let test_render_keeps_a_source_message_on_one_line () =
  let across_two_lines =
    rendered
      (report
         ~orchestrator:
           (Error
              (Report.Not_consulted
                 "Eio.Io Net Connection_failure Refused,\n\
                 \  connecting to tcp:127.0.0.1:9"))
         ())
  in
  check bool "the message reaches the report whole, on the row's own line" true
    (contains across_two_lines
       ~needle:
         "not reachable: Eio.Io Net Connection_failure Refused, connecting to \
          tcp:127.0.0.1:9");
  check bool "so no part of it ever begins a line of its own" false
    (List.exists
       (fun line ->
         Bondi_common.String_utils.starts_with ~prefix:"connecting to tcp"
           (String.trim line))
       (String.split_on_char '\n' across_two_lines));
  let already_one_line =
    rendered
      (report ~orchestrator:(Error (Report.Not_consulted "connection refused"))
         ())
  in
  check bool "a message that was already one line is left as it was" true
    (contains already_one_line ~needle:"not reachable: connection refused")

(* 19. The section on the box is its own line, and an entry whose job could not
       be read is counted and located rather than dropped or named. *)
let test_render_crontab_row_shows_counts_and_names () =
  let output =
    rendered
      ~crontab:
        (Crontab.Section
           {
             entries =
               [ Crontab.Named "daily-close"; Crontab.Unnamed { position = 2 } ];
           })
      (report ())
  in
  let row = line_naming "bondi section" output in
  check bool "the section is counted" true (contains row ~needle:"2 jobs");
  check bool "the job it could name is named" true
    (contains row ~needle:"daily-close");
  check bool "the entry it could not read is located" true
    (contains row ~needle:"entry 2 could not be read")

(* 20. The machine-readable form carries the same two accounts, so a consumer
       reading it is no more able to pick a winner than a reader of the table. *)
let test_render_json_carries_provenance () =
  let drifted =
    orchestrator_container
      ~name:(container_name "ibgateway")
      ~image:"ghcr.io/org/ibgateway" ~tag:"10.47.0" ~state:"running"
  in
  let output =
    Report.render_json
      [
        one_server
          (report ~orchestrator:(Ok [ orchestrator_over_http; drifted ]) ());
      ]
  in
  let json = Yojson.Safe.from_string output in
  let field name value =
    match value with
    | `Assoc fields -> (
        match List.assoc_opt name fields with
        | Some found -> found
        | None -> failf "expected a %s field in %s" name output)
    | `String _
    | `Int _
    | `Float _
    | `Bool _
    | `Null
    | `List _
    | `Intlit _ ->
        failf "expected an object to read %s from, got %s" name output
  in
  let rendered value = Yojson.Safe.to_string value in
  let gateway =
    match field "infrastructure" (field "1.2.3.4" json) with
    | `List rows -> (
        match
          List.find_opt
            (fun row ->
              String.equal
                (rendered (field "name" row))
                (rendered (`String (container_name "ibgateway"))))
            rows
        with
        | Some row -> row
        | None ->
            failf "expected an infrastructure row for the gateway in %s" output)
    | `Assoc _
    | `String _
    | `Int _
    | `Float _
    | `Bool _
    | `Null
    | `Intlit _ ->
        failf "expected infrastructure to be a list in %s" output
  in
  check string "the host's tag is carried under its own source" {|"10.48.1e"|}
    (rendered (field "tag" (field "docker" gateway)));
  check string "the orchestrator's tag is carried under its own source"
    {|"10.47.0"|}
    (rendered (field "tag" (field "orchestrator" gateway)));
  check string "and the difference is flagged" "true"
    (rendered (field "disagreement" gateway))

(* --- Waiting on declared health ---

   Only [setup] waits, and only where a healthcheck is declared; the verdict it
   gets back is folded onto the row and decides the run's exit code. The four
   arms below are one requirement split two ways — two verdicts that must fail
   the run and two that must not — because [exit_failure] answering a constant
   satisfies either half on its own.

   The container is fixed as one whose check the host has recorded no verdict
   for yet, which is the state a freshly run container is in and is what a wait
   exists to resolve. Varying only the verdict handed in is what makes both the
   exit code and the rendered cell attributable to it. *)

let gateway_still_starting =
  host_container
    ~name:(container_name "ibgateway")
    ~image:"ghcr.io/org/ibgateway" ~tag:"10.48.1e" ~state:"running"
    ~health:Inventory.Starting

let starting_on_the_box =
  Inventory.Observed [ orchestrator_on_the_box; gateway_still_starting ]

let waited verdict =
  report ~docker:starting_on_the_box
    ~waits:[ (container_name "ibgateway", verdict) ]
    ()

let gateway_line rows = line_naming (container_name "ibgateway") (rendered rows)

(* 21. A component that never reached healthy inside the bound is what the wait
       exists to catch: the run does not get to claim success, and the row names
       the bound the host actually waited out rather than the one this client
       meant to ask for. *)
let test_report_exit_failure_on_timeout () =
  let rows = waited (Health.Timed_out { seconds = 120 }) in
  check bool "a component that never became healthy fails the run" true
    (Report.exit_failure rows);
  let line = gateway_line rows in
  check bool "and the row names the bound the host waited out" true
    (contains line ~needle:"120");
  check bool "without the cell ever reading as a pass" false
    (contains line ~needle:"healthy")

(* 22. A wait that could not be taken has established nothing, so it cannot
       establish success either. The exit code has two values and cannot say
       which of the two happened, so the row has to. *)
let test_report_exit_failure_on_unreadable_health () =
  let unreadable =
    waited (Health.Unreadable "command failed (255): Connection closed")
  in
  check bool "a health that could not be read fails the run too" true
    (Report.exit_failure unreadable);
  let unreadable_line = gateway_line unreadable in
  check bool "and the row says the read is what failed" true
    (contains unreadable_line ~needle:"Connection closed");
  check bool "which is not how a timeout reads" false
    (String.equal unreadable_line
       (gateway_line (waited (Health.Timed_out { seconds = 120 }))))

(* 23. The trap the other three arms exist to catch: a container with no
       healthcheck has passed nothing, and a verdict derived by negating "did it
       pass" would fail every run on every such container — which is every
       container this project ships today. *)
let test_report_no_healthcheck_is_not_failure () =
  let rows = waited Health.No_healthcheck in
  check bool "a container with no healthcheck does not fail the run" false
    (Report.exit_failure rows);
  let line = gateway_line rows in
  check bool "and the cell says there is none to pass" true
    (contains line ~needle:"no healthcheck defined");
  check bool "rather than reading as a pass" false
    (contains line ~needle:"healthy")

(* 24. Its affirmative arm, and the one proving [status] gains nothing: a check
       that passed does not fail the run, and a report nothing waited on carries
       the health the host had recorded instead of a verdict it never took. *)
let test_report_healthy_is_not_failure () =
  let rows = waited Health.Healthy in
  check bool "a component that passed its healthcheck does not fail the run"
    false (Report.exit_failure rows);
  check bool "and the row says it passed" true
    (Test_helpers.contains_word (gateway_line rows) ~word:"healthy");
  let unwaited = report ~docker:starting_on_the_box () in
  check bool "a report nothing waited on does not fail the run either" false
    (Report.exit_failure unwaited);
  check bool "and shows what the host had recorded, not a verdict" true
    (contains (gateway_line unwaited) ~needle:"starting")

(* 25. [setup] converges what the configuration declares, and its exit code says
       whether it managed to. A container nothing declares is on the box for
       reasons this run neither knows nor touches — an operator's own, a
       leftover the next run removes — and letting one decide the exit code
       hands the answer to something outside the question. The row still carries
       the verdict, because the report's job is to show what is there; the exit
       code's job is narrower.

       Both arms come off one fixture differing only in which name the failing
       verdict is attached to, so the exit code can only have turned on
       declaration. *)
let test_report_exit_failure_ignores_undeclared_containers () =
  let stray =
    host_container ~name:"someone-elses-worker" ~image:"legacy/worker" ~tag:"3"
      ~state:"running" ~health:Inventory.Starting
  in
  let docker =
    Inventory.Observed
      [ orchestrator_on_the_box; gateway_still_starting; stray ]
  in
  let failing = Health.Timed_out { seconds = 120 } in
  let undeclared_failed =
    report ~docker ~waits:[ ("someone-elses-worker", failing) ] ()
  in
  check bool "a container nothing declares does not fail the run" false
    (Report.exit_failure undeclared_failed);
  check bool "though its row still carries the verdict" true
    (contains
       (line_naming "someone-elses-worker" (rendered undeclared_failed))
       ~needle:"120");
  let declared_failed =
    report ~docker ~waits:[ (container_name "ibgateway", failing) ] ()
  in
  check bool "the same verdict on a declared component does fail the run" true
    (Report.exit_failure declared_failed)

(* 26. A source that could not be consulted and a source that answered with
       something this client cannot read are different failures, and an operator
       acts differently on each: the first sends them to the network, the second
       to a version skew between this client and that orchestrator. Rendering
       the second as "not reachable" sends them to the wrong one, and the body
       that would have shown them which is gone by then.

       Both arms come off one row differing only in which unavailability the
       orchestrator carries. *)
let test_report_an_unreadable_answer_is_not_an_unreachable_source () =
  let rendered_with unavailability =
    rendered
      (report ~orchestrator:(Error unavailability) ~docker:starting_on_the_box
         ())
  in
  let unreachable = rendered_with (Report.Not_consulted "connection refused") in
  check bool "a source that could not be consulted says it was not reachable"
    true
    (contains unreachable ~needle:"not reachable");
  let unreadable =
    rendered_with
      (Report.Not_understood
         "error decoding status response: body was {\"unexpected\":true}")
  in
  check bool
    "a source that answered unreadably does not claim to be unreachable" false
    (contains unreadable ~needle:"not reachable");
  check bool "and says that its answer is what could not be read" true
    (contains unreadable ~needle:"could not be read");
  check bool "carrying the answer it could not read" true
    (contains unreadable ~needle:"unexpected")

(* 27. The two sources split an image reference with two different parsers, and
       for a digest-pinned image they disagree on where the split falls. The
       host is read here, by a parser that knows a digest names no tag:
       [old/worker@sha256:abc] is the whole image. The orchestrator's side is
       produced by the server's [parse_image_and_tag], which splits on a colon
       and hands back [old/worker@sha256] with a tag of [abc].

       Nothing about the container differs — it is one container, described by
       two parsers — so flagging it reports drift where there is none, on every
       run, forever. A flag that is always lit is a flag nobody reads, which
       costs the report the one finding it exists to make.

       The second arm is what stops the fix going too far: two genuinely
       different images must still be a disagreement. *)
let test_report_a_digest_split_two_ways_is_not_a_disagreement () =
  let pinned = "old/worker@sha256:abc123" in
  let host_side =
    host_container ~name:"worker" ~image:pinned ~tag:"" ~state:"running"
      ~health:Inventory.No_healthcheck
  in
  let orchestrator_side =
    orchestrator_container ~name:"worker" ~image:"old/worker@sha256"
      ~tag:"abc123" ~state:"running"
  in
  let rows =
    report
      ~docker:(Inventory.Observed [ orchestrator_on_the_box; host_side ])
      ~orchestrator:(Ok [ orchestrator_over_http; orchestrator_side ])
      ()
  in
  check bool "one container described by two parsers is not two containers"
    false
    (Report.disagrees (row_named "worker" rows));
  let genuinely_different =
    orchestrator_container ~name:"worker" ~image:"old/worker@sha256"
      ~tag:"def456" ~state:"running"
  in
  let drifted =
    report
      ~docker:(Inventory.Observed [ orchestrator_on_the_box; host_side ])
      ~orchestrator:(Ok [ orchestrator_over_http; genuinely_different ])
      ()
  in
  check bool "two different images still are" true
    (Report.disagrees (row_named "worker" drifted))

let () =
  run "Status_report"
    [
      ( "rows",
        [
          test_case "a row exists without the orchestrator" `Quick
            test_report_row_exists_without_http;
          test_case "a row exists without docker" `Quick
            test_report_row_exists_without_ssh;
          test_case "an unreachable orchestrator is a row" `Quick
            test_report_orchestrator_unreachable_row_is_present;
          test_case "a reachable orchestrator is a row" `Quick
            test_report_orchestrator_reachable_row_is_present;
          test_case "a declared component neither source has" `Quick
            test_report_declared_absent;
          test_case "an observed container nothing declares" `Quick
            test_report_observed_undeclared_is_flagged;
          test_case "answered and found nothing is not could not ask" `Quick
            test_report_source_absent_is_not_source_unavailable;
        ] );
      ( "disagreement",
        [
          test_case "agreement is not a disagreement" `Quick
            test_report_agreement_is_not_disagreement;
          test_case "both values are kept" `Quick
            test_report_disagreement_keeps_both_values;
          test_case "a differing image is detected" `Quick
            test_report_disagreement_on_image_is_detected;
          test_case "a differing state is detected" `Quick
            test_report_disagreement_on_state_is_detected;
        ] );
      ( "render",
        [
          test_case "each source is named on its own account" `Quick
            test_render_shows_provenance_per_source;
          test_case "a disagreement shows both and is flagged" `Quick
            test_render_disagreement_shows_both_and_flags;
          test_case "no healthcheck is not a positive" `Quick
            test_render_no_healthcheck_is_not_a_positive;
          test_case "a passing healthcheck renders as healthy" `Quick
            test_render_healthy_renders_as_healthy;
          test_case "an undeclared container is flagged" `Quick
            test_render_undeclared_is_flagged;
          test_case "rows the host could not confirm are flagged" `Quick
            test_render_http_only_rows_flagged_unverified;
          test_case "a source that could not be consulted is a line" `Quick
            test_render_unreachable_source_is_a_line;
          test_case "a source's message stays on one line" `Quick
            test_render_keeps_a_source_message_on_one_line;
          test_case "the crontab section is counted and named" `Quick
            test_render_crontab_row_shows_counts_and_names;
          test_case "json carries both accounts" `Quick
            test_render_json_carries_provenance;
        ] );
      ( "health wait",
        [
          test_case "a timeout fails the run" `Quick
            test_report_exit_failure_on_timeout;
          test_case "a health that could not be read fails the run" `Quick
            test_report_exit_failure_on_unreadable_health;
          test_case "no healthcheck is not a failure" `Quick
            test_report_no_healthcheck_is_not_failure;
          test_case "a passing healthcheck is not a failure" `Quick
            test_report_healthy_is_not_failure;
          test_case "an undeclared container does not decide the exit code"
            `Quick test_report_exit_failure_ignores_undeclared_containers;
        ] );
      ( "agreement",
        [
          test_case "a digest split two ways is not a disagreement" `Quick
            test_report_a_digest_split_two_ways_is_not_a_disagreement;
        ] );
      ( "unavailability",
        [
          test_case "an unreadable answer is not an unreachable source" `Quick
            test_report_an_unreadable_answer_is_not_an_unreachable_source;
        ] );
    ]
