open Alcotest
module Cmd_io = Bondi_server__Cmd_io
module Handler_error = Bondi_server__Handler_error

(* The module writes to this process's own stdout and stderr, which is the
   contract: a subcommand's caller is a shell reading fd 1 and fd 2, so a
   signature taking streams would be testing something other than what ships.
   The streams are therefore captured where a shell would capture them -- at the
   file descriptors -- and restored under [Fun.protect], because a test that
   raised while fd 1 pointed at a temporary file would leave every later test in
   the executable writing its Alcotest output there. *)
let read_file path = In_channel.with_open_bin path In_channel.input_all

let capture f =
  let out_path = Filename.temp_file "bondi_cmd_io_stdout" ".json" in
  let err_path = Filename.temp_file "bondi_cmd_io_stderr" ".txt" in
  let out_fd = Unix.openfile out_path [ Unix.O_WRONLY; Unix.O_TRUNC ] 0o600 in
  let err_fd = Unix.openfile err_path [ Unix.O_WRONLY; Unix.O_TRUNC ] 0o600 in
  let saved_out = Unix.dup Unix.stdout in
  let saved_err = Unix.dup Unix.stderr in
  flush stdout;
  flush stderr;
  Unix.dup2 out_fd Unix.stdout;
  Unix.dup2 err_fd Unix.stderr;
  let restore () =
    flush stdout;
    flush stderr;
    Unix.dup2 saved_out Unix.stdout;
    Unix.dup2 saved_err Unix.stderr;
    Unix.close saved_out;
    Unix.close saved_err;
    Unix.close out_fd;
    Unix.close err_fd
  in
  let value = Fun.protect ~finally:restore f in
  let written_out = read_file out_path in
  let written_err = read_file err_path in
  Sys.remove out_path;
  Sys.remove err_path;
  (value, written_out, written_err)

(* A stand-in for a route's response encoder. It is a real [Yojson.Safe.t]
   producer rather than a constant so that the bytes on stdout are asserted
   against a literal below, not against another call to the same encoder. *)
let encode service = `Assoc [ ("service", `String service) ]
let status_of result = capture (fun () -> Cmd_io.status_of result ~encode)

let test_a_success_exits_zero () =
  let code, _, _ = status_of (Ok "web") in
  check int "a success exits zero" 0 code

(* The three failure arms assert the literal code rather than a second call to
   [Handler_error.exit_code], which would pass against any table at all. The
   literals are the observable contract: the caller reading them is a shell
   comparing $? against a number. *)
let test_an_invalid_request_exits_with_its_own_code () =
  let code, written_out, written_err =
    status_of (Error (Handler_error.Invalid_request "image has no tag"))
  in
  check int "a request that was wrong as written exits 2" 2 code;
  check string "a failure writes nothing to stdout" "" written_out;
  check string "the failure's message goes to stderr" "image has no tag\n"
    written_err

let test_an_orchestrator_failure_exits_with_its_own_code () =
  let code, written_out, written_err =
    status_of
      (Error (Handler_error.Orchestrator_failure "docker daemon unreachable"))
  in
  check int "a fault on Bondi's side exits 1" 1 code;
  check string "a failure writes nothing to stdout" "" written_out;
  check string "the failure's message goes to stderr"
    "docker daemon unreachable\n" written_err

let test_a_readiness_failure_exits_with_its_own_code () =
  let code, written_out, written_err =
    status_of
      (Error (Handler_error.Not_ready "the crontab spool is not writable"))
  in
  check int "a box that is not ready to serve exits 3" 3 code;
  check string "a failure writes nothing to stdout" "" written_out;
  check string "the failure's message goes to stderr"
    "the crontab spool is not writable\n" written_err

(* "Nothing else" is an assertion of absence on stderr, and the three failure
   arms above are its affirmative arm on the same harness: they show the same
   capture producing non-empty stderr, so an implementation that never wrote
   there at all could not pass both. On stdout it is the trailing byte that is
   pinned: a subcommand writes the same bytes the corresponding route writes in
   its response body, and a newline the route does not send is a byte the
   subcommand must not add. *)
let test_a_success_writes_the_encoded_value_and_nothing_else () =
  let code, written_out, written_err = status_of (Ok "web") in
  check int "a success exits zero" 0 code;
  check string "stdout carries the encoder's bytes and no newline"
    {|{"service":"web"}|} written_out;
  check string "a success writes nothing to stderr" "" written_err

(* The failure write is a function of its own because three callers make it:
   [status_of]'s [Error] arm, [diagnostic_of]'s, and the serve action, which has
   no JSON answer at all. It is asserted here as the shared thing it is -- the
   message, the newline, the stream it lands on and the code it returns -- so
   that a change to any of those is one change in one place.

   The three classes below are asserted against literal codes rather than
   against a second call to [Handler_error.exit_code], which would pass against
   any table at all, and they cover every constructor the variant has: an
   assertion that the code comes from the class is worth nothing if it is made
   of one class.

   "Touches no stdout" is an absence, and its affirmative arm is the same
   [capture] harness writing stdout in the success case above and in both
   diagnostic cases below -- a capture that read fd 1 as empty whatever
   happened could not pass those. *)
let fail error = capture (fun () -> Cmd_io.fail error)

