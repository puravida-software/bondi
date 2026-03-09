open Alcotest
module Status = Bondi_server__Status
module Crontab = Bondi_server__Crontab

let component_status_testable =
  testable Status.pp_component_status Status.equal_component_status

let component_status_option_testable = option component_status_testable
let component_status_list_testable = list component_status_testable
let mk_container = Server_test_helpers.mk_container
let mk_inspect = Server_test_helpers.mk_inspect

(* --- Test helpers --- *)

let full_context : Status.status_context =
  {
    service_inspection =
      Some
        ( mk_container ~id:"svc1" ~image:"ghcr.io/org/myapp:v1.2.3"
            ~names:[ "/myapp" ] (),
          mk_inspect ~created_at:"2026-03-01T00:00:00Z" ~restart_count:2
            ~status:"running" () );
    orchestrator_inspection =
      Some
        ( mk_container ~id:"orch1" ~image:"ghcr.io/puravida/bondi-server:0.1.0"
            ~names:[ "/bondi-orchestrator" ] (),
          mk_inspect ~created_at:"2026-02-28T00:00:00Z" ~restart_count:0
            ~status:"running" () );
    traefik_inspection =
      Some
        ( mk_container ~id:"traefik1" ~image:"traefik:v3.3.3"
            ~names:[ "/bondi-traefik" ] (),
          mk_inspect ~created_at:"2026-02-28T00:00:00Z" ~restart_count:1
            ~status:"running" () );
    scheduled_cron_jobs =
      [
        { Crontab.name = "backup"; image = "ghcr.io/org/backup:v2.1.0" };
        { Crontab.name = "cleanup"; image = "ghcr.io/org/cleanup:latest" };
      ];
    cron_container_inspections = [];
    cron_error = None;
    alloy_inspection = None;
  }

(* 1. test_plan_all_found *)
let test_plan_all_found () =
  let result = Status.plan ~service_name:(Some "myapp") full_context in
  check component_status_option_testable "service present"
    (Some
       {
         Status.name = "myapp";
         image_name = "ghcr.io/org/myapp";
         tag = "v1.2.3";
         status = "running";
         restart_count = Some 2;
         created_at = Some "2026-03-01T00:00:00Z";
       })
    result.service;
  check component_status_option_testable "orchestrator present"
    (Some
       {
         Status.name = "bondi-orchestrator";
         image_name = "ghcr.io/puravida/bondi-server";
         tag = "0.1.0";
         status = "running";
         restart_count = Some 0;
         created_at = Some "2026-02-28T00:00:00Z";
       })
    result.infrastructure.orchestrator;
  check component_status_option_testable "traefik present"
    (Some
       {
         Status.name = "bondi-traefik";
         image_name = "traefik";
         tag = "v3.3.3";
         status = "running";
         restart_count = Some 1;
         created_at = Some "2026-02-28T00:00:00Z";
       })
    result.infrastructure.traefik;
  check int "two cron jobs" 2 (List.length result.cron_jobs)

(* 2. test_plan_no_service_name *)
let test_plan_no_service_name () =
  let result = Status.plan ~service_name:None full_context in
  check component_status_option_testable "service is None" None result.service

(* 3. test_plan_service_not_found *)
let test_plan_service_not_found () =
  let ctx = { full_context with service_inspection = None } in
  let result = Status.plan ~service_name:(Some "myapp") ctx in
  check component_status_option_testable "service is None when not found" None
    result.service

(* 4. test_plan_infrastructure_not_found *)
let test_plan_infrastructure_not_found () =
  let ctx =
    {
      full_context with
      orchestrator_inspection = None;
      traefik_inspection = None;
    }
  in
  let result = Status.plan ~service_name:(Some "myapp") ctx in
  check component_status_option_testable "orchestrator None" None
    result.infrastructure.orchestrator;
  check component_status_option_testable "traefik None" None
    result.infrastructure.traefik

(* 5. test_plan_cron_jobs_from_crontab *)
let test_plan_cron_jobs_from_crontab () =
  let result = Status.plan ~service_name:(Some "myapp") full_context in
  let expected : Status.component_status list =
    [
      {
        name = "backup";
        image_name = "ghcr.io/org/backup";
        tag = "v2.1.0";
        status = "scheduled";
        restart_count = None;
        created_at = None;
      };
      {
        name = "cleanup";
        image_name = "ghcr.io/org/cleanup";
        tag = "latest";
        status = "scheduled";
        restart_count = None;
        created_at = None;
      };
    ]
  in
  check component_status_list_testable "cron jobs mapped correctly" expected
    result.cron_jobs

