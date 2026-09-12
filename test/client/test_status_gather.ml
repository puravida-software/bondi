open Alcotest
module Gather = Bondi_client.Status_gather
module Report = Bondi_client.Status_report
module Inventory = Bondi_client.Host_inventory
module Crontab = Bondi_client.Crontab_listing
module Remote_exec = Bondi_client.Remote_exec
module Config_file = Bondi_client.Config_file
module Cron_payload = Bondi_client.Cron_payload
module Cron_exec_line = Bondi_common.Cron_exec_line
module Status_cmd = Bondi_client.Cmd.Status
module Container_health = Bondi_client.Container_health

(* Every arm named, so a seventh verdict is a compile error here rather than a
   case this suite renders as some other one. *)
let pp_verdict fmt (verdict : Container_health.verdict) =
  match verdict with
  | Container_health.Healthy -> Format.fprintf fmt "Healthy"
  | Container_health.Unhealthy detail ->
      Format.fprintf fmt "Unhealthy %S" detail
  | Container_health.No_healthcheck -> Format.fprintf fmt "No_healthcheck"
  | Container_health.Timed_out { seconds } ->
      Format.fprintf fmt "Timed_out { seconds = %d }" seconds
  | Container_health.Gone -> Format.fprintf fmt "Gone"
  | Container_health.Unreadable detail ->
      Format.fprintf fmt "Unreadable %S" detail

let verdicts = list (pair string (testable pp_verdict ( = )))

(* Both constructors named, so a third is a compile error here rather than a
   silently unrendered failure. *)
let unavailability_name (unavailability : Report.unavailability) =
  match unavailability with
  | Report.Not_consulted message -> message
  | Report.Not_understood message -> message

