open Alcotest
module Diagnostics = Bondi_server__Diagnostics
module String_utils = Bondi_common.String_utils

(* Whether a diagnostic line must also be written to PID 1's stderr is a
   question about a number, so both answers are checked here without a
   container. The pair is the whole boundary: nothing else in the suite reaches
   this decision, so an arm left out is a branch covered by nothing. *)

(* The absence arm. A writer that is already PID 1 owns the stream the engine
   captures, and duplicating into it emits the line twice -- observed, not
   assumed: a container whose PID 1 wrote one line to its own stderr and the
   same line to /proc/1/fd/2 showed both lines in the container log, with the
   write reporting success. The wrong answer here is therefore silent doubling
   rather than an error anyone would notice. *)
let test_pid_one_does_not_duplicate () =
  check bool "PID 1 already owns the stream the engine captures" false
    (Diagnostics.should_duplicate ~pid:1)

(* The affirmative arm, on the same function, so that the absence above is
   evidence rather than a constant [false] that would pin nothing. Two
   unrelated pids, because the claim is about every process that is not PID 1
   and not about one neighbouring number. *)
let test_any_other_pid_duplicates () =
  check bool "an exec'd process reaches the log only through PID 1" true
    (Diagnostics.should_duplicate ~pid:2);
  check bool "and does so whatever its own pid happens to be" true
    (Diagnostics.should_duplicate ~pid:31337)

(* The degradation notice goes to this process's own stderr, so a test that
   wants to know whether it was emitted has to read that stream. fd 2 is
   redirected for the duration of [emit] and put back afterwards; there is no
   other way to observe what a function writes to [Stdlib.stderr] short of
   handing the module a second sink to write it to, which would make the test
   about the seam rather than about the behaviour. *)
let own_stderr_during emit =
  let path = Filename.temp_file "bondi-diagnostics-own-stderr" ".txt" in
  flush stderr;
  let saved = Unix.dup Unix.stderr in
  let capture = Unix.openfile path [ Unix.O_WRONLY; Unix.O_TRUNC ] 0o600 in
  Unix.dup2 capture Unix.stderr;
  Unix.close capture;
  Fun.protect
    ~finally:(fun () ->
      flush stderr;
      Unix.dup2 saved Unix.stderr;
      Unix.close saved)
    emit;
  let channel = open_in_bin path in
  let captured = really_input_string channel (in_channel_length channel) in
  close_in channel;
  Sys.remove path;
  captured

let read_file path =
  let channel = open_in_bin path in
  let contents = really_input_string channel (in_channel_length channel) in
  close_in channel;
  contents

let notice = "diagnostics: cannot write to"
let line = "diagnostics test line"

(* Both arms below are anchored to a sink the test makes and removes. The one
   sink a test must not use is /proc/1/fd/2: whether that open is refused is a
   property of the uid of PID 1 on whichever machine is running the suite, so a
   test resting on it asserts the degradation path on a developer's box and the
   success path under a rootful CI container, with nothing able to tell which
   ran. *)
let reachable_sink () =
  let path = Filename.temp_file "bondi-diagnostics-sink" ".log" in
  (path, Diagnostics.sink_at ~path)

(* A regular file is created and the sink is placed one segment below it, so
   the open fails with ENOTDIR wherever the suite runs and as whatever uid it
   runs as. Manufactured rather than found, and removed afterwards. *)
let unreachable_sink () =
  let blocker = Filename.temp_file "bondi-diagnostics-blocker" ".not-a-dir" in
  let path = Filename.concat blocker "sink" in
  (blocker, path, Diagnostics.sink_at ~path)

(* The affirmative arm for the degradation test below: a sink that can be
   reached gets the line, and nothing is said about degradation. *)
let test_a_reachable_sink_receives_the_line () =
  check bool "the suite's own process is not PID 1, or this arm proves nothing"
    true
    (Diagnostics.should_duplicate ~pid:(Unix.getpid ()));
  let path, sink = reachable_sink () in
  let own = own_stderr_during (fun () -> Diagnostics.write_to sink line) in
  check string "the duplicate sink got the line, terminated" (line ^ "\n")
    (read_file path);
  check bool "and this process's own stderr got it as well" true
    (String_utils.contains ~needle:line own);
  check bool "with nothing said about degradation" false
    (String_utils.contains ~needle:notice own);
  Sys.remove path

(* The refusal arm. Three things have to hold at once for the contract to mean
   anything: the line survives on own stderr, the loss of the sink is
   announced, and it is announced once. The third is an assertion of absence,
   so it is followed by a sink that has not been given up on, which proves the
   silence is the latch rather than the notice having stopped working. *)
