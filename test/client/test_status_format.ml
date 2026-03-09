open Alcotest
module Status = Bondi_client.Cmd.Status
module Config_file = Bondi_client.Config_file

(* --- Test helpers --- *)

let contains ~needle hay = Bondi_common.String_utils.contains ~needle hay

let mk_config ?user_service ?cron_jobs () : Config_file.t =
  {
    user_service;
    bondi_server = { version = "0.1.0" };
    traefik = None;
    cron_jobs;
    alloy = None;
  }

let mk_service name : Config_file.user_service =
  {
    name;
    image = "ghcr.io/org/myapp";
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
  }

let mk_cron_job name image ip : Config_file.cron_job =
  {
    name;
    image;
    schedule = "0 0 * * *";
    env_vars = None;
    registry_user = None;
    registry_pass = None;
    server = { ip_address = ip; ssh = None };
  }

let mk_component ~name ~image_name ~tag ~status ~restart_count ~created_at :
    Status.component_status =
  { name; image_name; tag; status; restart_count; created_at }

let full_service =
  mk_component ~name:"myapp" ~image_name:"ghcr.io/org/myapp" ~tag:"v1.2.3"
    ~status:"running" ~restart_count:(Some 2)
    ~created_at:(Some "2026-03-01T00:00:00Z")

let full_orchestrator =
  mk_component ~name:"bondi-orchestrator"
    ~image_name:"ghcr.io/puravida/bondi-server" ~tag:"0.1.0" ~status:"running"
    ~restart_count:(Some 0) ~created_at:(Some "2026-02-28T00:00:00Z")

let full_traefik =
  mk_component ~name:"bondi-traefik" ~image_name:"traefik" ~tag:"v3.3.3"
    ~status:"running" ~restart_count:(Some 1)
    ~created_at:(Some "2026-02-28T00:00:00Z")

let cron_backup =
  mk_component ~name:"backup" ~image_name:"ghcr.io/org/backup" ~tag:"v2.1.0"
    ~status:"scheduled" ~restart_count:None ~created_at:None

let cron_cleanup =
  mk_component ~name:"cleanup" ~image_name:"ghcr.io/org/cleanup" ~tag:"latest"
    ~status:"scheduled" ~restart_count:None ~created_at:None

let full_status : Status.comprehensive_status =
  {
    service = Some full_service;
    cron_jobs = [ cron_backup; cron_cleanup ];
    infrastructure =
      {
        orchestrator = Some full_orchestrator;
        traefik = Some full_traefik;
        alloy = None;
      };
    errors = [];
  }

(* 1. test_format_table_full — all components present → table with all sections *)
let test_format_table_full () =
  let config =
    mk_config ~user_service:(mk_service "myapp")
      ~cron_jobs:
        [
          mk_cron_job "backup" "ghcr.io/org/backup:v2.1.0" "1.2.3.4";
          mk_cron_job "cleanup" "ghcr.io/org/cleanup:latest" "1.2.3.4";
        ]
      ()
  in
  let result = Status.format_table ~config [ ("1.2.3.4", full_status) ] in
  (* Should contain all section headers *)
  check bool "has Service header" true (contains result ~needle:"Service");
  check bool "has Cron Jobs header" true (contains result ~needle:"Cron Jobs");
  check bool "has Infrastructure header" true
    (contains result ~needle:"Infrastructure");
  (* Should contain component names *)
  check bool "has myapp" true (contains result ~needle:"myapp");
  check bool "has backup" true (contains result ~needle:"backup");
  check bool "has cleanup" true (contains result ~needle:"cleanup");
  check bool "has bondi-orchestrator" true
    (contains result ~needle:"bondi-orchestrator");
  check bool "has bondi-traefik" true (contains result ~needle:"bondi-traefik");
  (* Should contain server IP *)
  check bool "has server IP" true (contains result ~needle:"1.2.3.4")

(* 2. test_format_table_no_service — no service in config/response → service section omitted *)
let test_format_table_no_service () =
  let config = mk_config () in
  let status : Status.comprehensive_status =
    {
      service = None;
      cron_jobs = [];
      infrastructure =
        {
          orchestrator = Some full_orchestrator;
          traefik = Some full_traefik;
          alloy = None;
        };
      errors = [];
    }
  in
  let result = Status.format_table ~config [ ("1.2.3.4", status) ] in
  check bool "no Service header" false (contains result ~needle:"Service");
  check bool "has Infrastructure header" true
    (contains result ~needle:"Infrastructure")

(* 3. test_format_table_not_found_service — service in config but None from server → "not found" row *)
let test_format_table_not_found_service () =
  let config = mk_config ~user_service:(mk_service "myapp") () in
  let status : Status.comprehensive_status =
    {
      service = None;
      cron_jobs = [];
      infrastructure =
        {
          orchestrator = Some full_orchestrator;
          traefik = Some full_traefik;
          alloy = None;
        };
      errors = [];
    }
  in
  let result = Status.format_table ~config [ ("1.2.3.4", status) ] in
  check bool "has Service header" true (contains result ~needle:"Service");
  check bool "has not found" true (contains result ~needle:"not found")

