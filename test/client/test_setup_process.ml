open Alcotest
module Setup = Bondi_client.Cmd.Setup

let contains ~needle hay = Bondi_common.String_utils.contains ~needle hay

(* A remote command that exits without draining its stdin closes the pipe while
   the payload is still being written. With SIGPIPE at its default disposition
   the signal terminates the client outright, so the exit status is never
   reported and `bondi setup` dies with no message — this test takes the whole
   runner down with it rather than failing. The payload has to exceed the pipe
   buffer (~64 KiB) for the write to reach the closed pipe at all; a short one
   is buffered and never notices. *)
let test_run_command_with_input_reports_early_exit () =
  let payload = String.make 200_000 'x' in
  match Setup.run_command_with_input "exit 7" payload with
  | Ok _ -> fail "expected the command's non-zero exit to be reported"
  | Error message ->
      check bool "reports the exit status" true (contains ~needle:"(7)" message)

(* Affirmative arm: a command that does read its input still succeeds and sees
   the payload, so the arm above cannot pass by the write silently doing
   nothing. *)
let test_run_command_with_input_delivers_payload () =
  match Setup.run_command_with_input "cat" "hello stdin" with
  | Error message -> fail message
  (* [read_all] terminates every line it reads, so the echoed payload comes
     back newline-terminated; call sites trim. *)
  | Ok output ->
      check string "payload reaches the command" "hello stdin\n" output

(* The disposition is restored, so ignoring SIGPIPE for the write does not
   leak into the rest of the process. *)
let test_run_command_with_input_restores_sigpipe () =
  let before = Sys.signal Sys.sigpipe Sys.Signal_default in
  Sys.set_signal Sys.sigpipe before;
  let (_ : (string, string) result) =
    Setup.run_command_with_input "cat" "hello"
  in
  let after = Sys.signal Sys.sigpipe Sys.Signal_default in
  Sys.set_signal Sys.sigpipe after;
  check bool "sigpipe disposition unchanged" true (before = after)

let () =
  run "Setup.process"
    [
      ( "run_command_with_input",
        [
          test_case "reports a command that exits without reading stdin" `Quick
            test_run_command_with_input_reports_early_exit;
          test_case "delivers the payload to a command that reads it" `Quick
            test_run_command_with_input_delivers_payload;
          test_case "restores the SIGPIPE disposition" `Quick
            test_run_command_with_input_restores_sigpipe;
        ] );
    ]