let test_a_refused_sink_degrades_and_says_so_once () =
  let blocker, path, sink = unreachable_sink () in
  let first = own_stderr_during (fun () -> Diagnostics.write_to sink line) in
  check bool "the line is on own stderr even though the duplicate failed" true
    (String_utils.contains ~needle:line first);
  check bool "the loss of the duplicate sink is announced" true
    (String_utils.contains ~needle:notice first);
  check bool "and the notice names the sink that was lost" true
    (String_utils.contains ~needle:path first);
  let second = own_stderr_during (fun () -> Diagnostics.write_to sink line) in
  check bool "the next line still reaches own stderr" true
    (String_utils.contains ~needle:line second);
  check bool "and is not announced a second time" false
    (String_utils.contains ~needle:notice second);
  let fresh_path, fresh = reachable_sink () in
  let elsewhere =
    own_stderr_during (fun () -> Diagnostics.write_to fresh line)
  in
  check string "a sink nothing was given up on is still written to"
    (line ^ "\n") (read_file fresh_path);
  check bool "and it is not silenced by the sink that was given up on" false
    (String_utils.contains ~needle:notice elsewhere);
  Sys.remove fresh_path;
  Sys.remove blocker

let pp_step formatter = function
  | Diagnostics.Advance { offset; remaining } ->
      Format.fprintf formatter "Advance {offset = %d; remaining = %d}" offset
        remaining
  | Diagnostics.Abandon reason -> Format.fprintf formatter "Abandon %S" reason

let equal_step left right =
  match (left, right) with
  | ( Diagnostics.Advance { offset; remaining },
      Diagnostics.Advance { offset = other_offset; remaining = other_remaining }
    ) ->
      offset = other_offset && remaining = other_remaining
  | Diagnostics.Abandon reason, Diagnostics.Abandon other ->
      String.equal reason other
  | (Diagnostics.Advance _ | Diagnostics.Abandon _), _ -> false

let step = testable pp_step equal_step

(* A short write is the ordinary case for a pipe and must resume where it
   stopped rather than start again, which would repeat what was already sent. *)
let test_a_partial_write_advances_by_what_moved () =
  check step "a short write leaves the rest to send"
    (Diagnostics.Advance { offset = 4; remaining = 6 })
    (Diagnostics.step_after ~offset:0 ~remaining:10 (Diagnostics.Wrote 4));
  check step "a write that took everything leaves nothing"
    (Diagnostics.Advance { offset = 10; remaining = 0 })
    (Diagnostics.step_after ~offset:0 ~remaining:10 (Diagnostics.Wrote 10))

(* The silent half of the defect this module exists to close: a write that
   moves nothing while bytes remain cannot make progress, and looping on it
   truncates a diagnostic rather than failing one. *)
let test_a_write_that_moved_nothing_is_abandoned () =
  check step "no bytes moved with bytes still to send is not progress"
    (Diagnostics.Abandon "the write moved no bytes")
    (Diagnostics.step_after ~offset:3 ~remaining:7 (Diagnostics.Wrote 0))

let test_an_interrupted_write_keeps_its_place () =
  check step "a signal before any byte moved has lost nothing"
    (Diagnostics.Advance { offset = 3; remaining = 7 })
    (Diagnostics.step_after ~offset:3 ~remaining:7 Diagnostics.Interrupted)

(* A non-blocking sink with no room is the stalled-reader case. The line is
   dropped rather than waited on, because waiting is what would stop the
   server. *)
let test_a_sink_with_no_room_is_abandoned () =
  check step "a sink that would have blocked drops the line instead"
    (Diagnostics.Abandon "the sink was not ready to accept the line")
    (Diagnostics.step_after ~offset:3 ~remaining:7 Diagnostics.Not_ready)

let () =
  run "diagnostics"
    [
      ( "duplication decision",
        [
          test_case "PID 1 does not duplicate" `Quick
            test_pid_one_does_not_duplicate;
          test_case "a pid other than 1 duplicates" `Quick
            test_any_other_pid_duplicates;
        ] );
      ( "writer",
        [
          test_case "a reachable sink receives the line" `Quick
            test_a_reachable_sink_receives_the_line;
          test_case "a refused sink degrades and says so once" `Quick
            test_a_refused_sink_degrades_and_says_so_once;
        ] );
      ( "partial writes",
        [
          test_case "a partial write advances by what moved" `Quick
            test_a_partial_write_advances_by_what_moved;
          test_case "a write that moved nothing is abandoned" `Quick
            test_a_write_that_moved_nothing_is_abandoned;
          test_case "an interrupted write keeps its place" `Quick
            test_an_interrupted_write_keeps_its_place;
          test_case "a sink with no room is abandoned" `Quick
            test_a_sink_with_no_room_is_abandoned;
        ] );
    ]