(* 4. test_format_table_not_found_cron — cron in config but absent from response → "not found" row *)
let test_format_table_not_found_cron () =
  let config =
    mk_config
      ~cron_jobs:[ mk_cron_job "backup" "ghcr.io/org/backup:v2.1.0" "1.2.3.4" ]
      ()
  in
  let status : Status.comprehensive_status =
    {
      service = None;
      cron_jobs = [];
      infrastructure =
        {
          orchestrator = Some full_orchestrator;
          traefik = Some full_traefik;
          alloy = None;
        };
      errors = [];
    }
  in
  let result = Status.format_table ~config [ ("1.2.3.4", status) ] in
  check bool "has Cron Jobs header" true (contains result ~needle:"Cron Jobs");
  check bool "has not found for backup" true
    (contains result ~needle:"not found")

(* 5. test_format_table_cron_restart_na — cron restart_count displays as "N/A" *)
let test_format_table_cron_restart_na () =
  let config =
    mk_config
      ~cron_jobs:[ mk_cron_job "backup" "ghcr.io/org/backup:v2.1.0" "1.2.3.4" ]
      ()
  in
  let status : Status.comprehensive_status =
    {
      service = None;
      cron_jobs = [ cron_backup ];
      infrastructure =
        {
          orchestrator = Some full_orchestrator;
          traefik = Some full_traefik;
          alloy = None;
        };
      errors = [];
    }
  in
  let result = Status.format_table ~config [ ("1.2.3.4", status) ] in
  check bool "has N/A for restart count" true (contains result ~needle:"N/A")

(* 6. test_format_table_errors — errors are displayed in table output *)
let test_format_table_errors () =
  let config = mk_config () in
  let status : Status.comprehensive_status =
    {
      service = None;
      cron_jobs = [];
      infrastructure =
        {
          orchestrator = Some full_orchestrator;
          traefik = Some full_traefik;
          alloy = None;
        };
      errors = [ "Failed to read crontab: permission denied" ];
    }
  in
  let result = Status.format_table ~config [ ("1.2.3.4", status) ] in
  check bool "has Warnings header" true (contains result ~needle:"Warnings");
  check bool "has error message" true
    (contains result ~needle:"Failed to read crontab: permission denied")

(* 7. test_format_json — JSON output matches expected structure *)
let test_format_json () =
  let result = Status.format_json [ ("1.2.3.4", full_status) ] in
  let json = Yojson.Safe.from_string result in
  (* Should be an object with the server IP as key *)
  match json with
  | `Assoc [ (ip, server_json) ] -> (
      check string "server IP key" "1.2.3.4" ip;
      (* Should have service, cron_jobs, infrastructure keys *)
      match server_json with
      | `Assoc fields ->
          let keys = List.map fst fields in
          check bool "has service key" true (List.mem "service" keys);
          check bool "has cron_jobs key" true (List.mem "cron_jobs" keys);
          check bool "has infrastructure key" true
            (List.mem "infrastructure" keys);
          check bool "has errors key" true (List.mem "errors" keys)
      | _ -> fail "expected server status to be an object")
  | _ -> fail "expected top-level object with single server key"

(* 8. test_format_table_with_alloy — alloy present in infrastructure → alloy row shown *)
let test_format_table_with_alloy () =
  let config = mk_config () in
  let alloy_component =
    mk_component ~name:"bondi-alloy" ~image_name:"grafana/alloy" ~tag:"v1.8.0"
      ~status:"running" ~restart_count:(Some 0)
      ~created_at:(Some "2026-03-01T00:00:00Z")
  in
  let status : Status.comprehensive_status =
    {
      service = None;
      cron_jobs = [];
      infrastructure =
        {
          orchestrator = Some full_orchestrator;
          traefik = Some full_traefik;
          alloy = Some alloy_component;
        };
      errors = [];
    }
  in
  let result = Status.format_table ~config [ ("1.2.3.4", status) ] in
  check bool "has Infrastructure header" true
    (contains result ~needle:"Infrastructure");
  check bool "has bondi-alloy" true (contains result ~needle:"bondi-alloy");
  check bool "has grafana/alloy" true (contains result ~needle:"grafana/alloy");
  check bool "has v1.8.0 tag" true (contains result ~needle:"v1.8.0")

let () =
  run "Status_format"
    [
      ( "format_table",
        [
          test_case "full status" `Quick test_format_table_full;
          test_case "no service" `Quick test_format_table_no_service;
          test_case "not found service" `Quick
            test_format_table_not_found_service;
          test_case "not found cron" `Quick test_format_table_not_found_cron;
          test_case "cron restart N/A" `Quick test_format_table_cron_restart_na;
          test_case "errors displayed" `Quick test_format_table_errors;
          test_case "with alloy" `Quick test_format_table_with_alloy;
        ] );
      ("format_json", [ test_case "json structure" `Quick test_format_json ]);
    ]
