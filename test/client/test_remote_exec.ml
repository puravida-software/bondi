open Alcotest
module Remote_exec = Bondi_client.Remote_exec

let contains = Test_helpers.contains

(* The bound the cases that are not about the bound are made under: long enough
   that nothing in them can reach it, so a case about the error stream or the
   staged key never turns into a case about the clock. The two that are about it
   name their own. *)
let unbounded_enough = 600

let pp_failure fmt (f : Remote_exec.failure) =
  match f with
  | Remote_exec.Not_configured { server } ->
      Format.fprintf fmt "Not_configured { server = %S }" server
  | Remote_exec.Ssh_not_found { program } ->
      Format.fprintf fmt "Ssh_not_found { program = %S }" program
  | Remote_exec.Local_failure { reason } ->
      Format.fprintf fmt "Local_failure { reason = %S }" reason
  | Remote_exec.Ssh_failed { code; output } ->
      Format.fprintf fmt "Ssh_failed { code = %d; output = %S }" code output
  | Remote_exec.Command_failed { code; output } ->
      Format.fprintf fmt "Command_failed { code = %d; output = %S }" code output
  | Remote_exec.Signalled { signal; output } ->
      Format.fprintf fmt "Signalled { signal = %d; output = %S }" signal output
  | Remote_exec.Stopped { signal; output } ->
      Format.fprintf fmt "Stopped { signal = %d; output = %S }" signal output
  | Remote_exec.Timed_out { seconds; output } ->
      Format.fprintf fmt "Timed_out { seconds = %d; output = %S }" seconds
        output

let failure = testable pp_failure ( = )
let outcome = result string failure

let pp_ssh fmt (s : Bondi_client.Config_file.server_ssh) =
  Format.fprintf fmt "{ user = %S }" s.Bondi_client.Config_file.user

let ssh_result = result (testable pp_ssh ( = )) failure

(* The text ssh prints when it could not reach the host at all -- taken from the
   observation of 2026-09-03 against an unroutable address. Carried through the
   classifier untouched so the caller sees why, not only that. *)
let unreachable_output =
  "ssh: connect to host 192.0.2.1 port 22: Connection timed out\n"

(* ssh reserves 255 for its own failures, so a 255 is the client saying it never
   got as far as running anything. A caller that treats it as the remote
   command's verdict reports a box that could not be reached as a box that
   answered with something unreadable, and those are resolved in different
   places. *)
let test_ssh_own_failure_is_not_a_remote_failure () =
  check outcome "255 is ssh's own failure, carrying what ssh said"
    (Error (Remote_exec.Ssh_failed { code = 255; output = unreachable_output }))
    (Remote_exec.failure_of_status (Unix.WEXITED 255) ~output:unreachable_output)

(* Any other non-zero code reached the host: ssh ran the command and handed back
   what it exited with. The code itself is the value a caller may act on, so it
   survives as an int rather than as a digit inside a sentence. *)
let test_remote_non_zero_carries_its_own_code () =
  check outcome "7 is the remote command's own code"
    (Error (Remote_exec.Command_failed { code = 7; output = "boom\n" }))
    (Remote_exec.failure_of_status (Unix.WEXITED 7) ~output:"boom\n");
  check outcome "and so is a shell's not-found"
    (Error
       (Remote_exec.Command_failed
          { code = 127; output = "sh: no_such_binary: not found\n" }))
    (Remote_exec.failure_of_status (Unix.WEXITED 127)
       ~output:"sh: no_such_binary: not found\n")

(* A signal is neither of the two: the shell the runner spawns was killed while
   it waited, so there is no exit code to attribute to anybody. A stop is its own
   arm again, because it renders its own text.

   The numbers below are arbitrary inhabitants chosen to show that the arm
   carries whatever it is given. What the runtime actually delivers here is
   OCaml's own signal numbering, in which SIGTERM is -11; the interface says so
   where a caller reads. *)
let test_signalled_is_neither_of_the_two () =
  check outcome "a killed client is signalled, not exited"
    (Error (Remote_exec.Signalled { signal = 15; output = "" }))
    (Remote_exec.failure_of_status (Unix.WSIGNALED 15) ~output:"");
  check outcome "a stopped client is its own arm"
    (Error (Remote_exec.Stopped { signal = 19; output = "" }))
    (Remote_exec.failure_of_status (Unix.WSTOPPED 19) ~output:"")

(* Exit 0 is the only status that is not a failure, and the output comes back
   exactly as it was collected -- untrimmed, because a caller parsing a listing
   is entitled to the bytes the host printed.

   The second check is the affirmative arm on the same fixture: identical
   output, a non-zero code, and the classifier says failure. Without it the
   first check would still pass the day the classifier started answering [Ok]
   to everything. *)
let test_success_is_not_a_failure () =
  check outcome "exit 0 is success, output untouched" (Ok "  hello  \n")
    (Remote_exec.failure_of_status (Unix.WEXITED 0) ~output:"  hello  \n");
  check outcome "the same output at a non-zero code is not"
    (Error (Remote_exec.Command_failed { code = 1; output = "  hello  \n" }))
    (Remote_exec.failure_of_status (Unix.WEXITED 1) ~output:"  hello  \n")

(* Four of these five strings are what the two implementations this module
   replaces printed, and holding them byte-identical is what makes the existing
   unit and cram assertions evidence that the move preserved behaviour rather
   than a diff to re-baseline. The transport arm is the one that moved, for the
   reason the pair above gives, and every line that pinned its old wording moved
   with it in the same commit. Asserted as whole rendered strings, not as format
   strings. *)
