open Alcotest
module Probe = Bondi_client.Orchestrator_probe
module Remote_exec = Bondi_client.Remote_exec
module Builtin_container = Bondi_common.Builtin_container

let contains = Test_helpers.contains
let contains_word = Test_helpers.contains_word

(* What made the outage undiagnosable was that the operator was told nothing.
   The message has to carry the server's own account of the failure. *)
let test_failure_message_carries_the_diagnostics () =
  let message =
    Probe.failure_message ~ip_address:"46.225.53.162"
      ~image:"mlopez1506/bondi-server:0.10.1"
      ~reason:"the container did not answer GET /api/v1/health"
      ~diagnostics:
        "exited exit=127\n\
         Error loading shared library libzstd.so.1: No such file or directory"
  in
  check bool "names the server" true (contains ~needle:"46.225.53.162" message);
  check bool "names the image" true
    (contains ~needle:"mlopez1506/bondi-server:0.10.1" message);
  check bool "carries the exit code" true (contains ~needle:"exit=127" message);
  check bool "carries the loader error" true
    (contains ~needle:"libzstd.so.1" message)

(* Every string this module sends to a host, and the one it shows an operator,
   name the container the shared module names. The name is pinned as a literal
   in the shared module's own suite; what is asserted here is the link, because
   a second spelling here would be found by nothing -- the probe would go on
   looking for a container the rest of setup had stopped creating. *)
let test_the_probe_names_the_container_the_common_module_names () =
  let container = Builtin_container.orchestrator in
  check bool "the running wait names it" true
    (contains ~needle:container
       (Probe.running_command ~container_name:container ~attempts:3));
  check bool "the diagnostics command names it" true
    (contains ~needle:container Probe.diagnostics_command);
  check bool "the failure message names it" true
    (contains ~needle:container
       (Probe.failure_message ~ip_address:"46.225.53.162"
          ~image:"mlopez1506/bondi-server:0.10.1" ~reason:"no answer"
          ~diagnostics:"exited exit=127"))

(* The question setup asks changed: not "does something answer HTTP on the port
   the orchestrator published", which needs a fetch tool inside the container
   and a port that a later feature removes, but "does the server's own command
   surface say this box can serve". The command has to reach the binary inside
   the container it just started, because that is the only place the binary
   is. *)
let test_check_command_runs_the_servers_own_check_inside_the_container () =
  let command =
    Probe.check_command ~container_name:Builtin_container.orchestrator
      ~cron_configured:false
  in
  check bool "execs into a container" true
    (contains ~needle:"docker exec" command);
  check bool "names the container it was given" true
    (contains ~needle:Builtin_container.orchestrator command);
  check bool "runs the server binary" true
    (contains ~needle:"bondi-server" command);
  check bool "and asks it for the check subcommand" true
    (contains_word ~word:"check" command)

(* The half of the change that is an absence: a published port is no longer
   consulted, and no fetch tool is run inside the container. An absence is
   satisfied by the empty string, so the affirmative arm is asserted here on the
   same value -- a [check_command] that returned "" would otherwise pass this
   case while establishing nothing. *)
let test_check_command_names_no_published_port_and_runs_no_fetch_tool () =
  let command =
    Probe.check_command ~container_name:Builtin_container.orchestrator
      ~cron_configured:false
  in
  check bool "the value under inspection is the real command" true
    (contains ~needle:"docker exec" command
    && contains ~needle:Builtin_container.orchestrator command);
  check bool "names no published port" false
    (contains ~needle:(string_of_int Bondi_common.Defaults.server_port) command);
  check bool "addresses no loopback socket" false
    (contains ~needle:"127.0.0.1" command);
  check bool "requests no URL" false (contains ~needle:"http://" command);
  check bool "runs no wget" false (contains ~needle:"wget" command);
  check bool "runs no curl" false (contains ~needle:"curl" command)

(* Whether the crontab spool must be writable is a property of the deployment,
   not of the container, so the container cannot soundly infer it and setup has
   to say. Both values are asserted: a body that ignored the argument and always
   passed the flag -- or never passed it -- would satisfy a test that only ever
   looked at one of them. *)
let test_check_command_carries_cron_configuration_only_when_declared () =
  let configured =
    Probe.check_command ~container_name:Builtin_container.orchestrator
      ~cron_configured:true
  in
  let unconfigured =
    Probe.check_command ~container_name:Builtin_container.orchestrator
      ~cron_configured:false
  in
  check bool "a cron deployment declares it" true
    (contains ~needle:"--cron-configured" configured);
  check bool "one without cron does not" false
    (contains ~needle:"--cron-configured" unconfigured);
  check string "and the flag is the only difference between the two"
    (unconfigured ^ " --cron-configured")
    configured

(* A container that is no longer there will not come back, and an operator
   should not wait out the whole bound to be told so. The absence branch has to
   sit inside the loop, ahead of the retry, rather than being the fall-through
   the attempts run out into -- so what is asserted is where it sits, not merely
   that the sentence occurs somewhere. *)
let test_the_running_wait_stops_as_soon_as_the_container_is_gone () =
  let command =
    Probe.running_command ~container_name:Builtin_container.orchestrator
      ~attempts:30
  in
  check bool "reads the container's state from the host" true
    (contains ~needle:"docker inspect" command);
  match Bondi_common.String_utils.index_of ~needle:"sleep" command with
  | None -> fail "the wait does not sleep between attempts"
  | Some retry ->
      let loop_body_before_the_retry = String.sub command 0 retry in
      check bool "the container's absence is answered inside the loop" true
        (contains ~needle:"is not present" loop_body_before_the_retry);
      check bool "and the answer is to stop rather than sleep again" true
        (contains ~needle:"exit 1" loop_body_before_the_retry);
      check bool "running out of attempts is a separate, later answer" false
        (contains ~needle:"did not reach a running state"
           loop_body_before_the_retry);
      check bool "and the command does say so once the attempts run out" true
        (contains ~needle:"did not reach a running state" command)

(* The name is the caller's string and it reaches the host inside a command the
   host's shell parses, so every position it stands in carries the quoted form:
   a name holding a quote would break the command and one holding [$] or a
   backtick would be evaluated. The name here holds a quote, which is what makes
   the absence assertion exact -- [Filename.quote] rewrites the quote, so the
   raw spelling occurs nowhere in a command that quotes it everywhere, and would
   occur the moment any one position stopped. *)
let test_the_running_wait_quotes_the_name_wherever_it_stands () =
  let hostile = "bondi'; rm -rf /" in
  let quoted = Filename.quote hostile in
  let command = Probe.running_command ~container_name:hostile ~attempts:3 in
  check bool "no position carries the name as the caller spelled it" false
    (contains ~needle:hostile command);
  match Bondi_common.String_utils.index_of ~needle:"sleep" command with
  | None -> fail "the wait does not sleep between attempts"
  | Some retry ->
      let before = String.sub command 0 retry in
      let after = String.sub command retry (String.length command - retry) in
      check bool "the state read and the absence sentence quote it" true
        (contains ~needle:quoted before);
      check bool "and so does the sentence the attempts run out into" true
        (contains ~needle:quoted after)

(* The bound is how long a healthy but slow host is given, and it is the
   caller's number. A body that reached for the module's own default instead
   would pass every assertion that only ever passed it that default, and would
   ignore a caller asking for a different wait. *)
let test_the_running_wait_is_bounded_by_the_attempts_it_is_given () =
  let seven =
    Probe.running_command ~container_name:Builtin_container.orchestrator
      ~attempts:7
  in
  check bool "the loop is bounded by a counted attempt" true
    (contains ~needle:"attempt" seven);
  check bool "the bound is the number the caller passed" true
    (contains_word ~word:"7" seven);
  check bool "and not the module's own default" false
    (contains_word ~word:(string_of_int Probe.running_attempts) seven);
  check bool "the default is a bound a caller can pass" true
    (contains_word
       ~word:(string_of_int Probe.running_attempts)
       (Probe.running_command ~container_name:Builtin_container.orchestrator
          ~attempts:Probe.running_attempts))

(* The marker setup looks for is written to the container's error stream, so a
   read that collected standard output alone would find the stream silent on
   every healthy box and fail every setup. The read is bounded because the line
   was written moments ago and a busy orchestrator's whole history is not
   wanted on the connection. *)
let test_log_stream_command_reads_the_containers_recent_output_and_its_errors ()
    =
  let command =
    Probe.log_stream_command ~container_name:Builtin_container.orchestrator
      ~lines:20
  in
  check bool "reads the container's log stream" true
    (contains ~needle:"docker logs" command);
  check bool "names the container it was given" true
    (contains ~needle:Builtin_container.orchestrator command);
  check bool "bounded to the lines the caller asked for" true
    (contains ~needle:"--tail 20" command);
  check bool "and collects the error stream the marker is written to" true
    (contains ~needle:"2>&1" command)

(* Fifty is one number standing in three places: the banner the diagnostics read
   prints above the lines, the bound that same read asks docker for, and the
   bound the log-stream read setup takes asks for. Spelled separately they
   drift, and a banner announcing fifty lines above twenty-five of them
   misreports what an operator is looking at on the one run where the reading
   was refused. So both positions are read back against the number this module
   exports rather than against a literal that would agree with itself. *)
let test_the_diagnostics_read_names_the_bound_it_asks_for () =
  let bound = string_of_int Probe.log_lines in
  check bool "the read is bounded by the module's own number" true
    (contains ~needle:("--tail " ^ bound) Probe.diagnostics_command);
  check bool "and the banner above the lines announces that same number" true
    (contains
       ~needle:("--- last " ^ bound ^ " log lines ---")
       Probe.diagnostics_command)

(* The documents [bondi-server check] actually writes, in the shape its own
   encoder produces: a [ready] flag and every probe taken, each named by the key
   a program compares against. They are held here so that the rejecting case and
   the passing case are told apart by what the box did, not by one fixture being
   empty and the other not. *)
let ready_document =
  {|{"ready":true,"probes":[{"name":"docker_socket","ok":true},{"name":"diagnostic_sink","ok":true}]}|}

let not_ready_document =
  {|{"ready":false,"probes":[{"name":"docker_socket","ok":true},{"name":"crontab_spool","ok":false,"reason":"/var/spool/cron/crontabs is not writable"}]}|}

(* Named exhaustively rather than compared with a polymorphic equality, so that
   a constructor added later is a build failure in this file -- which is where
   the arm nobody asserted would otherwise go unnoticed -- and so that a failing
   assertion says which verdict came back rather than that two values differed.
   The reason is read through a second exhaustive function for the same
   reason. *)
let verdict_name = function
  | Probe.Serving -> "Serving"
  | Probe.Not_ready _ -> "Not_ready"
  | Probe.Unreachable _ -> "Unreachable"

let verdict_reason = function
  | Probe.Serving -> ""
  | Probe.Not_ready reason -> reason
  | Probe.Unreachable reason -> reason

let log_stream_name = function
  | Probe.Carrying -> "Carrying"
  | Probe.Silent -> "Silent"
  | Probe.Unreadable _ -> "Unreadable"

let log_stream_reason = function
  | Probe.Carrying -> ""
  | Probe.Silent -> ""
  | Probe.Unreadable reason -> reason

(* The subcommand writes its document whichever way its verdict goes and the
   transport preserves the remote status, so an exit the transport reports as a
   success is the box having answered that it can serve. *)
let test_a_clean_exit_is_serving () =
  let verdict = Probe.verdict_of_output (Ok ready_document) in
  check string "a check that exited cleanly is the box saying it can serve"
    "Serving" (verdict_name verdict)

(* The status the readiness class leaves behind is the one code that means the
   box ran the check and named faults. Classifying it as anything else sends an
   operator to the network when the answer is on the machine, and the reason has
   to carry the document because the document is the whole of what there is to
   act on. *)
let test_the_readiness_exit_code_is_the_box_reporting_faults () =
  let output =
    not_ready_document
    ^ "\ncrontab spool: /var/spool/cron/crontabs is not writable\n"
  in
  let verdict =
    Probe.verdict_of_output
      (Error
         (Remote_exec.Command_failed
            { code = Bondi_common.Readiness_exit_code.not_ready; output }))
  in
  check string "the readiness code is the box reporting its own faults"
    "Not_ready" (verdict_name verdict);
  let reason = verdict_reason verdict in
  check bool "and the reason carries the probe the document named" true
    (contains ~needle:"crontab_spool" reason);
  check bool "and what the box said about it" true
    (contains ~needle:"/var/spool/cron/crontabs is not writable" reason)

(* The failure this module exists to catch: a missing shared library stops the
   musl loader before [main], so the process leaves a status and never writes a
   document. Read as a readiness failure it would be reported as a box with a
   fault to repair; it is a container that never ran the check at all, and the
   status it left is the only thing there is to carry. *)
let test_a_container_that_died_before_its_entry_point_is_unreachable () =
  let verdict =
    Probe.verdict_of_output
      (Error
         (Remote_exec.Command_failed
            {
              code = 127;
              output =
                "Error loading shared library libzstd.so.1: No such file or \
                 directory";
            }))
  in
  check string "a status with no document is not the box reporting faults"
    "Unreachable" (verdict_name verdict);
  let reason = verdict_reason verdict in
  check bool "the status the box left behind is carried" true
    (contains ~needle:"(127)" reason);
  check bool "and so is what the loader said" true
    (contains ~needle:"libzstd.so.1" reason)

(* Nothing was obtained from the box, and each of these says which way that
   happened: an operator resolves a key, a hung host and a killed client in
   three different places. *)
let test_every_other_failure_says_nothing_was_obtained_from_the_box () =
  let cases =
    [
      ( "ssh's own failure",
        Remote_exec.Ssh_failed
          { code = 255; output = "Connection closed by 10.0.0.1 port 22" },
        "Connection closed" );
      ("a timeout", Remote_exec.Timed_out { seconds = 60; output = "" }, "60s");
      ("a signal", Remote_exec.Signalled { signal = 9; output = "" }, "(9)");
    ]
  in
  List.iter
    (fun (name, failure, fragment) ->
      let verdict = Probe.verdict_of_output (Error failure) in
      check string
        (name ^ " is not a reading")
        "Unreachable" (verdict_name verdict);
      check bool
        (name ^ " says nothing was obtained from the box")
        true
        (contains ~needle:"no reading was obtained" (verdict_reason verdict));
      check bool
        (name ^ " names which way that happened")
        true
        (contains ~needle:fragment (verdict_reason verdict)))
    cases

(* A remote command that exited saying nothing is the case a stub with no arm
   for the command produces, and it is not evidence that the box can serve. The
   passing arm is asserted on the same function in the same case, because a body
   that rejected everything would satisfy the rejection on its own. *)
let test_empty_output_is_a_rejection_not_a_pass () =
  let silent = Probe.verdict_of_output (Ok "") in
  check string "a command that exited saying nothing is not a pass"
    "Unreachable" (verdict_name silent);
  check bool "and says that no document was written" true
    (contains ~needle:"exited without writing a document"
       (verdict_reason silent));
  check bool "in a sentence, not in fragments a line break glued together" true
    (contains ~needle:"a command that exited saying nothing"
       (verdict_reason silent));
  check string "whitespace is saying nothing too" "Unreachable"
    (verdict_name (Probe.verdict_of_output (Ok "  \n")));
  check string "and a check that did answer is still a pass" "Serving"
    (verdict_name (Probe.verdict_of_output (Ok ready_document)))

(* Three outcomes, and the one that matters is the middle: a stream that came
   back without the marker is a deployment that has lost its observability,
   which must fail setup, and a stream that could not be read is a reading to
   take again. Folding the first into the second reports a broken box as a
   broken connection. *)
let test_the_log_stream_carrying_silent_and_unreadable_are_three_outcomes () =
  let carrying =
    Probe.log_stream_of_output
      (Ok
         (Printf.sprintf "bondi-server starting\n%s\n"
            Bondi_common.Check_marker.diagnostic_sink))
  in
  let silent = Probe.log_stream_of_output (Ok "bondi-server starting\n") in
  let unreadable =
    Probe.log_stream_of_output
      (Error
         (Remote_exec.Command_failed
            {
              code = 1;
              output = "Error: No such container: bondi-orchestrator";
            }))
  in
  check string "the marker in the stream is the stream carrying it" "Carrying"
    (log_stream_name carrying);
  check string "a stream without it is silent, not unreadable" "Silent"
    (log_stream_name silent);
  check string "an empty stream is silent too" "Silent"
    (log_stream_name (Probe.log_stream_of_output (Ok "")));
  check string "and a read that did not happen is unreadable" "Unreadable"
    (log_stream_name unreadable);
  check bool "the unreadable arm names what happened instead" true
    (contains ~needle:"No such container" (log_stream_reason unreadable))

let () =
  run "Orchestrator_probe"
    [
      ( "container name",
        [
          test_case "the probe names the container the common module names"
            `Quick test_the_probe_names_the_container_the_common_module_names;
        ] );
      ( "failure_message",
        [
          test_case "carries the server's own diagnostics" `Quick
            test_failure_message_carries_the_diagnostics;
        ] );
      ( "check_command",
        [
          test_case "runs the server's own check inside the container" `Quick
            test_check_command_runs_the_servers_own_check_inside_the_container;
          test_case "names no published port and runs no fetch tool" `Quick
            test_check_command_names_no_published_port_and_runs_no_fetch_tool;
          test_case "carries cron configuration only when it is declared" `Quick
            test_check_command_carries_cron_configuration_only_when_declared;
        ] );
      ( "running_command",
        [
          test_case "stops as soon as the container is gone" `Quick
            test_the_running_wait_stops_as_soon_as_the_container_is_gone;
          test_case "is bounded by the attempts it is given" `Quick
            test_the_running_wait_is_bounded_by_the_attempts_it_is_given;
          test_case "quotes the container name wherever it stands" `Quick
            test_the_running_wait_quotes_the_name_wherever_it_stands;
        ] );
      ( "verdict_of_output",
        [
          test_case "a clean exit is serving" `Quick
            test_a_clean_exit_is_serving;
          test_case
            "the readiness exit code is the box reporting faults, and carries \
             them"
            `Quick test_the_readiness_exit_code_is_the_box_reporting_faults;
          test_case
            "a container that died before its entry point is unreachable, and \
             carries the status"
            `Quick
            test_a_container_that_died_before_its_entry_point_is_unreachable;
          test_case "every other failure says nothing was obtained from the box"
            `Quick
            test_every_other_failure_says_nothing_was_obtained_from_the_box;
          test_case "empty output is a rejection, not a pass" `Quick
            test_empty_output_is_a_rejection_not_a_pass;
        ] );
      ( "log_stream_of_output",
        [
          test_case
            "carrying the marker, silent, and unreadable are three outcomes"
            `Quick
            test_the_log_stream_carrying_silent_and_unreadable_are_three_outcomes;
        ] );
      ( "diagnostics_command",
        [
          test_case "names the bound it asks for" `Quick
            test_the_diagnostics_read_names_the_bound_it_asks_for;
        ] );
      ( "log_stream_command",
        [
          test_case "reads the container's recent output and its error stream"
            `Quick
            test_log_stream_command_reads_the_containers_recent_output_and_its_errors;
        ] );
    ]
