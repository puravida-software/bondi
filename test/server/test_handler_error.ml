open Alcotest
module Handler_error = Bondi_server__Handler_error

let invalid = Handler_error.Invalid_request "image has no tag"

let orchestrator =
  Handler_error.Orchestrator_failure "docker daemon unreachable"

let not_ready = Handler_error.Not_ready "the crontab spool is not writable"

(* The range check below iterates a list, and a list is the one thing the
   compiler cannot check for completeness. Naming each arm here is what makes
   the omission a build failure instead of a silent narrowing: a constructor
   added to the variant makes this [function] inexhaustive in this file, which
   is where the missing coverage would otherwise have gone unnoticed. The
   result labels the failing check, so the arm that broke is named. *)
let arm_name = function
  | Handler_error.Invalid_request _ -> "Invalid_request"
  | Handler_error.Orchestrator_failure _ -> "Orchestrator_failure"
  | Handler_error.Not_ready _ -> "Not_ready"

let all_arms = [ invalid; orchestrator; not_ready ]

let test_http_status_per_class () =
  check int "a request that was wrong as written answers 400" 400
    (Dream.status_to_int (Handler_error.http_status invalid));
  check int "a fault on Bondi's side answers 500" 500
    (Dream.status_to_int (Handler_error.http_status orchestrator));
  check int "a box that is not ready to serve answers 503" 503
    (Dream.status_to_int (Handler_error.http_status not_ready))

let test_exit_code_per_class () =
  check int "a request that was wrong as written exits 2" 2
    (Handler_error.exit_code invalid);
  check int "a fault on Bondi's side exits 1" 1
    (Handler_error.exit_code orchestrator)

(* The readiness verdict is a third kind of event and is owed a code of its own:
   an operator reading 1 cannot tell a box that failed a probe from a box whose
   request failed while it was serving, and the two need different next steps. *)
let test_readiness_failure_has_its_own_exit_code () =
  check int "a box that is not ready to serve exits 3" 3
    (Handler_error.exit_code not_ready);
  check bool "the readiness code is not the general-failure code" true
    (Handler_error.exit_code not_ready <> Handler_error.exit_code orchestrator);
  check bool "the readiness code is not the bad-request code" true
    (Handler_error.exit_code not_ready <> Handler_error.exit_code invalid)

(* Distinctness is asserted across the whole variant rather than pair by pair,
   so a class added later is covered by this assertion rather than owing a new
   one. The excluded range is cmdliner's own: the client returns 123 to 125 for
   its argument errors, so a server verdict landing there is read as the caller
   having mistyped a flag. That range is [observed] -- cmdliner 2.1.1 documents
   [Cmdliner.Cmd.Exit.some_error] as 123, [cli_error] as 124 and
   [internal_error] as 125, read in [_opam/lib/cmdliner/cmdliner.mli] on
   2026-09-05. *)
let test_every_class_has_a_distinct_code_in_range () =
  let codes = List.map Handler_error.exit_code all_arms in
  check int "every failure class has a code no other class uses"
    (List.length all_arms)
    (List.length (List.sort_uniq Int.compare codes));
  List.iter
    (fun arm ->
      let code = Handler_error.exit_code arm in
      let name = arm_name arm in
      check bool
        (name ^ " does not land in cmdliner's own range")
        true
        (code < 123 || code > 125))
    all_arms

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

(* The exit table is what [--help] documents, and the sentences beside the codes
   are read by an operator who has just seen one. Both halves come from the same
   variant the codes do: a class added later gains a row here by exhaustiveness,
   and the row cannot carry a code the class does not have. Asserted as set
   equality against [exit_code] over [all_arms] rather than against three
   literals, so a class added later is covered by this assertion rather than
   owing a new one. *)
let test_exit_documentation_covers_every_class_and_only_the_table () =
  let documented =
    List.sort Int.compare (List.map fst Handler_error.exit_documentation)
  in
  let chosen =
    List.sort Int.compare (List.map Handler_error.exit_code all_arms)
  in
  check (list int) "the documented codes are exactly the table's" chosen
    documented;
  List.iter
    (fun (code, doc) ->
      check bool
        (Printf.sprintf "%d is documented by a sentence" code)
        true
        (String.trim doc <> ""))
    Handler_error.exit_documentation

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
          test_case "readiness failure has its own exit code" `Quick
            test_readiness_failure_has_its_own_exit_code;
          test_case
            "every class has a distinct exit code in the permitted range" `Quick
            test_every_class_has_a_distinct_code_in_range;
          test_case "the exit documentation covers every class and only them"
            `Quick test_exit_documentation_covers_every_class_and_only_the_table;
        ] );
    ]