let test_message_renders_the_text_each_shape_rendered_before () =
  check string "ssh's own failure renders as a host that was not reached"
    "the host was not reached (255): could not resolve hostname"
    (Remote_exec.message
       (Remote_exec.Ssh_failed
          { code = 255; output = "  could not resolve hostname \n" }));
  check string "a remote non-zero renders with its own code"
    "command failed (7): boom"
    (Remote_exec.message
       (Remote_exec.Command_failed { code = 7; output = "  boom  \n" }));
  check string "a signal renders as killed" "command killed (15): boom"
    (Remote_exec.message
       (Remote_exec.Signalled { signal = 15; output = "  boom  \n" }));
  check string "a stop renders as stopped" "command stopped (19): boom"
    (Remote_exec.message
       (Remote_exec.Stopped { signal = 19; output = "  boom  \n" }));
  check string "an unconsultable server names itself"
    "Missing ssh configuration for server 10.0.0.1"
    (Remote_exec.message (Remote_exec.Not_configured { server = "10.0.0.1" }))

(* A box that was never reached and a command the box ran and refused resolve in
   different places -- one sends an operator to the network, to this machine's
   configuration or to the key, the other to the host itself -- and until now
   both rendered through the same sentence. Shown "command failed" in the middle
   of a deploy for a box that was never reached, an operator goes to the wrong
   machine.

   The pair is asserted at one code on purpose. 255 is the only code the
   transport arm is ever built with, so the words are the whole of the
   difference and a reader cannot fall back on the number. The second case is
   also the affirmative arm for the first: without it, a [message] that had
   stopped saying anything at all would satisfy the absence above. *)
let test_ssh_failure_names_the_host_not_the_command () =
  let rendered =
    Remote_exec.message
      (Remote_exec.Ssh_failed
         { code = 255; output = "  Connection closed by 10.0.0.1 port 22 \n" })
  in
  check bool "a host that was never reached is not a command that failed" false
    (contains ~needle:"command failed" rendered);
  check string "it is the host that is named"
    "the host was not reached (255): Connection closed by 10.0.0.1 port 22"
    rendered

let test_command_failure_still_names_the_command () =
  check string "the host's own refusal reads as it always did"
    "command failed (255): Connection closed by 10.0.0.1 port 22"
    (Remote_exec.message
       (Remote_exec.Command_failed
          { code = 255; output = "  Connection closed by 10.0.0.1 port 22 \n" }))

let server_without_ssh : Bondi_client.Config_file.server =
  { ip_address = "10.0.0.1"; ssh = None; port = None }

let server_with_ssh : Bondi_client.Config_file.server =
  {
    ip_address = "10.0.0.1";
    ssh =
      Some
        { user = "deploy"; private_key_contents = "KEY"; private_key_pass = "" };
    port = None;
  }

(* A server with no [ssh] block is a source that cannot be consulted, which is a
   value the caller decides about -- not an exception, and not an error string
   it would have to read to find out what kind of failure it had.

   The second check is the affirmative arm: the same shape of fixture, an [ssh]
   block present, and the configuration comes back. It is what stops the first
   check from passing because the function rejects everything. *)
let test_unconfigured_server_is_an_arm_not_an_exception () =
  check ssh_result "no ssh block yields the arm, naming the server"
    (Error (Remote_exec.Not_configured { server = "10.0.0.1" }))
    (Remote_exec.ssh_config server_without_ssh);
  check ssh_result "an ssh block is returned"
    (Ok
       {
         Bondi_client.Config_file.user = "deploy";
         private_key_contents = "KEY";
         private_key_pass = "";
       })
    (Remote_exec.ssh_config server_with_ssh)

(* A real spawn whose exit status and output this test chooses.

   The runner spawns whatever [ssh] the operator's PATH resolves, so an
   executable of that name at the front of PATH is the entire substitution:
   there is no seam inside the runner, and every step it takes on the way to the
   spawn -- reading the configuration, writing the key, building the option set
   and the command line -- is still taken.

   The fixture below is addressed at 192.0.2.1, which RFC 5737 reserves as
   unroutable. Were the substitution ever to stop working, the operator's own
   client would run, spend its connect timeout and report 255, and these
   assertions would fail loudly rather than pass quietly. *)
let with_path = Client_fixtures.with_path
let with_ssh_stub = Client_fixtures.with_ssh_stub

let unroutable_server : Bondi_client.Config_file.server =
  {
    ip_address = "192.0.2.1";
    ssh =
      Some
        { user = "deploy"; private_key_contents = "KEY"; private_key_pass = "" };
    port = None;
  }

(* The classifier was decided on statuses this test suite made up, and the
   spawn is written here; neither half is evidence for the other, and the whole
   point of the pair is what they do together. So this drives the public entry
   point over a process that really exits 7 and asserts the code as a value.

   The first case also settles where standard error goes: the stub writes its
   line there, and it has to arrive in the output a caller is handed, because
   that text is the answer an unreadable reading is supposed to carry.

   Three arms on the same shape of stub. Without the exit-0 arm the pair above
   would still pass the day the runner started reporting every command as
   failed; without the 255 arm the classifier could have been dropped from the
   path entirely and nothing here would have noticed. *)
let test_runner_and_classifier_compose_over_a_real_non_zero_command () =
  with_ssh_stub "#!/bin/sh\necho 'docker: command not found' >&2\nexit 7\n"
    (fun () ->
      check outcome "the host's own exit code survives as a value"
        (Error
           (Remote_exec.Command_failed
              { code = 7; output = "docker: command not found\n" }))
        (Remote_exec.command_output ~timeout_seconds:unbounded_enough
           ~command:"docker ps" unroutable_server));
  with_ssh_stub "#!/bin/sh\nexit 255\n" (fun () ->
      check outcome "255 is still read as ssh's own failure"
        (Error (Remote_exec.Ssh_failed { code = 255; output = "" }))
        (Remote_exec.command_output ~timeout_seconds:unbounded_enough
           ~command:"docker ps" unroutable_server));
  with_ssh_stub "#!/bin/sh\necho ok\n" (fun () ->
      check outcome "and a command that exits 0 is not a failure at all"
        (Ok "ok\n")
        (Remote_exec.command_output ~timeout_seconds:unbounded_enough
           ~command:"docker ps" unroutable_server))

