open Alcotest
module Handler_error = Bondi_server__Handler_error

let invalid = Handler_error.Invalid_request "image has no tag"

let orchestrator =
  Handler_error.Orchestrator_failure "docker daemon unreachable"

(* The range check below iterates a list, and a list is the one thing the
   compiler cannot check for completeness. Naming each arm here is what makes
   the omission a build failure instead of a silent narrowing: a constructor
   added to the variant makes this [function] inexhaustive in this file, which
   is where the missing coverage would otherwise have gone unnoticed. The
   result labels the failing check, so the arm that broke is named. *)
let arm_name = function
  | Handler_error.Invalid_request _ -> "Invalid_request"
  | Handler_error.Orchestrator_failure _ -> "Orchestrator_failure"

let all_arms = [ invalid; orchestrator ]

let test_http_status_per_class () =
  check int "a request that was wrong as written answers 400" 400
    (Dream.status_to_int (Handler_error.http_status invalid));
  check int "a fault on Bondi's side answers 500" 500
    (Dream.status_to_int (Handler_error.http_status orchestrator))

let test_exit_code_per_class () =
  check int "a request that was wrong as written exits 2" 2
    (Handler_error.exit_code invalid);
  check int "a fault on Bondi's side exits 1" 1
    (Handler_error.exit_code orchestrator)

(* The client reads 255 as ssh's own failure and 128 plus n as a signal, so a
   server verdict landing on either is reported to the operator as a different
   kind of event than it is; 0 would report a failure as a success. Written as
   an iteration over [all_arms] rather than as two named checks, so that a class
   added later is covered by the same assertion rather than owing a new one. *)
let test_exit_code_avoids_the_reserved_codes () =
  List.iter
    (fun arm ->
      let code = Handler_error.exit_code arm in
      let name = arm_name arm in
      check bool (name ^ " is not ssh's own failure") true (code <> 255);
      check bool (name ^ " is not a signal") true (code < 128);
      check bool (name ^ " does not report success") true (code > 0))
    all_arms

let () =
  run "handler_error"
    [
      ( "handler error",
        [
          test_case "http status is chosen per class" `Quick
            test_http_status_per_class;
          test_case "exit code is chosen per class" `Quick
            test_exit_code_per_class;
          test_case "exit code never collides with ssh's own or with a signal"
            `Quick test_exit_code_avoids_the_reserved_codes;
        ] );
    ]