(* 6. test_plan_no_cron_jobs *)
let test_plan_no_cron_jobs () =
  let ctx = { full_context with scheduled_cron_jobs = [] } in
  let result = Status.plan ~service_name:(Some "myapp") ctx in
  check component_status_list_testable "empty cron jobs" [] result.cron_jobs

(* 7. test_plan_image_tag_parsed *)
let test_plan_image_tag_parsed () =
  let result = Status.plan ~service_name:(Some "myapp") full_context in
  (* Service *)
  (match result.service with
  | Some s ->
      check string "service image_name" "ghcr.io/org/myapp" s.image_name;
      check string "service tag" "v1.2.3" s.tag
  | None -> fail "expected service to be present");
  (* Orchestrator *)
  (match result.infrastructure.orchestrator with
  | Some o ->
      check string "orchestrator image_name" "ghcr.io/puravida/bondi-server"
        o.image_name;
      check string "orchestrator tag" "0.1.0" o.tag
  | None -> fail "expected orchestrator to be present");
  (* Traefik *)
  (match result.infrastructure.traefik with
  | Some t ->
      check string "traefik image_name" "traefik" t.image_name;
      check string "traefik tag" "v3.3.3" t.tag
  | None -> fail "expected traefik to be present");
  (* Cron *)
  let first_cron = List.hd result.cron_jobs in
  check string "cron image_name" "ghcr.io/org/backup" first_cron.image_name;
  check string "cron tag" "v2.1.0" first_cron.tag

(* 8. test_plan_grouping *)
let test_plan_grouping () =
  let result = Status.plan ~service_name:(Some "myapp") full_context in
  (* Verify the response has the expected structure *)
  check bool "service is Some" true (Option.is_some result.service);
  check bool "cron_jobs is non-empty" true (result.cron_jobs <> []);
  check bool "orchestrator is Some" true
    (Option.is_some result.infrastructure.orchestrator);
  check bool "traefik is Some" true
    (Option.is_some result.infrastructure.traefik)

(* 9. test_plan_no_errors *)
let test_plan_no_errors () =
  let result = Status.plan ~service_name:(Some "myapp") full_context in
  check (list string) "no errors" [] result.errors

(* 10. test_plan_cron_error_propagation *)
let test_plan_cron_error_propagation () =
  let ctx =
    {
      full_context with
      scheduled_cron_jobs = [];
      cron_error = Some "Failed to read crontab: permission denied";
    }
  in
  let result = Status.plan ~service_name:(Some "myapp") ctx in
  check (list string) "error propagated"
    [ "Failed to read crontab: permission denied" ]
    result.errors;
  check
    (list component_status_testable)
    "cron jobs empty with error" [] result.cron_jobs

(* 11. test_plan_cron_job_completed *)
let test_plan_cron_job_completed () =
  let ctx =
    {
      full_context with
      scheduled_cron_jobs =
        [ { Crontab.name = "backup"; image = "ghcr.io/org/backup:v2.1.0" } ];
      cron_container_inspections =
        [
          ( "backup",
            mk_inspect ~created_at:"2026-03-01T12:00:00Z" ~restart_count:0
              ~status:"exited" ~exit_code:0 () );
        ];
    }
  in
  let result = Status.plan ~service_name:None ctx in
  let expected : Status.component_status =
    {
      name = "backup";
      image_name = "ghcr.io/org/backup";
      tag = "v2.1.0";
      status = "completed";
      restart_count = None;
      created_at = None;
    }
  in
  check component_status_list_testable "cron job completed" [ expected ]
    result.cron_jobs

(* 12. test_plan_cron_job_failed *)
let test_plan_cron_job_failed () =
  let ctx =
    {
      full_context with
      scheduled_cron_jobs =
        [ { Crontab.name = "backup"; image = "ghcr.io/org/backup:v2.1.0" } ];
      cron_container_inspections =
        [
          ( "backup",
            mk_inspect ~created_at:"2026-03-01T12:00:00Z" ~restart_count:0
              ~status:"exited" ~exit_code:1 () );
        ];
    }
  in
  let result = Status.plan ~service_name:None ctx in
  let expected : Status.component_status =
    {
      name = "backup";
      image_name = "ghcr.io/org/backup";
      tag = "v2.1.0";
      status = "failed (exit 1)";
      restart_count = None;
      created_at = None;
    }
  in
  check component_status_list_testable "cron job failed" [ expected ]
    result.cron_jobs