(* Standard error is what a failed call is reported with, and it is only that.
   A call that succeeded is the host answering the question it was asked, and
   the lines ssh and sudo write alongside that answer are not part of it: the
   first connection to any fresh host draws a "Permanently added ... to the list
   of known hosts" from the accept-new host-key policy, and a box whose name
   does not resolve draws a sudo warning. Setup reads these outputs by shape --
   the first non-empty line of a container listing, a whole-output comparison
   against an expected port binding -- so a warning ahead of the reading is read
   as the reading, and a healthy orchestrator becomes one to tear down.

   The second arm is the same noise at a non-zero exit, where the merge is the
   whole point: the answer says what the host found and the noise says why it
   could not be acted on, and an operator needs both. Without that arm the first
   would still pass the day standard error stopped being collected at all. *)
let test_standard_error_is_merged_on_a_failure_and_only_there () =
  with_ssh_stub
    "#!/bin/sh\n\
     echo 'mesg: ttyname failed: Inappropriate ioctl for device' >&2\n\
     echo BONDI_ACME_PRESENT\n" (fun () ->
      check outcome "a call that succeeded carries the answer alone"
        (Ok "BONDI_ACME_PRESENT\n")
        (Remote_exec.command_output ~timeout_seconds:unbounded_enough
           ~command:"acme probe" unroutable_server));
  with_ssh_stub
    "#!/bin/sh\n\
     echo BONDI_ACME_ABSENT\n\
     echo 'mesg: ttyname failed: Inappropriate ioctl for device' >&2\n\
     exit 1\n" (fun () ->
      check outcome "and one that failed carries the answer and the reason"
        (Error
           (Remote_exec.Command_failed
              {
                code = 1;
                output =
                  "BONDI_ACME_ABSENT\n\
                   mesg: ttyname failed: Inappropriate ioctl for device\n";
              }))
        (Remote_exec.command_output ~timeout_seconds:unbounded_enough
           ~command:"acme probe" unroutable_server))

(* One runner serves the fed and the unfed call, which is what stops the next
   caller that needs to feed a command from writing a second one -- the way the
   duplicate this module replaces came about.

   [cat] answers both arms from one stub, so the empty result below cannot be
   the stub failing to run: the same executable returns the payload when there
   is one. Not being fed is end of input at once, not this process's own
   terminal handed to a command on a deploy box. *)
let test_input_absent_and_present_use_the_one_runner () =
  with_ssh_stub "#!/bin/sh\ncat\n" (fun () ->
      check outcome "a command that is not fed reaches end of input at once"
        (Ok "")
        (Remote_exec.command_output ~timeout_seconds:unbounded_enough
           ~command:"cat" unroutable_server);
      check outcome "and a fed one is handed exactly what it was fed"
        (Ok "hello stdin\n")
        (Remote_exec.command_output ~input:"hello stdin"
           ~timeout_seconds:unbounded_enough ~command:"cat" unroutable_server))

(* A command that exits without draining its input closes the pipe while the
   payload is still being written. At its default disposition SIGPIPE terminates
   this process outright, so the exit status is never reported and the run dies
   with no message: this test takes the whole runner down with it rather than
   failing one assertion. The payload has to exceed the pipe buffer for the
   write to reach the closed pipe at all; a short one is buffered and never
   notices.

   The second arm is the same payload through a stub that reads it, and it is
   what stops the first from passing because the write quietly did nothing. *)
let test_a_fed_command_that_exits_early_does_not_kill_the_client () =
  let payload = String.make 200_000 'x' in
  with_ssh_stub "#!/bin/sh\nexit 7\n" (fun () ->
      check outcome "the exit status is reported rather than lost"
        (Error (Remote_exec.Command_failed { code = 7; output = "" }))
        (Remote_exec.command_output ~input:payload
           ~timeout_seconds:unbounded_enough ~command:"true" unroutable_server));
  with_ssh_stub "#!/bin/sh\nwc -c | tr -d ' '\n" (fun () ->
      check outcome "and a command that drains it receives every byte"
        (Ok "200000\n")
        (Remote_exec.command_output ~input:payload
           ~timeout_seconds:unbounded_enough ~command:"wc -c" unroutable_server))

(* A payload past the pipe buffer, fed to a command that is itself printing past
   the pipe buffer before it reads a byte of it. Neither half alone provokes
   anything: the case above already pushes 200 KB in, and passes, because its
   stub prints nothing until stdin closes; the case below already pulls 200 KB
   out, and passes, because nothing is being written while it does. Only the two
   at once close the circle -- this client blocked writing a pipe the command is
   not reading, the command blocked writing a pipe this client is not reading --
   and a caller sending a deploy payload to a command that reports as it works is
   exactly that shape.

   The stub's [awk] has only a BEGIN rule, so it exits without touching stdin;
   the [wc -c] after it is what the payload is delivered to. Both halves are
   asserted, because either on its own would pass against a runner that dropped
   the other: the tail is the payload arriving whole, and the length is the
   command's own output having been collected while that was still in flight.

   Bounded well short of [unbounded_enough] because the failure this case
   detects is a deadlock rather than a wrong answer, and a deadlock is only
   observable when something ends it. The number is a detector and not a
   measurement -- a fifth of a megabyte through two pipes on a loopback stub is
   milliseconds, so there are four orders of magnitude between the work and the
   bound, and no slow machine reaches it. *)