let test_a_failure_writes_its_message_to_stderr_alone () =
  let code, written_out, written_err =
    fail (Handler_error.Not_ready "the crontab spool is not writable")
  in
  check int "a box that is not ready to serve exits 3" 3 code;
  check string "the failure write touches no stdout" "" written_out;
  check string "the message goes to stderr, newline-terminated"
    "the crontab spool is not writable\n" written_err

let test_a_failure_takes_its_code_from_its_class () =
  let invalid, _, _ = fail (Handler_error.Invalid_request "image has no tag") in
  let orchestrator, _, _ =
    fail (Handler_error.Orchestrator_failure "docker daemon unreachable")
  in
  check int "a request that was wrong as written exits 2" 2 invalid;
  check int "a fault on Bondi's side exits 1" 1 orchestrator

(* [check] is the one subcommand whose document is worth reading in both
   outcomes: it names every probe it took and whether each passed, and the
   outcome a program acts on is the failing one. So the document is written on
   both arms and the reasons go to stderr beside it, rather than the [Ok]-only
   write [status_of] makes.

   The document handed in is a literal rather than a call to
   [Readiness.observations_to_yojson], because what is under test here is that
   the bytes given are the bytes written, not what the readiness encoder
   produces -- that is pinned in the readiness suite.

   The two arms are each other's affirmative arm on the same harness: the
   passing one asserts stderr empty and the failing one asserts it non-empty,
   and the failing one asserts stdout non-empty where [status_of]'s failure
   cases above assert it empty. So neither absence can be satisfied by a write
   that never happens. *)
let not_ready_document =
  `Assoc
    [
      ("ready", `Bool false);
      ("probes", `List [ `Assoc [ ("name", `String "docker_socket") ] ]);
    ]

let ready_document = `Assoc [ ("ready", `Bool true); ("probes", `List []) ]

let diagnostic_of verdict ~document =
  capture (fun () -> Cmd_io.diagnostic_of verdict ~document)

let test_a_passing_diagnostic_writes_its_document_and_exits_zero () =
  let code, written_out, written_err =
    diagnostic_of (Ok ()) ~document:ready_document
  in
  check int "a verdict that passed exits zero" 0 code;
  check string "stdout carries the document's bytes and no newline"
    {|{"ready":true,"probes":[]}|} written_out;
  check string "a passing verdict writes nothing to stderr" "" written_err

let test_a_failing_diagnostic_writes_its_document_as_well_as_its_reasons () =
  let code, written_out, written_err =
    diagnostic_of
      (Error (Handler_error.Not_ready "the Docker socket is not connectable"))
      ~document:not_ready_document
  in
  check int "a box that is not ready to serve exits 3" 3 code;
  check string "the document a program reads is on stdout on this arm too"
    {|{"ready":false,"probes":[{"name":"docker_socket"}]}|} written_out;
  check string "the reasons an operator reads are on stderr"
    "the Docker socket is not connectable\n" written_err

(* A payload arrives on stdin because it may carry credentials that must not
   appear in argv, and a deploy payload is JSON with embedded newlines. Reading
   it a line at a time would truncate at the first one and the truncation would
   surface as a decode failure with no hint of its cause, so the whole-stream
   read is pinned here rather than left to the subcommand that discovers it. *)
let test_stdin_is_read_whole () =
  let path = Filename.temp_file "bondi_cmd_io_stdin" ".json" in
  Out_channel.with_open_bin path (fun channel ->
      Out_channel.output_string channel "{\n  \"image\": \"web:1\"\n}");
  let payload_fd = Unix.openfile path [ Unix.O_RDONLY ] 0o600 in
  let saved_in = Unix.dup Unix.stdin in
  Unix.dup2 payload_fd Unix.stdin;
  let restore () =
    Unix.dup2 saved_in Unix.stdin;
    Unix.close saved_in;
    Unix.close payload_fd;
    Sys.remove path
  in
  let payload = Fun.protect ~finally:restore Cmd_io.read_stdin in
  check string "every byte of the payload is read, newlines included"
    "{\n  \"image\": \"web:1\"\n}" payload

let () =
  run "cmd_io"
    [
      ( "cmd io",
        [
          test_case "a success exits zero" `Quick test_a_success_exits_zero;
          test_case "an invalid request exits with its own code" `Quick
            test_an_invalid_request_exits_with_its_own_code;
          test_case "an orchestrator failure exits with its own code" `Quick
            test_an_orchestrator_failure_exits_with_its_own_code;
          test_case "a readiness failure exits with its own code" `Quick
            test_a_readiness_failure_exits_with_its_own_code;
          test_case "a success writes the encoded value and nothing else" `Quick
            test_a_success_writes_the_encoded_value_and_nothing_else;
          test_case "a failure writes its message to stderr alone" `Quick
            test_a_failure_writes_its_message_to_stderr_alone;
          test_case "a failure takes its code from its class" `Quick
            test_a_failure_takes_its_code_from_its_class;
          test_case "a passing diagnostic writes its document and exits zero"
            `Quick test_a_passing_diagnostic_writes_its_document_and_exits_zero;
          test_case
            "a failing diagnostic writes its document as well as its reasons"
            `Quick
            test_a_failing_diagnostic_writes_its_document_as_well_as_its_reasons;
          test_case "stdin is read whole" `Quick test_stdin_is_read_whole;
        ] );
    ]
