open Alcotest
module Remote_exec = Bondi_client.Remote_exec

let contains = Test_helpers.contains

let pp_failure fmt (f : Remote_exec.failure) =
  match f with
  | Remote_exec.Not_configured { server } ->
      Format.fprintf fmt "Not_configured { server = %S }" server
  | Remote_exec.Ssh_failed { code; output } ->
      Format.fprintf fmt "Ssh_failed { code = %d; output = %S }" code output
  | Remote_exec.Command_failed { code; output } ->
      Format.fprintf fmt "Command_failed { code = %d; output = %S }" code output
  | Remote_exec.Signalled { signal; output } ->
      Format.fprintf fmt "Signalled { signal = %d; output = %S }" signal output
  | Remote_exec.Stopped { signal; output } ->
      Format.fprintf fmt "Stopped { signal = %d; output = %S }" signal output

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

(* These five strings are what the two implementations this module replaces
   printed, and holding them byte-identical is what makes the existing unit and
   cram assertions evidence that the move preserved behaviour rather than a diff
   to re-baseline. Asserted as whole rendered strings, not as format strings. *)
let test_message_renders_the_text_each_shape_rendered_before () =
  check string "ssh's own failure renders as a command failure"
    "command failed (255): could not resolve hostname"
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
let with_ssh_stub script f =
  let dir = Filename.temp_dir "bondi-ssh-stub-" "" in
  let stub = Filename.concat dir "ssh" in
  let oc = open_out stub in
  output_string oc script;
  close_out oc;
  Unix.chmod stub 0o755;
  let previous_path = Sys.getenv_opt "PATH" in
  Unix.putenv "PATH"
    (match previous_path with
    | None -> dir
    | Some previous -> dir ^ ":" ^ previous);
  Fun.protect
    ~finally:(fun () ->
      (match previous_path with
      | None -> ()
      | Some previous -> Unix.putenv "PATH" previous);
      (try Sys.remove stub with
      | Sys_error _ -> ());
      try Unix.rmdir dir with
      | Unix.Unix_error _ -> ())
    f

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
        (Remote_exec.command_output ~command:"docker ps" unroutable_server));
  with_ssh_stub "#!/bin/sh\nexit 255\n" (fun () ->
      check outcome "255 is still read as ssh's own failure"
        (Error (Remote_exec.Ssh_failed { code = 255; output = "" }))
        (Remote_exec.command_output ~command:"docker ps" unroutable_server));
  with_ssh_stub "#!/bin/sh\necho ok\n" (fun () ->
      check outcome "and a command that exits 0 is not a failure at all"
        (Ok "ok\n")
        (Remote_exec.command_output ~command:"docker ps" unroutable_server))

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
        (Remote_exec.command_output ~command:"acme probe" unroutable_server));
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
        (Remote_exec.command_output ~command:"acme probe" unroutable_server))

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
        (Remote_exec.command_output ~command:"cat" unroutable_server);
      check outcome "and a fed one is handed exactly what it was fed"
        (Ok "hello stdin\n")
        (Remote_exec.command_output ~input:"hello stdin" ~command:"cat"
           unroutable_server))

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
        (Remote_exec.command_output ~input:payload ~command:"true"
           unroutable_server));
  with_ssh_stub "#!/bin/sh\nwc -c | tr -d ' '\n" (fun () ->
      check outcome "and a command that drains it receives every byte"
        (Ok "200000\n")
        (Remote_exec.command_output ~input:payload ~command:"wc -c"
           unroutable_server))

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
            Remote_exec.command_output ~input:"hello" ~command:"cat"
              unroutable_server
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

(* Which failures mean the host ran the command is one policy, and every caller
   that words a report around it asks the same question. Asked here, of the
   type, so that a sixth constructor is a compile error in one place rather than
   a silent fifth wording.

   All five arms are asserted, not only the true one: the four that answer false
   are what stops a predicate that answers true to everything from passing. *)
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
    (Remote_exec.ran_on_host (Remote_exec.Stopped { signal = 19; output = "" }))

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
      ( "classifying a failure",
        [
          test_case "ran_on_host names the one answer the host gave" `Quick
            test_ran_on_host_names_the_one_answer_the_host_gave;
        ] );
      ( "ssh options",
        [
          test_case "bound a host that stops answering" `Quick
            test_ssh_options_bound_a_host_that_stops_answering;
          test_case "never wait on a prompt" `Quick
            test_ssh_options_never_prompt;
        ] );
    ]