let long_enough_to_fail_visibly = 30

let interleaving_ssh_stub =
  "#!/bin/sh\n\
   awk 'BEGIN{s=\"\";for(i=0;i<1000;i++)s=s \"x\";for(j=0;j<200;j++)print s}'\n\
   wc -c | tr -d ' '\n"

let test_input_larger_than_a_pipe_buffer_is_delivered_whole () =
  let payload = String.make 200_000 'x' in
  with_ssh_stub interleaving_ssh_stub (fun () ->
      match
        Remote_exec.command_output ~input:payload
          ~timeout_seconds:long_enough_to_fail_visibly ~command:"wc -c"
          unroutable_server
      with
      | Error failure ->
          fail
            ("the stub exits zero and the payload fits the bound: "
            ^ Remote_exec.message failure)
      | Ok output ->
          check bool "every byte of the payload reached the command" true
            (String.ends_with ~suffix:"200000\n" output);
          check int
            "and the command's own output was collected while it was in flight"
            200_207 (String.length output))

(* Ignoring SIGPIPE is how the test above survives at all, and it is a change to
   a disposition that belongs to the whole process. Restoring it is therefore
   part of the runner's contract with every other thing this client does: a
   remote call that left the signal ignored would take a later write to a closed
   pipe -- one that nothing here is watching -- and turn a clean death into a
   silent one.

   Carried across, assertions unchanged, from the suite that covered this while
   the runner it tests lived in another file. Read through the public entry
   point now, so what is asserted is what a caller actually provokes. *)
let test_the_sigpipe_disposition_is_restored () =
  (* The disposition wanted afterwards is set here rather than read here. A
     sibling case in this executable has already driven the runner, so whatever
     is ambient at this point may be that call's leftover -- and a check that
     compares what it found before with what it finds after passes by comparing
     a leak with itself. Pinned to a known value instead, so the check is
     against the disposition this test chose. *)
  let ambient = Sys.signal Sys.sigpipe Sys.Signal_default in
  Fun.protect
    ~finally:(fun () -> Sys.set_signal Sys.sigpipe ambient)
    (fun () ->
      with_ssh_stub "#!/bin/sh\ncat\n" (fun () ->
          let (_ : (string, Remote_exec.failure) result) =
            Remote_exec.command_output ~input:"hello"
              ~timeout_seconds:unbounded_enough ~command:"cat" unroutable_server
          in
          ());
      let observed = Sys.signal Sys.sigpipe Sys.Signal_default in
      check bool "sigpipe disposition unchanged" true
        (observed = Sys.Signal_default))

(* The key is read back through the path [f] was handed, which is the only
   window in which it exists at all. *)
let read_file path =
  let ic = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () -> really_input_string ic (in_channel_length ic))

(* A key as an operator pastes it: not base64, and so not something to reject.
   The space and the dashes are what make that a fact rather than a hope. *)
let verbatim_key = "-----BEGIN OPENSSH PRIVATE KEY-----\nnot base64\n"

exception Raised_from_f of string

(* Key material must not outlive the call that needs it, and the path out that
   an implementation forgets is the one nobody drove: [f] raising. The exception
   carries the path, because the path is the thing the assertion needs and it
   exists nowhere else once the call is over.

   The second half is the same contract under a cleanup that finds nothing to
   remove -- a sweeper, or an [f] that moved the file itself. A removal that
   raises there is turned by [Fun.protect] into [Fun.Finally_raised], which
   reports the cleanup and discards the fault the caller was about to be told
   about. *)
let test_a_raising_call_leaves_no_key_and_still_reports_its_fault () =
  (match
     Remote_exec.with_temp_key verbatim_key (fun path ->
         raise (Raised_from_f path))
   with
  | () -> fail "the exception from [f] should have propagated"
  | exception Raised_from_f path ->
      check bool "the key file does not outlive the call" false
        (Sys.file_exists path));
  match
    Remote_exec.with_temp_key verbatim_key (fun path ->
        Sys.remove path;
        raise (Raised_from_f path))
  with
  | () -> fail "the exception from [f] should have propagated"
  | exception Raised_from_f _ -> ()

(* The mode is the whole reason the key is written here rather than by each
   caller: ssh refuses a key file others can read, and a key file others can
   read is a key others have. Asserted from inside the call, because from
   outside it there is nothing left to stat.

   The removal on the ordinary path out is the same contract as the raising one
   above, and it is what stops that test from passing against a function that
   never wrote anything. *)
let test_the_key_is_written_readable_by_its_owner_alone () =
  let path, permissions =
    Remote_exec.with_temp_key verbatim_key (fun path ->
        (path, (Unix.stat path).Unix.st_perm))
  in
  check int "readable and writable by its owner and nobody else" 0o600
    permissions;
  check bool "and gone once the call has returned" false (Sys.file_exists path)

(* A key is carried in the configuration either base64-encoded or verbatim, and
   the two are told apart by trying: a value that does not decode is one of the
   latter rather than a configuration to reject. Both arms are asserted through
   the file, which is the only place the decision is visible and the place the
   ssh client reads. *)
let test_both_shapes_of_configured_key_reach_disk () =
  check string "a value that decodes is written decoded" "bondi"
    (Remote_exec.with_temp_key "Ym9uZGk=" read_file);
  check string "and one that does not is written as it was given" verbatim_key
    (Remote_exec.with_temp_key verbatim_key read_file)