(* --- Fixtures ---

   This module is the one place where four reads, each of which may have failed
   on its own, collapse into a single reading. Every case below goes through
   [reading] varying exactly one of those four, so an outcome can only have come
   from the read the case changed.

   The strings are what the host actually prints for the commands this feature
   sends; they are not shaped for the parser's convenience. *)

let listing_output =
  "my-service\tacme/app:1.4.0\trunning\n\
   bondi-orchestrator\tmlopez1506/bondi-server:0.10.3\trunning\n"

let inspection_output =
  "/my-service\tdeclared\thealthy\t0\t2026-08-01T10:00:00.111111111Z\n\
   /bondi-orchestrator\tundeclared\t\t0\t2026-08-01T09:00:00.222222222Z\n"

(* What the read command prints when it managed to read the file: the marker
   that says the contents follow, and then the contents. *)
let read_output_of contents =
  "BONDI_CRONTAB_CONTENTS\n" ^ contents ^ "BONDI_CRONTAB_END\n"

let spool_output =
  read_output_of
    "# BEGIN BONDI CRON\n\
     0 6 * * * curl -s -d '{\"job\":\"daily-close\",\"secret\":\"s3cr3t\"}' \
     http://127.0.0.1:3030/api/v1/run\n\
     # END BONDI CRON\n"

let spool_without_a_section =
  read_output_of "0 3 * * * /usr/local/bin/backup.sh\n"

(* The job the section above fires, so the two reads in this module are about
   the same host rather than about two unrelated fixtures. *)
let payload_job = "daily-close"

(* The markers are the listing command's own words. A fixture of bare paths
   carries no marker, which the reader answers as "unknown" -- so a case built
   that way would assert nothing about a listing that was taken, and one that
   left off the closing marker would be a listing that stopped part-way through.
   The paths come from the writer's own module rather than being spelled here,
   so a fixture cannot go on passing after the two have drifted apart. *)
let payload_listing_output =
  String.concat "\n"
    [
      "BONDI_CRON_PAYLOAD_LISTED";
      Cron_exec_line.run_file_of payload_job;
      Cron_exec_line.env_file_of payload_job;
      "BONDI_CRON_PAYLOAD_END";
    ]

let orchestrator_reading : Gather.orchestrator_reading =
  {
    components =
      [
        {
          name = "my-service";
          observation =
            {
              image = "acme/app";
              tag = "1.4.0";
              state = "running";
              health = None;
              wait = None;
              restart_count = Some 0;
              created_at = Some "2026-08-01T10:00:00.111111111Z";
            };
        };
      ];
    warnings = [ "failed to inspect cron container nightly-close" ];
  }

let config : Config_file.t =
  {
    user_service =
      Some
        {
          name = "my-service";
          image = "acme/app";
          port = 8080;
          registry_user = None;
          registry_pass = None;
          env_vars = [];
          servers = [];
          drain_grace_period = None;
          deployment_strategy = None;
          health_timeout = None;
          poll_interval = None;
          logs = None;
        };
    bondi_server = { version = "0.10.3"; bind_address = None; api_token = None };
    traefik = None;
    cron_jobs = None;
    alloy = None;
    managed_containers = None;
  }

let reading ?(listing = Ok listing_output) ?(inspection = Ok inspection_output)
    ?(crontab = Ok spool_output) ?(payloads = Ok payload_listing_output)
    ?(orchestrator = Ok orchestrator_reading) () =
  Gather.reading_of_reads ~listing ~inspection ~crontab ~payloads ~orchestrator

(* Taking a reading and waiting on health are separate calls, and these cases
   are about the first: nothing here waited, which is also what the command that
   only reports a state passes. *)
let report_of reading =
  Gather.report_of_reading ~config ~address:"10.0.0.1" ~waits:[] reading

(* --- Reading a reading without reaching for a partial function --- *)

let containers_of (reading : Gather.reading) =
  match reading.docker with
  | Inventory.Observed containers -> containers
  | Inventory.Unreadable_listing failure ->
      failf "expected the host listing to have been read, got: %s"
        (Remote_exec.message failure)

let unreadable_listing_of (reading : Gather.reading) =
  match reading.docker with
  | Inventory.Unreadable_listing failure -> Remote_exec.message failure
  | Inventory.Observed containers ->
      failf "expected the host listing to have failed, got %d containers"
        (List.length containers)

let crontab_name (listing : Crontab.t) =
  match listing with
  | Crontab.Section { entries } ->
      Printf.sprintf "section of %d" (List.length entries)
  | Crontab.No_section -> "no section"
  | Crontab.Malformed Crontab.End_without_begin ->
      "malformed: end without begin"
  | Crontab.Malformed Crontab.Begin_without_end ->
      "malformed: begin without end"
  | Crontab.Malformed Crontab.Nested_begin -> "malformed: nested begin"
  | Crontab.Unreadable message -> "unreadable: " ^ message

(* All three constructors named, so a fourth outcome of the payload read is a
   compile error here rather than a listing the reading quietly drops. *)
let payloads_name (listing : Cron_payload.listing) =
  match listing with
  | Cron_payload.Payloads { files } -> String.concat " " files
  | Cron_payload.Root_absent -> "root absent"
  | Cron_payload.Unlisted message -> "unlisted: " ^ message

let row_named = Client_fixtures.row_named

let source_name ~source (view : Report.source_view) =
  match view with
  | Report.Reported observation ->
      Printf.sprintf "reported %s:%s %s" observation.image observation.tag
        observation.state
  | Report.Absent -> "absent"
  | Report.Unavailable unavailability ->
      failf "expected %s to have answered, got unavailable: %s" source
        (unavailability_name unavailability)

(* Which of the two a reading became, rather than what it said. Both arms carry
   the host's own words, so a check on the message alone passes against a report
   that has collapsed them. *)
let unavailable_state_of ~source (view : Report.source_view) =
  match view with
  | Report.Unavailable (Report.Not_consulted _) -> "not consulted"
  | Report.Unavailable (Report.Not_understood _) -> "not understood"
  | Report.Absent -> failf "expected %s to be unavailable, got absent" source
  | Report.Reported _ ->
      failf "expected %s to be unavailable, got a reported observation" source

let unavailable_of ~source (view : Report.source_view) =
  match view with
  | Report.Unavailable unavailability -> unavailability_name unavailability
  | Report.Absent -> failf "expected %s to be unavailable, got absent" source
  | Report.Reported _ ->
      failf "expected %s to be unavailable, got a reported observation" source

(* --- Tests --- *)

(* 1. The host answered and the orchestrator did not. This is the motivating
      failure, and the reading has to carry everything the host said while
      saying plainly that the other source was never consulted. *)
let test_gather_reading_without_http () =
  let reading =
    reading ~orchestrator:(Error (Report.Not_consulted "connection refused")) ()
  in
  check (list string) "the host's containers survive the other source failing"
    [ "my-service"; "bondi-orchestrator" ]
    (List.map
       (fun (container : Inventory.container) -> container.name)
       (containers_of reading));
  check string "and so does the crontab read" "section of 1"
    (crontab_name reading.crontab);
  let rows = (report_of reading).rows in
  check string "the row keeps the host's account"
    "reported acme/app:1.4.0 running"
    (source_name ~source:"docker" (row_named "my-service" rows).docker);
  check string "and names why the other source has none" "connection refused"
    (unavailable_of ~source:"the orchestrator"
       (row_named "my-service" rows).orchestrator)

(* 2. The other half of the same requirement, on the same fixture. Without it an
      implementation that never populates a reading at all passes case 1. *)
let test_gather_reading_without_ssh () =
  let reading =
    let unconfigured =
      Error (Remote_exec.Not_configured { server = "10.0.0.1" })
    in
    reading ~listing:unconfigured ~inspection:unconfigured ~crontab:unconfigured
      ()
  in
  check string "a listing that never ran is not an empty box"
    "Missing ssh configuration for server 10.0.0.1"
    (unreadable_listing_of reading);
  check string "and a spool that never opened is not a missing section"
    "unreadable: Missing ssh configuration for server 10.0.0.1"
    (crontab_name reading.crontab);
  let rows = (report_of reading).rows in
  check string "the row still carries what the other source said"
    "reported acme/app:1.4.0 running"
    (source_name ~source:"the orchestrator"
       (row_named "my-service" rows).orchestrator)

(* 3. Neither source answered. Every declared component still has a row: a report
      that empties itself is the report an operator loses when it is needed. *)
let test_gather_reading_from_neither () =
  let reading =
    let refused =
      Error
        (Remote_exec.Ssh_failed
           { code = 255; output = "Permission denied (publickey)." })
    in
    reading ~listing:refused ~inspection:refused ~crontab:refused
      ~orchestrator:(Error (Report.Not_consulted "connection refused")) ()
  in
  let rows = (report_of reading).rows in
  check (list string) "both declared components are rows"
    [ "my-service"; "bondi-orchestrator" ]
    (List.map (fun (row : Report.row) -> row.name) rows);
  check string "the host says why it could not answer"
    "the host was not reached (255): Permission denied (publickey)."
    (unavailable_of ~source:"docker"
       (row_named "bondi-orchestrator" rows).docker);
  check string "and so does the orchestrator" "connection refused"
    (unavailable_of ~source:"the orchestrator"
       (row_named "bondi-orchestrator" rows).orchestrator)

(* 4. Both answered. The reading hands each source's own account through
      untouched, so the merge is the only place either could be preferred. *)
let test_gather_reading_from_both () =
  let rows = (report_of (reading ())).rows in
  let service = row_named "my-service" rows in
  check string "the host's account" "reported acme/app:1.4.0 running"
    (source_name ~source:"docker" service.docker);
  check string "the orchestrator's, separately"
    "reported acme/app:1.4.0 running"
    (source_name ~source:"the orchestrator" service.orchestrator);
  check string "a component only the host has keeps the other source's answer"
    "absent"
    (source_name ~source:"the orchestrator"
       (row_named "bondi-orchestrator" rows).orchestrator)

(* 5. A spool read that failed and a spool with no markers are different facts
      about a host, and the pair is what stops the first collapsing into the
      second. Both arms are built from the same fixture. *)
let test_gather_crontab_read_is_its_own_outcome () =
  check string "a read the host ran and refused says so, and says which"
    "unreadable: the read ran on the host and failed: command failed (1): cat: \
     /var/spool/cron/crontabs/root: Permission denied"
    (crontab_name
       (reading
          ~crontab:
            (Error
               (Remote_exec.Command_failed
                  {
                    code = 1;
                    output =
                      "cat: /var/spool/cron/crontabs/root: Permission denied";
                  }))
          ())
         .crontab);
  check string "a file that was read and has no section says that instead"
    "no section"
    (crontab_name (reading ~crontab:(Ok spool_without_a_section) ()).crontab);
  (* Nothing the reading carries is a line of the spool, on any of the three
     outcomes: the payload in the fixture holds a secret so this can fail. *)
  List.iter
    (fun (listing : Crontab.t) ->
      match
        Bondi_common.String_utils.contains ~needle:"s3cr3t"
          (crontab_name listing)
      with
      | false -> ()
      | true -> fail "the crontab reading carried a line of the spool file")
    [
      (reading ()).crontab;
      (reading ~crontab:(Ok spool_without_a_section) ()).crontab;
      (reading
         ~crontab:
           (Error (Remote_exec.Command_failed { code = 1; output = "denied" }))
         ())
        .crontab;
    ]

(* 6. What the orchestrator reported alongside its components reaches the report,
      and a source that could not be consulted contributes none rather than an
      error line of its own — its silence is already a row. *)
let test_gather_warnings_come_from_the_orchestrator () =
  check (list string) "the orchestrator's own warnings are carried"
    [ "failed to inspect cron container nightly-close" ]
    (report_of (reading ())).warnings;
  check (list string) "an unreachable orchestrator contributes none" []
    (report_of
       (reading
          ~orchestrator:(Error (Report.Not_consulted "connection refused")) ()))
      .warnings;
  check string "and the report knows which server it is about" "10.0.0.1"
    (report_of (reading ())).address

(* 7. The end of the path the other cases only start. A remote read's outcome is
      taken here, handed to the inventory and rendered by the report, and the
      two failures an operator resolves in different places have to survive all
      three: an ssh client that never reached the box, and a box that ran the
      listing and refused it. The cases above prove each hop keeps the value;
      this one is the only thing that fails if a hop turns it back into a
      sentence. *)
let test_a_failed_listing_reaches_the_report_as_the_state_it_was () =
  let state_of listing =
    let rows = (report_of (reading ~listing ())).rows in
    unavailable_state_of ~source:"docker" (row_named "my-service" rows).docker
  in
  check string "an ssh client that never reached the box consulted nothing"
    "not consulted"
    (state_of
       (Error (Remote_exec.Ssh_failed { code = 255; output = "no route" })));
  check string "a box that ran the listing and refused it has answered"
    "not understood"
    (state_of
       (Error
          (Remote_exec.Command_failed
             { code = 1; output = "Cannot connect to the Docker daemon" })))

(* 8. The payload directory is the fifth read, and the reading has to carry what
      it answered. The fixture lists two real paths rather than none: an empty
      directory reads the same against an implementation that plumbed the
      argument through and one that never did. *)
let test_gather_reading_carries_the_payload_listing () =
  check string "the paths the directory answered with"
    (Cron_exec_line.run_file_of payload_job
    ^ " "
    ^ Cron_exec_line.env_file_of payload_job)
    (payloads_name (reading ()).payloads)

(* 9. The other half of the same requirement, and the affirmative arm for it is
      case 8 on the same fixture with only this read varied. A payload read that
      failed is a value in the reading -- it does not abort the other four and
      it does not become a report nobody receives. *)
let test_gather_payload_read_that_failed_is_a_value () =
  let reading =
    reading
      ~payloads:
        (Error
           (Remote_exec.Ssh_failed
              { code = 255; output = "Connection closed by 10.0.0.1 port 22" }))
      ()
  in
  check string "the failure is carried in the transport's own words"
    "unlisted: the host was not reached (255): Connection closed by 10.0.0.1 \
     port 22"
    (payloads_name reading.payloads);
  check (list string) "and the host's containers were not abandoned for it"
    [ "my-service"; "bondi-orchestrator" ]
    (List.map
       (fun (container : Inventory.container) -> container.name)
       (containers_of reading));
  check string "nor was the crontab" "section of 1"
    (crontab_name reading.crontab)

(* 10. The link case 8 stops one short of. A reading that carries the listing
       and a report that drops it is the whole of the defect this closes, and it
       is invisible from either end alone: the reading is right and the table
       says the host's directory was never read. *)
let test_report_carries_the_payload_listing () =
  check string "the report carries what the directory answered"
    (Cron_exec_line.run_file_of payload_job
    ^ " "
    ^ Cron_exec_line.env_file_of payload_job)
    (payloads_name (report_of (reading ())).payloads)

(* An unroutable address, RFC 5737 TEST-NET-1, behind a stub [ssh]: were the
   stub ever to stop being resolved the operator's own client would run, spend
   its connect timeout and answer nothing, and the counts below would fail
   loudly rather than pass quietly. *)
let unroutable_server : Config_file.server =
  {
    ip_address = "192.0.2.1";
    ssh =
      Some
        { user = "deploy"; private_key_contents = "KEY"; private_key_pass = "" };
    port = None;
  }

(* [reading_of_reads] is checked above against plain data and the runner is
   checked in its own suite; neither says that the five reads this module makes
   are made over one staged key. The composition is where that is decided, so it
   is driven here, over a real spawn.

   The wait's inventory is built from the fixtures rather than from what the stub
   answered, because the stub answers nothing: what this case counts is how many
   keys the reads were handed, and a wait that had nothing to wait for would drop
   the fifth read and leave the count passing for the wrong reason. *)
let test_a_reading_is_gathered_inside_one_session () =
  let (), staged =
    Client_fixtures.staged_keys_during (fun () ->
        match
          Remote_exec.with_session ~timeout_seconds:60 unroutable_server
            (fun session ->
              let reading =
                Gather.gather ~session ~timeout_seconds:60
                  ~fetch:(fun _ ->
                    Error (Report.Not_consulted "no orchestrator read here"))
                  unroutable_server
              in
              (match reading.Gather.orchestrator with
              | Error (Report.Not_consulted message) ->
                  check string "the fetch's answer reaches the reading"
                    "no orchestrator read here" message
              | Error (Report.Not_understood message) ->
                  failf "the fetch was not asked, got unreadable: %s" message
              | Ok _ -> fail "the fetch answered that it was not consulted");
              let waits =
                Gather.health_waits ~session ~timeout_seconds:1
                  unroutable_server
                  (Inventory.of_reads ~listing:(Ok listing_output)
                     ~inspection:(Ok inspection_output))
              in
              check int "the inventory had one container to wait on" 1
                (List.length waits))
        with
        | Ok () -> ()
        | Error failure ->
            failf "the key can be staged here: %s" (Remote_exec.message failure))
  in
  check int "every read was made" 5 (List.length staged);
  check int "over one staged key" 1
    (List.length (List.sort_uniq String.compare staged))

(* [health_waits] is the one read whose invocation bound is not the caller's to
   choose: it adds slack over the wait the host is asked to perform, because a
   bound at the wait's own length reports a container that used its whole budget
   as a call that was given up on. That addition is worth nothing if the session
   the wait runs inside overrides it, and every caller of this function is on
   its way into one.

   The session here is opened at a second, below the wait itself and far below
   the wait plus its slack, so a runner that held the call to the session's
   number would cut the stub off before it answers and the verdict would be
   [Unreadable]. The stub sleeps past that and then answers healthy: a container
   that passes late in its budget, which is the case the slack exists for. *)
let test_a_health_wait_is_not_cut_off_by_the_session_it_runs_in () =
  Client_fixtures.with_ssh_stub
    "#!/bin/sh\nsleep 3\necho BONDI_CONTAINER_HEALTHY\n" (fun () ->
      match
        Remote_exec.with_session ~timeout_seconds:1 unroutable_server
          (fun session ->
            Gather.health_waits ~session ~timeout_seconds:1 unroutable_server
              (Inventory.of_reads ~listing:(Ok listing_output)
                 ~inspection:(Ok inspection_output)))
      with
      | Error failure ->
          failf "the key can be staged here: %s" (Remote_exec.message failure)
      | Ok waits ->
          check verdicts "the wait ran for its own bound and its slack"
            [ ("my-service", Container_health.Healthy) ]
            waits)

(* The orchestrator's account used to arrive over HTTP through a forwarded
   port, so a box that could not be reached produced a sentence about a socket
   this client had opened. It arrives from a command run on the box now, and
   what an unreachable box produces is the runner's own account of not having
   reached it -- which is the sentence that sends an operator to their key and
   the network rather than to the orchestrator.

   The needles are the transport's words rather than merely "some failure": an
   HTTP fetch against an address nothing listens on also fails, and a case that
   only asserted failure would pass against the transport this feature
   removes. *)
let test_the_orchestrator_read_is_a_remote_exec_outcome () =
  Client_fixtures.with_ssh_stub
    "#!/bin/sh\necho 'Permission denied (publickey).' >&2\nexit 255\n"
    (fun () ->
      match
        Status_cmd.orchestrator_reading ~service_name:None unroutable_server
      with
      | Ok _ -> fail "a host that was never reached has no reading to give"
      | Error (Report.Not_understood message) ->
          failf "the box said nothing, so nothing of its was misread: %s"
            message
      | Error (Report.Not_consulted message) ->
          check bool "the transport's own account of not reaching the host" true
            (Test_helpers.contains message
               ~needle:"the host was not reached (255)");
          check bool "carrying what ssh said while failing" true
            (Test_helpers.contains message
               ~needle:"Permission denied (publickey)."))

let () =
  run "status gather"
    [
      ( "reading",
        [
          test_case "the host alone" `Quick test_gather_reading_without_http;
          test_case "the orchestrator alone" `Quick
            test_gather_reading_without_ssh;
          test_case "neither source" `Quick test_gather_reading_from_neither;
          test_case "both sources" `Quick test_gather_reading_from_both;
          test_case "an unread spool is not a missing section" `Quick
            test_gather_crontab_read_is_its_own_outcome;
          test_case "warnings come from the orchestrator" `Quick
            test_gather_warnings_come_from_the_orchestrator;
          test_case "a failed listing keeps its state to the report" `Quick
            test_a_failed_listing_reaches_the_report_as_the_state_it_was;
          test_case "the payload directory's answer" `Quick
            test_gather_reading_carries_the_payload_listing;
          test_case "a payload read that failed is a value" `Quick
            test_gather_payload_read_that_failed_is_a_value;
          test_case "the report carries the payload listing" `Quick
            test_report_carries_the_payload_listing;
        ] );
      ( "taking the reading",
        [
          test_case "a reading is gathered inside one session" `Quick
            test_a_reading_is_gathered_inside_one_session;
          test_case "a health wait is not cut off by the session it runs in"
            `Quick test_a_health_wait_is_not_cut_off_by_the_session_it_runs_in;
          test_case "the orchestrator read is a remote-exec outcome" `Quick
            test_the_orchestrator_read_is_a_remote_exec_outcome;
        ] );
    ]
