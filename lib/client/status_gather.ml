type orchestrator_reading = {
  components : Status_report.component list;
  warnings : string list;
}

type reading = {
  docker : Host_inventory.t;
  crontab : Crontab_listing.t;
  payloads : Cron_payload.listing;
  orchestrator : (orchestrator_reading, Status_report.unavailability) result;
}

let reading_of_reads ~listing ~inspection ~crontab ~payloads ~orchestrator =
  {
    docker = Host_inventory.of_reads ~listing ~inspection;
    crontab = Crontab_listing.of_read_output crontab;
    payloads = Cron_payload.of_listing_output payloads;
    orchestrator;
  }

let gather ?session ~timeout_seconds ~fetch server =
  reading_of_reads
    ~listing:
      (Remote_exec.docker_command_output ?session ~timeout_seconds
         ~command:Host_inventory.listing_command server)
    ~inspection:
      (Remote_exec.docker_command_output ?session ~timeout_seconds
         ~command:Host_inventory.inspection_command server)
    ~crontab:
      (Remote_exec.command_output ?session ~timeout_seconds
         ~command:Crontab_listing.read_command server)
    ~payloads:
      (Remote_exec.command_output ?session ~timeout_seconds
         ~command:Cron_payload.listing_command server)
    ~orchestrator:(fetch server)

(* A health wait is the one read whose bound cannot be chosen on its own: the
   command being run is itself a wait of [timeout_seconds] on the host, so an
   invocation bound at or below that number would cut off every container that
   takes its full budget to pass and report a box that answered as a box that
   did not. The slack over it is the connection and the polling loop's own turn,
   and it is added here rather than asked of the caller, which would be asking
   them to know what this command does on the far side. *)
let wait_slack_seconds = 30

let health_waits ?session ~timeout_seconds server docker =
  List.map
    (fun container_name ->
      ( container_name,
        Container_health.verdict_of_output
          (Remote_exec.command_output ?session
             ~timeout_seconds:(timeout_seconds + wait_slack_seconds)
             ~command:
               (Container_health.wait_command ~container_name ~timeout_seconds)
             server) ))
    (Host_inventory.health_to_wait_for docker)

let report_of_reading ~config ~address ~waits reading :
    Status_report.server_report =
  {
    address;
    rows =
      Status_report.rows ~config ~docker:reading.docker ~waits
        ~orchestrator:
          (Result.map
             (fun orchestrator -> orchestrator.components)
             reading.orchestrator);
    crontab = reading.crontab;
    payloads = reading.payloads;
    (* A source that could not be consulted contributes no warnings. Its silence
       is already on every row, and repeating it here would put the same failure
       in the report twice under two headings. *)
    warnings =
      (match reading.orchestrator with
      | Ok orchestrator -> orchestrator.warnings
      | Error _ -> []);
  }