(* The private key's time on disk is a decision per server rather than per
   remote call: this client makes tens of calls against one box in a run, and a
   staging that comes with each of them is a crash window with each of them.

   The count of distinct key paths is asserted beside the count of invocations,
   because "one distinct path" is also what a session whose calls never ran
   reports -- and a stub that is never spawned records nothing at all. *)
let test_two_calls_in_one_session_stage_the_key_once () =
  let calls, staged =
    Client_fixtures.staged_keys_during (fun () ->
        Remote_exec.with_session ~timeout_seconds:unbounded_enough
          unroutable_server (fun session ->
            let first =
              Remote_exec.command_output ~session
                ~timeout_seconds:unbounded_enough ~command:"true"
                unroutable_server
            in
            let second =
              Remote_exec.command_output ~session
                ~timeout_seconds:unbounded_enough ~command:"true"
                unroutable_server
            in
            (first, second)))
  in
  (match calls with
  | Ok (first, second) ->
      check outcome "the first call reached the host" (Ok "") first;
      check outcome "the second call reached the host" (Ok "") second
  | Error staging ->
      fail ("the key can be staged here: " ^ Remote_exec.message staging));
  check int "both calls were made" 2 (List.length staged);
  check int "over one staged key" 1
    (List.length (List.sort_uniq String.compare staged))

(* Key material must not outlive the session that needed it, and the path out
   an implementation forgets is the one nobody drove: a body that raises. The
   path is read back from the stub because the session says nothing about it and
   the file is gone by the time the call returns.

   The ordinary path out is asserted first, so the raising case cannot pass
   against a session that never wrote a key at all. *)
let test_the_staged_key_does_not_outlive_the_session () =
  let path_of staged =
    match staged with
    | [ path ] -> path
    | [] -> fail "the stub recorded no invocation, so no key was staged"
    | _ :: _ :: _ -> fail "one call should have staged one key"
  in
  let (), staged =
    Client_fixtures.staged_keys_during (fun () ->
        match
          Remote_exec.with_session ~timeout_seconds:unbounded_enough
            unroutable_server (fun session ->
              Remote_exec.command_output ~session
                ~timeout_seconds:unbounded_enough ~command:"true"
                unroutable_server)
        with
        | Ok (Ok _) -> ()
        | Ok (Error _) -> fail "the stub exits zero"
        | Error _ -> fail "the key can be staged here")
  in
  check bool "the key does not outlive an ordinary session" false
    (Sys.file_exists (path_of staged));
  let (), staged =
    Client_fixtures.staged_keys_during (fun () ->
        match
          Remote_exec.with_session ~timeout_seconds:unbounded_enough
            unroutable_server (fun session ->
              check outcome "the call inside the session reached the host"
                (Ok "")
                (Remote_exec.command_output ~session
                   ~timeout_seconds:unbounded_enough ~command:"true"
                   unroutable_server);
              raise (Raised_from_f "from the session's body"))
        with
        | Ok () -> fail "the exception from the body should have propagated"
        | Error _ -> fail "the exception from the body should have propagated"
        | exception Raised_from_f _ -> ())
  in
  check bool "nor one the body left by raising" false
    (Sys.file_exists (path_of staged))

(* Which failures mean the host ran the command is one policy, and every caller
   that words a report around it asks the same question. Asked here, of the
   type, so that a further constructor is a compile error in one place rather
   than a second wording nobody sees.

   All six arms are asserted, not only the true one: the five that answer false
   are what stops a predicate that answers true to everything from passing. The
   bound's own arm is among them because [explain] words a report around this
   answer, and a timeout read as a host verdict would tell an operator the host
   ran their deploy and refused it -- when what happened is that this client
   stopped waiting and the work may still be going on. *)
let test_ran_on_host_names_the_one_answer_the_host_gave () =
  check bool "a non-zero exit is the host's own verdict" true
    (Remote_exec.ran_on_host
       (Remote_exec.Command_failed { code = 1; output = "" }));
  check bool "a server with no ssh block was never asked" false
    (Remote_exec.ran_on_host
       (Remote_exec.Not_configured { server = "10.0.0.1" }));
  check bool "ssh's own failure means nothing ran there" false
    (Remote_exec.ran_on_host
       (Remote_exec.Ssh_failed { code = 255; output = "" }));
  check bool "a killed local shell carries no host verdict" false
    (Remote_exec.ran_on_host
       (Remote_exec.Signalled { signal = 15; output = "" }));
  check bool "and neither does a stopped one" false
    (Remote_exec.ran_on_host (Remote_exec.Stopped { signal = 19; output = "" }));
  check bool "a call given up on carries none either" false
    (Remote_exec.ran_on_host
       (Remote_exec.Timed_out { seconds = 60; output = "" }))

(* Carried across, assertions unchanged, from the suite that covered these
   options while they lived in the module this one replaces.

   The report exists to be printed on exactly the runs that go wrong, and both
   commands that print one read the host over SSH first. A host that accepts the
   TCP connection and then stops answering -- a firewall that drops rather than
   refuses, a box that is wedged rather than down -- leaves [ssh] waiting with no
   deadline of its own, so the report is lost on one of the failures it exists
   to describe.

   The HTTP source was given a bound for this reason. This is the same bound on
   the source the report needs more: a host read is on its own sufficient to
   produce a report, and there are several of them per server plus one per
   container waited on. *)
let test_ssh_options_bound_a_host_that_stops_answering () =
  let options = String.concat " " Remote_exec.ssh_options in
  check bool "gives up on a connection that is never established" true
    (contains ~needle:"ConnectTimeout=" options);
  check bool "and on one that is established and then goes quiet" true
    (contains ~needle:"ServerAliveInterval=" options);
  check bool "after a bounded number of unanswered probes" true
    (contains ~needle:"ServerAliveCountMax=" options)