(* 13. test_plan_cron_job_no_container *)
let test_plan_cron_job_no_container () =
  let ctx =
    {
      full_context with
      scheduled_cron_jobs =
        [ { Crontab.name = "backup"; image = "ghcr.io/org/backup:v2.1.0" } ];
      cron_container_inspections = [];
    }
  in
  let result = Status.plan ~service_name:None ctx in
  let expected : Status.component_status =
    {
      name = "backup";
      image_name = "ghcr.io/org/backup";
      tag = "v2.1.0";
      status = "scheduled";
      restart_count = None;
      created_at = None;
    }
  in
  check component_status_list_testable "cron job scheduled" [ expected ]
    result.cron_jobs

(* 15. test_status_alloy_running *)
let test_status_alloy_running () =
  let ctx =
    {
      full_context with
      alloy_inspection =
        Some
          ( mk_container ~id:"alloy1" ~image:"grafana/alloy:v1.8.0"
              ~names:[ "/bondi-alloy" ] (),
            mk_inspect ~created_at:"2026-03-01T00:00:00Z" ~restart_count:0
              ~status:"running" () );
    }
  in
  let result = Status.plan ~service_name:(Some "myapp") ctx in
  check component_status_option_testable "alloy present"
    (Some
       {
         Status.name = "bondi-alloy";
         image_name = "grafana/alloy";
         tag = "v1.8.0";
         status = "running";
         restart_count = Some 0;
         created_at = Some "2026-03-01T00:00:00Z";
       })
    result.infrastructure.alloy

(* 16. test_status_alloy_not_configured *)
let test_status_alloy_not_configured () =
  let result = Status.plan ~service_name:(Some "myapp") full_context in
  check component_status_option_testable "alloy is None" None
    result.infrastructure.alloy

(* 17. test_status_alloy_stopped *)
let test_status_alloy_stopped () =
  let ctx =
    {
      full_context with
      alloy_inspection =
        Some
          ( mk_container ~id:"alloy1" ~image:"grafana/alloy:v1.8.0"
              ~names:[ "/bondi-alloy" ] ~state:(Some "exited")
              ~status:(Some "Exited (0)") (),
            mk_inspect ~created_at:"2026-03-01T00:00:00Z" ~restart_count:0
              ~status:"exited" ~exit_code:0 () );
    }
  in
  let result = Status.plan ~service_name:(Some "myapp") ctx in
  check component_status_option_testable "alloy stopped"
    (Some
       {
         Status.name = "bondi-alloy";
         image_name = "grafana/alloy";
         tag = "v1.8.0";
         status = "exited";
         restart_count = Some 0;
         created_at = Some "2026-03-01T00:00:00Z";
       })
    result.infrastructure.alloy

(* 14. test_plan_cron_job_running *)
let test_plan_cron_job_running () =
  let ctx =
    {
      full_context with
      scheduled_cron_jobs =
        [ { Crontab.name = "backup"; image = "ghcr.io/org/backup:v2.1.0" } ];
      cron_container_inspections =
        [
          ( "backup",
            mk_inspect ~created_at:"2026-03-01T12:00:00Z" ~restart_count:0
              ~status:"running" ~exit_code:0 () );
        ];
    }
  in
  let result = Status.plan ~service_name:None ctx in
  let expected : Status.component_status =
    {
      name = "backup";
      image_name = "ghcr.io/org/backup";
      tag = "v2.1.0";
      status = "running";
      restart_count = None;
      created_at = None;
    }
  in
  check component_status_list_testable "cron job running" [ expected ]
    result.cron_jobs

let () =
  run "Status.plan"
    [
      ( "plan",
        [
          test_case "all found" `Quick test_plan_all_found;
          test_case "no service name" `Quick test_plan_no_service_name;
          test_case "service not found" `Quick test_plan_service_not_found;
          test_case "infrastructure not found" `Quick
            test_plan_infrastructure_not_found;
          test_case "cron jobs from crontab" `Quick
            test_plan_cron_jobs_from_crontab;
          test_case "no cron jobs" `Quick test_plan_no_cron_jobs;
          test_case "image tag parsed" `Quick test_plan_image_tag_parsed;
          test_case "grouping" `Quick test_plan_grouping;
          test_case "no errors" `Quick test_plan_no_errors;
          test_case "cron error propagation" `Quick
            test_plan_cron_error_propagation;
          test_case "cron job completed" `Quick test_plan_cron_job_completed;
          test_case "cron job failed" `Quick test_plan_cron_job_failed;
          test_case "cron job no container" `Quick
            test_plan_cron_job_no_container;
          test_case "cron job running" `Quick test_plan_cron_job_running;
          test_case "alloy running" `Quick test_status_alloy_running;
          test_case "alloy not configured" `Quick
            test_status_alloy_not_configured;
          test_case "alloy stopped" `Quick test_status_alloy_stopped;
        ] );
    ]
