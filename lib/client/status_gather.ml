type orchestrator_reading = {
  components : Status_report.component list;
  warnings : string list;
}

type reading = {
  docker : Host_inventory.t;
  crontab : Crontab_listing.t;
  orchestrator : (orchestrator_reading, Status_report.unavailability) result;
}

let reading_of_reads ~listing ~inspection ~crontab ~orchestrator =
  {
    docker = Host_inventory.of_reads ~listing ~inspection;
    crontab = Crontab_listing.of_read_output crontab;
    orchestrator;
  }

let gather ~fetch server =
  reading_of_reads
    ~listing:
      (Remote_exec.docker_command_output ~command:Host_inventory.listing_command
         server)
    ~inspection:
      (Remote_exec.docker_command_output
         ~command:Host_inventory.inspection_command server)
    ~crontab:
      (Remote_exec.command_output ~command:Crontab_listing.read_command server)
    ~orchestrator:(fetch server)

let health_waits ~timeout_seconds server docker =
  List.map
    (fun container_name ->
      ( container_name,
        Container_health.verdict_of_output
          (Remote_exec.command_output
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
    (* A source that could not be consulted contributes no warnings. Its silence
       is already on every row, and repeating it here would put the same failure
       in the report twice under two headings. *)
    warnings =
      (match reading.orchestrator with
      | Ok orchestrator -> orchestrator.warnings
      | Error _ -> []);
  }