(* The options that were already there and are load-bearing for a different
   reason: a prompt is a wait with no deadline at all, and neither command that
   reads a host is attended by anyone who could answer one. *)
let test_ssh_options_never_prompt () =
  let options = String.concat " " Remote_exec.ssh_options in
  check bool "never asks for a password" true
    (contains ~needle:"BatchMode=yes" options);
  check bool "never asks about an unknown host key" true
    (contains ~needle:"StrictHostKeyChecking=" options)

(* A command whose standard error exceeds one pipe buffer, written before it
   says anything on standard output. A runner that drains one stream to end of
   file before starting on the other never reaches the second: the command
   blocks on the full error pipe, so the output pipe never reaches end of file
   and the call never returns. 200 KB is comfortably past the 64 KB a Linux
   pipe holds.

   [bondi docker logs] is the caller that provokes it -- [docker logs] writes
   the container's own error stream to its error stream -- and there is no
   deadline anywhere on this path, so the failure is a hang rather than an
   error. The second arm is the same shape on standard output, which is what
   stops the first from passing against a runner that simply stopped collecting
   standard error. *)
let large_stderr_stub =
  "#!/bin/sh\n\
   awk 'BEGIN{s=\"\";for(i=0;i<1000;i++)s=s \"x\";for(j=0;j<200;j++)print s}' \
   >&2\n\
   echo done\n"

let large_stdout_stub =
  "#!/bin/sh\n\
   awk 'BEGIN{s=\"\";for(i=0;i<1000;i++)s=s \"x\";for(j=0;j<200;j++)print s}'\n\
   echo done >&2\n"

let test_both_streams_are_drained_together () =
  with_ssh_stub large_stderr_stub (fun () ->
      check outcome "a command that fills the error pipe still returns"
        (Ok "done\n")
        (Remote_exec.command_output ~timeout_seconds:unbounded_enough
           ~command:"docker logs c" unroutable_server));
  with_ssh_stub large_stdout_stub (fun () ->
      match
        Remote_exec.command_output ~timeout_seconds:unbounded_enough
          ~command:"docker logs c" unroutable_server
      with
      | Error _ -> fail "the stub exits zero"
      | Ok output ->
          check int "and one that fills the output pipe returns all of it"
            200_200 (String.length output))

(* The two pass-through printers exist to show an operator what the container
   said, and a container says a good deal of it on standard error. The
   stdout-only rule is right for the probes setup reads by shape and wrong for
   these two, so the merge is asked for at the call rather than assumed either
   way.

   Both arms on one stub: without the default arm this would pass against a
   runner that merged unconditionally, which is the defect the stdout-only rule
   was introduced to fix. *)
let test_a_caller_may_ask_for_the_error_stream_on_a_successful_command () =
  with_ssh_stub "#!/bin/sh\necho 'from stdout'\necho 'from stderr' >&2\n"
    (fun () ->
      check outcome "asked for, the error stream arrives with the answer"
        (Ok "from stdout\nfrom stderr\n")
        (Remote_exec.command_output ~standard_error:Remote_exec.Merged_always
           ~timeout_seconds:unbounded_enough ~command:"logs c" unroutable_server);
      check outcome "and by default it does not" (Ok "from stdout\n")
        (Remote_exec.command_output ~timeout_seconds:unbounded_enough
           ~command:"logs c" unroutable_server))

(* An [ssh] that is not on this machine's PATH is the local shell exiting 127,
   which is the same code the host's own shell exits when the remote command
   does not exist. Read as the host's answer it authorises installing Docker on
   a box nobody asked to change, so the question is settled before the spawn:
   a client that is not there is this machine's failure and no host verdict at
   all.

   The second arm is the same call with a working stub on PATH, which is what
   stops the first from passing against a runner that never reaches a host. *)
let test_a_missing_local_ssh_is_not_the_hosts_answer () =
  let empty = Filename.temp_dir "bondi-no-ssh-" "" in
  Fun.protect
    ~finally:(fun () ->
      try Unix.rmdir empty with
      | Unix.Unix_error _ -> ())
    (fun () ->
      with_path empty (fun () ->
          match
            Remote_exec.command_output ~timeout_seconds:unbounded_enough
              ~command:"docker --version" unroutable_server
          with
          | Ok _ -> fail "there is no ssh to run"
          | Error observed ->
              check bool "no host ran anything, so there is no host verdict"
                false
                (Remote_exec.ran_on_host observed);
              check failure "and the arm says which client is missing"
                (Remote_exec.Ssh_not_found { program = "ssh" })
                observed));
  with_ssh_stub "#!/bin/sh\necho ok\n" (fun () ->
      check outcome "an ssh that is there is spawned as before" (Ok "ok\n")
        (Remote_exec.command_output ~timeout_seconds:unbounded_enough
           ~command:"docker --version" unroutable_server))

(* This client's own inability to make the call -- no temporary directory to
   write the key into, no descriptors left to spawn with -- is a failure it can
   describe, so it is a value rather than something a caller discovers by
   catching. [ran_on_host] is false for the same reason as above: nothing ran
   anywhere.

   The temporary directory is moved to a path that does not exist, which is what
   [Filename.temp_file] raises [Sys_error] on. The successful call ahead of it is
   not decoration: it forces the multiplexing directory, which is named once per
   process from the temporary directory in force at the time. *)
