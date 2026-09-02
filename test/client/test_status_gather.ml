open Alcotest
module Gather = Bondi_client.Status_gather
module Report = Bondi_client.Status_report
module Inventory = Bondi_client.Host_inventory
module Crontab = Bondi_client.Crontab_listing
module Config_file = Bondi_client.Config_file

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
let read_output_of contents = "BONDI_CRONTAB_CONTENTS\n" ^ contents

let spool_output =
  read_output_of
    "# BEGIN BONDI CRON\n\
     0 6 * * * curl -s -d '{\"job\":\"daily-close\",\"secret\":\"s3cr3t\"}' \
     http://127.0.0.1:3030/api/v1/run\n\
     # END BONDI CRON\n"

let spool_without_a_section =
  read_output_of "0 3 * * * /usr/local/bin/backup.sh\n"

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
    ?(crontab = Ok spool_output) ?(orchestrator = Ok orchestrator_reading) () =
  Gather.reading_of_reads ~listing ~inspection ~crontab ~orchestrator

(* Taking a reading and waiting on health are separate calls, and these cases
   are about the first: nothing here waited, which is also what the command that
   only reports a state passes. *)
let report_of reading =
  Gather.report_of_reading ~config ~address:"10.0.0.1" ~waits:[] reading

(* --- Reading a reading without reaching for a partial function --- *)

let containers_of (reading : Gather.reading) =
  match reading.docker with
  | Inventory.Observed containers -> containers
  | Inventory.Unreadable_listing message ->
      failf "expected the host listing to have been read, got: %s" message

let unreadable_listing_of (reading : Gather.reading) =
  match reading.docker with
  | Inventory.Unreadable_listing message -> message
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
    reading ~listing:(Error "Missing ssh configuration for server 10.0.0.1")
      ~inspection:(Error "Missing ssh configuration for server 10.0.0.1")
      ~crontab:(Error "Missing ssh configuration for server 10.0.0.1") ()
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
    reading ~listing:(Error "Permission denied (publickey).")
      ~inspection:(Error "Permission denied (publickey).")
      ~crontab:(Error "Permission denied (publickey).")
      ~orchestrator:(Error (Report.Not_consulted "connection refused")) ()
  in
  let rows = (report_of reading).rows in
  check (list string) "both declared components are rows"
    [ "my-service"; "bondi-orchestrator" ]
    (List.map (fun (row : Report.row) -> row.name) rows);
  check string "the host says why it could not answer"
    "Permission denied (publickey)."
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
  check string "a read that never happened says so"
    "unreadable: cat: /var/spool/cron/crontabs/root: Permission denied"
    (crontab_name
       (reading
          ~crontab:
            (Error "cat: /var/spool/cron/crontabs/root: Permission denied") ())
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
      (reading ~crontab:(Error "denied") ()).crontab;
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
        ] );
    ]