let test_a_client_that_cannot_write_its_key_reports_a_value () =
  with_ssh_stub "#!/bin/sh\necho ok\n" (fun () ->
      check outcome "the same call succeeds where the key can be written"
        (Ok "ok\n")
        (Remote_exec.command_output ~timeout_seconds:unbounded_enough
           ~command:"true" unroutable_server);
      let previous = Filename.get_temp_dir_name () in
      Filename.set_temp_dir_name
        (Filename.concat previous "bondi-absent-tmpdir");
      Fun.protect
        ~finally:(fun () -> Filename.set_temp_dir_name previous)
        (fun () ->
          match
            Remote_exec.command_output ~timeout_seconds:unbounded_enough
              ~command:"true" unroutable_server
          with
          | Ok _ -> fail "there is nowhere to write the key"
          | Error observed ->
              check bool "nothing ran on any host" false
                (Remote_exec.ran_on_host observed);
              check bool "and the arm is this machine's own" true
                (match observed with
                | Remote_exec.Local_failure _ -> true
                | Remote_exec.Not_configured _
                | Remote_exec.Ssh_not_found _
                | Remote_exec.Ssh_failed _
                | Remote_exec.Command_failed _
                | Remote_exec.Signalled _
                | Remote_exec.Stopped _
                | Remote_exec.Timed_out _ ->
                    false)))

(* The rendered message is printed to a terminal and pasted into reports, and
   the output it interpolates is whatever the failed command printed --
   [docker logs] on a chatty container is megabytes. The payload is what makes
   the message worth reading, so it is carried and bounded rather than dropped,
   and the marker says the bound was reached.

   The second arm is an output just under the bound, which is what stops the
   first from passing against a message that truncates everything. *)
let test_message_bounds_the_output_it_carries () =
  let long = String.make 10_000 'x' in
  let rendered =
    Remote_exec.message (Remote_exec.Command_failed { code = 1; output = long })
  in
  check bool "the bound is applied" true (String.length rendered < 3_000);
  check bool "and it says so rather than trailing off" true
    (contains ~needle:"truncated" rendered);
  let short = String.make 2_000 'x' in
  check string "an output within the bound is carried whole"
    ("command failed (1): " ^ short)
    (Remote_exec.message
       (Remote_exec.Command_failed { code = 1; output = short }))

(* One template was being spelled out by every caller that words a report
   around [ran_on_host]. The wording is the policy's, the noun is the caller's,
   and both arms are asserted so a helper that prefixed everything -- or
   nothing -- would be caught. *)
let test_explain_prefixes_only_the_host_s_own_answer () =
  check string "a host that answered is named as having answered"
    "the read ran on the host and failed: command failed (1): boom"
    (Remote_exec.explain ~subject:"the read"
       (Remote_exec.Command_failed { code = 1; output = "boom" }));
  check string "and one that was never reached is not"
    "the host was not reached (255): boom"
    (Remote_exec.explain ~subject:"the read"
       (Remote_exec.Ssh_failed { code = 255; output = "boom" }));
  check string "nor is one this client stopped waiting for"
    "the command did not finish within 60s and was given up on, and may still \
     be running on the host: boom"
    (Remote_exec.explain ~subject:"the read"
       (Remote_exec.Timed_out { seconds = 60; output = "boom" }))

(* The guarded [Command_failed] test that two setup probes each spelled out,
   asked of the type instead. A code that matches on any other arm would be
   the misreading the predicate exists to prevent. *)
let test_exited_with_is_the_hosts_own_code_alone () =
  check bool "the host's own code matches" true
    (Remote_exec.exited_with ~code:127
       (Remote_exec.Command_failed { code = 127; output = "" }));
  check bool "a different code does not" false
    (Remote_exec.exited_with ~code:127
       (Remote_exec.Command_failed { code = 1; output = "" }));
  check bool "and no other arm carries a host code at all" false
    (List.exists
       (Remote_exec.exited_with ~code:127)
       [
         Remote_exec.Not_configured { server = "10.0.0.1" };
         Remote_exec.Ssh_not_found { program = "ssh" };
         Remote_exec.Local_failure { reason = "no descriptors" };
         Remote_exec.Ssh_failed { code = 127; output = "" };
         Remote_exec.Signalled { signal = 127; output = "" };
         Remote_exec.Stopped { signal = 127; output = "" };
         Remote_exec.Timed_out { seconds = 127; output = "" };
       ])

(* The connection bounds in [ssh_options] cover a box that refuses and a box
   that goes quiet. Neither covers a host that took the command and is still
   running it: ssh waits for as long as the command does, and until this bound
   nothing said how long that may be.

   The two numbers here differ on purpose, and the one in force is the call's.
   A read that asks for a minute inside a session opened for a deploy's own
   half-hour is asking for a minute: a session that overrode it would hold a
   read of a wedged box to the deploy's whole budget, which is the wait the
   bound exists to end. The session names a different number so that a runner
   that took the session's would be caught, and neither would be visible if they
   agreed.

   The second arm is the same stub differing only in how long it sleeps. Without
   it a runner that gave up on every command would satisfy the first. *)
let sleeping_ssh_stub ~seconds =
  Printf.sprintf "#!/bin/sh\nsleep %d\necho awake\n" seconds

let call_bounded_by_its_own_number stub =
  with_ssh_stub stub (fun () ->
      Remote_exec.with_session ~timeout_seconds:600 unroutable_server
        (fun session ->
          Remote_exec.command_output ~session ~timeout_seconds:1
            ~command:"a command that takes its time" unroutable_server))

let test_a_command_that_outlives_its_bound_fails_with_the_bound_named () =
  match call_bounded_by_its_own_number (sleeping_ssh_stub ~seconds:3) with
  | Error staging ->
      fail ("the key can be staged here: " ^ Remote_exec.message staging)
  | Ok answer -> (
      check outcome "the call's own bound is the one it is held to"
        (Error (Remote_exec.Timed_out { seconds = 1; output = "" }))
        answer;
      match answer with
      | Ok output -> fail ("the command should not have finished: " ^ output)
      | Error failure ->
          check bool "and the text an operator reads names that bound" true
            (contains ~needle:"within 1s" (Remote_exec.message failure)))

(* A command given up on is still a failure with something to say, and what it
   managed to print before the bound passed is the half of it worth reading: a
   deploy killed at its bound had usually named the step it had reached. The
   stub speaks first and then sleeps past the bound, so the line is already
   drained when the deadline arrives and nothing but the carry could put it in
   the failure. *)
let test_what_a_command_said_before_its_bound_is_carried () =
  match
    call_bounded_by_its_own_number
      "#!/bin/sh\necho 'reached step two'\nsleep 3\n"
  with
  | Error staging ->
      fail ("the key can be staged here: " ^ Remote_exec.message staging)
  | Ok answer ->
      check outcome "the failure carries what the command managed to print"
        (Error
           (Remote_exec.Timed_out { seconds = 1; output = "reached step two\n" }))
        answer

let test_a_command_that_finishes_inside_its_bound_is_unaffected () =
  match call_bounded_by_its_own_number (sleeping_ssh_stub ~seconds:0) with
  | Error staging ->
      fail ("the key can be staged here: " ^ Remote_exec.message staging)
  | Ok answer ->
      check outcome "a command that answers in time answers as it always did"
        (Ok "awake\n") answer

let () =
  run "Remote_exec"
    [
      ( "classifying a process status",
        [
          test_case "ssh's own failure is not a remote failure" `Quick
            test_ssh_own_failure_is_not_a_remote_failure;
          test_case "a remote non-zero carries its own code" `Quick
            test_remote_non_zero_carries_its_own_code;
          test_case "signalled is neither of the two" `Quick
            test_signalled_is_neither_of_the_two;
          test_case "success is not a failure" `Quick
            test_success_is_not_a_failure;
        ] );
      ( "rendering a failure",
        [
          test_case "renders the text each shape rendered before" `Quick
            test_message_renders_the_text_each_shape_rendered_before;
          test_case "an ssh failure names the host, not the command" `Quick
            test_ssh_failure_names_the_host_not_the_command;
          test_case "a command failure still names the command" `Quick
            test_command_failure_still_names_the_command;
          test_case "bounds the output it carries" `Quick
            test_message_bounds_the_output_it_carries;
          test_case "an unconfigured server is an arm, not an exception" `Quick
            test_unconfigured_server_is_an_arm_not_an_exception;
        ] );
      ( "running a command on a server",
        [
          test_case
            "the runner and the classifier compose over a real non-zero command"
            `Quick
            test_runner_and_classifier_compose_over_a_real_non_zero_command;
          test_case "input absent and present use the one runner" `Quick
            test_input_absent_and_present_use_the_one_runner;
          test_case "a fed command that exits early does not kill the client"
            `Quick test_a_fed_command_that_exits_early_does_not_kill_the_client;
          test_case "restores the SIGPIPE disposition" `Quick
            test_the_sigpipe_disposition_is_restored;
          test_case "merges standard error on a failure and only there" `Quick
            test_standard_error_is_merged_on_a_failure_and_only_there;
          test_case "drains both streams together" `Quick
            test_both_streams_are_drained_together;
          test_case "a caller may ask for the error stream on success" `Quick
            test_a_caller_may_ask_for_the_error_stream_on_a_successful_command;
          test_case "a missing local ssh is not the host's answer" `Quick
            test_a_missing_local_ssh_is_not_the_hosts_answer;
          test_case "a client that cannot write its key reports a value" `Quick
            test_a_client_that_cannot_write_its_key_reports_a_value;
        ] );
      ( "input",
        [
          test_case "input larger than a pipe buffer is delivered whole" `Quick
            test_input_larger_than_a_pipe_buffer_is_delivered_whole;
        ] );
      ( "writing the key to disk",
        [
          test_case "a raising call leaves no key and still reports its fault"
            `Quick test_a_raising_call_leaves_no_key_and_still_reports_its_fault;
          test_case "the key is written readable by its owner alone" `Quick
            test_the_key_is_written_readable_by_its_owner_alone;
          test_case "both shapes of configured key reach disk" `Quick
            test_both_shapes_of_configured_key_reach_disk;
        ] );
      ( "session",
        [
          test_case "two calls in one session stage the key once" `Quick
            test_two_calls_in_one_session_stage_the_key_once;
          test_case "the key is gone when the session closes" `Quick
            test_the_staged_key_does_not_outlive_the_session;
        ] );
      ( "timeout",
        [
          test_case
            "a command that outlives its bound fails with the bound named"
            `Quick
            test_a_command_that_outlives_its_bound_fails_with_the_bound_named;
          test_case "a command that finishes inside its bound is unaffected"
            `Quick test_a_command_that_finishes_inside_its_bound_is_unaffected;
          test_case "what a command said before its bound is carried" `Quick
            test_what_a_command_said_before_its_bound_is_carried;
        ] );
      ( "classifying a failure",
        [
          test_case "ran_on_host names the one answer the host gave" `Quick
            test_ran_on_host_names_the_one_answer_the_host_gave;
          test_case "explain prefixes only the host's own answer" `Quick
            test_explain_prefixes_only_the_host_s_own_answer;
          test_case "exited_with is the host's own code alone" `Quick
            test_exited_with_is_the_hosts_own_code_alone;
        ] );
      ( "ssh options",
        [
          test_case "bound a host that stops answering" `Quick
            test_ssh_options_bound_a_host_that_stops_answering;
          test_case "never wait on a prompt" `Quick
            test_ssh_options_never_prompt;
        ] );
    ]
