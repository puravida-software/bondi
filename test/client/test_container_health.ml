open Alcotest
module Health = Bondi_client.Container_health
module Remote_exec = Bondi_client.Remote_exec

let contains = Test_helpers.contains

(* --- Fixtures ---

   The wait runs on the host and always exits 0, carrying its answer as a
   marker on stdout, so every fixture below is what the host printed. The one
   builder each test reads through takes exactly that, because it is the only
   input a verdict has: two arms differing in their outcome can only differ
   because of what the host said. *)

let verdict_of output = Health.verdict_of_output (Ok output)

(* --- Tests --- *)

(* The affirmative arm the rejections below are measured against: the same
   builder, given the marker the host prints once a check has passed, does
   produce a pass. Without it, an implementation that never reports health at
   all satisfies every other test in this file. *)
let test_health_verdict_healthy () =
  match verdict_of "BONDI_CONTAINER_HEALTHY\n" with
  | Health.Healthy -> ()
  | Health.Unhealthy _
  | Health.No_healthcheck
  | Health.Timed_out _
  | Health.Gone
  | Health.Unreadable _ ->
      fail "a passing healthcheck must be reported as a pass"

(* A failing check knows one thing the client cannot reconstruct: whether this
   is a first blip or a run of failures. That is the streak, and it is the whole
   of what the host is asked for — a healthcheck is a command line, and a
   command line on this host is a place a secret lives, so what the check itself
   printed is never fetched and so can never be reported. *)
let test_health_verdict_unhealthy_carries_the_failing_streak () =
  match verdict_of "BONDI_CONTAINER_UNHEALTHY\nfailing streak 3\n" with
  | Health.Unhealthy detail ->
      check bool "carries how many runs in a row have failed" true
        (contains ~needle:"failing streak 3" detail);
      check bool "leaves the marker out of what gets reported" false
        (contains ~needle:"BONDI_CONTAINER_UNHEALTHY" detail)
  | Health.Healthy
  | Health.No_healthcheck
  | Health.Timed_out _
  | Health.Gone
  | Health.Unreadable _ ->
      fail "a failing healthcheck must be reported as one"

(* A container that defines no healthcheck has passed nothing. Reporting that
   as a pass is the conflation this module exists to make unavailable, and it
   is the state most containers on a host are in. *)
let test_health_verdict_no_healthcheck () =
  match verdict_of "BONDI_CONTAINER_NO_HEALTHCHECK\n" with
  | Health.No_healthcheck -> ()
  | Health.Healthy ->
      fail
        "a container that defines no healthcheck must not be reported as \
         having passed one"
  | Health.Unhealthy _
  | Health.Timed_out _
  | Health.Gone
  | Health.Unreadable _ ->
      fail "a container with no healthcheck must be reported as having none"

(* The bound comes back from the host rather than from the caller, so the
   report says how long was actually waited and not how long the client meant
   to ask for. A marker that named no bound has not said that, and inventing a
   zero would put a number in the report nothing on the host supports. *)
let test_health_verdict_timeout () =
  (match verdict_of "BONDI_CONTAINER_TIMEOUT 120\n" with
  | Health.Timed_out { seconds } ->
      check int "carries the bound the host waited out" 120 seconds
  | Health.Healthy
  | Health.Unhealthy _
  | Health.No_healthcheck
  | Health.Gone
  | Health.Unreadable _ ->
      fail "a bound that ran out must be reported as a timeout");
  match verdict_of "BONDI_CONTAINER_TIMEOUT\n" with
  | Health.Timed_out { seconds } ->
      failf
        "a timeout that named no bound must not be reported as one of %d \
         seconds"
        seconds
  | Health.Unreadable _ -> ()
  | Health.Healthy
  | Health.Unhealthy _
  | Health.No_healthcheck
  | Health.Gone ->
      fail "a timeout that named no bound is a reading that did not answer"

(* Waiting out the full bound on a container that has already stopped tells the
   operator nothing and costs them the bound. The host stops as soon as the
   container is no longer running, and that is its own outcome — neither a
   timeout nor a failing check. *)
let test_health_verdict_gone_when_container_stops () =
  match verdict_of "BONDI_CONTAINER_GONE\n" with
  | Health.Gone -> ()
  | Health.Healthy
  | Health.Unhealthy _
  | Health.No_healthcheck
  | Health.Timed_out _
  | Health.Unreadable _ ->
      fail "a container that is no longer running must be reported as gone"

(* The remote command could not be run at all. That is a fact about the read
   and not about the container, and it must be reported as neither a pass nor a
   failing check. *)
let test_health_verdict_unreadable () =
  match
    Health.verdict_of_output
      (Error
         (Remote_exec.Ssh_failed { code = 255; output = "Connection closed" }))
  with
  | Health.Unreadable message ->
      check bool "carries what went wrong" true
        (contains ~needle:"Connection closed" message)
  | Health.Healthy
  | Health.Unhealthy _
  | Health.No_healthcheck
  | Health.Timed_out _
  | Health.Gone ->
      fail "a read that never happened must be reported as unreadable"

(* Reading a verdict off the value rather than off a match, so the cases below
   stay about the difference between two failures and not about the five arms
   they are not. *)
let unreadable_message verdict =
  match verdict with
  | Health.Unreadable message -> message
  | Health.Healthy
  | Health.Unhealthy _
  | Health.No_healthcheck
  | Health.Timed_out _
  | Health.Gone ->
      fail "a wait that failed must be reported as unreadable"

(* A host that ran the wait and answered with a non-zero exit has told this
   client something about itself; a host that was never reached has not. Both
   are unreadable waits, and reporting the second's wording on the first sends
   an operator to the key when the answer is on the box. *)
let test_a_host_that_answered_is_not_a_host_that_could_not_be_reached () =
  let unreached =
    unreadable_message
      (Health.verdict_of_output
         (Error
            (Remote_exec.Ssh_failed
               { code = 255; output = "Connection closed by 10.0.0.1 port 22" })))
  in
  let answered =
    unreadable_message
      (Health.verdict_of_output
         (Error
            (Remote_exec.Command_failed
               { code = 1; output = "Cannot connect to the Docker daemon" })))
  in
  check bool "a host that ran the wait says so" true
    (contains ~needle:"ran on the host" answered);
  check bool "a host that was never reached does not" false
    (contains ~needle:"ran on the host" unreached);
  check bool "and each still carries what came back" true
    (contains ~needle:"Connection closed" unreached
    && contains ~needle:"Docker daemon" answered)

(* Every [docker inspect] in the wait discards its stderr, so a daemon that is
   down, a socket the user may not open, or a CLI that errored for any other
   reason all produced an empty reading — and an empty reading compared against
   "running" is not running, which was reported as the container having stopped.
   That is a read that never happened being stated as a fact about the
   container, and it failed the run under a sentence naming a cause nothing
   established. Its affirmative twin is the case above: a container the host did
   report as no longer running is still gone. *)
let test_health_verdict_unreadable_read_is_not_a_stopped_container () =
  match verdict_of "BONDI_CONTAINER_UNREADABLE\n" with
  | Health.Unreadable message ->
      (* The marker is recognised, rather than falling through to the arm that
         rejects output carrying no marker at all: those are different failures
         and an operator acts differently on each. *)
      check bool "says the host could not read the container" true
        (contains ~needle:"could not read" message);
      check bool "not that the host answered with nothing" false
        (contains ~needle:"without a verdict" message)
  | Health.Gone ->
      fail
        "a reading that could not be taken must not be reported as a container \
         that stopped"
  | Health.Healthy
  | Health.Unhealthy _
  | Health.No_healthcheck
  | Health.Timed_out _ ->
      fail "a reading that could not be taken is unreadable"

(* A remote command that exited saying nothing is not evidence of health.
   Reading it as one is the defect this module exists to prevent: it is how a
   silent failure becomes a green report. *)
let test_health_verdict_empty_output_is_rejection () =
  (match verdict_of "" with
  | Health.Unreadable message ->
      check bool "says the host gave no verdict" true
        (contains ~needle:"verdict" message)
  | Health.Healthy
  | Health.Unhealthy _
  | Health.No_healthcheck
  | Health.Timed_out _
  | Health.Gone ->
      fail "output saying nothing at all must be a rejection");
  match
    verdict_of "Warning: Permanently added '10.0.0.1' to known hosts.\n"
  with
  | Health.Unreadable _ -> ()
  | Health.Healthy
  | Health.Unhealthy _
  | Health.No_healthcheck
  | Health.Timed_out _
  | Health.Gone ->
      fail "output carrying no marker must be a rejection"

(* The bound is enforced on the host, so it has to be in the command; and the
   command has to stop early on a container that is no longer running, or an
   operator waits out the whole bound to be told a container had already
   died. *)
let test_health_wait_command_carries_the_bound () =
  let command =
    Health.wait_command ~container_name:"ib-gateway" ~timeout_seconds:120
  in
  check bool "carries the bound it was given" true
    (contains ~needle:"120" command);
  check bool "names the container" true (contains ~needle:"ib-gateway" command);
  check bool "reads the container's own state, so it can stop early" true
    (contains ~needle:"{{.State.Status}}" command);
  check bool "reads the health the host recorded" true
    (contains ~needle:"{{.State.Health.Status}}" command);
  check bool "asks whether a healthcheck is declared at all" true
    (contains ~needle:"{{if .Config.Healthcheck}}" command);
  check bool "always exits 0, so the marker survives the ssh layer" true
    (contains ~needle:"exit 0" command)

(* What a failing check printed is a command's own output, and a healthcheck on
   this host is written as a command line carrying credentials. The report can
   only decline to show what the wait never fetched, so the guard belongs in the
   command rather than at the render site: with the log unread, no verdict is
   able to carry it. Its affirmative arm is the streak, which is fetched. *)
let test_health_wait_command_never_reads_what_the_check_printed () =
  let command =
    Health.wait_command ~container_name:"ib-gateway" ~timeout_seconds:120
  in
  check bool "asks the host how many runs in a row have failed" true
    (contains ~needle:"FailingStreak" command);
  check bool "and never for what the check itself printed" false
    (contains ~needle:".State.Health.Log" command)

(* A container started with --no-healthcheck carries Test ["NONE"], which is a
   non-empty Healthcheck record — so a command asking only whether the record is
   there reads the operator's explicit "there is no check here" as a check to
   wait for, and then waits out the whole bound before failing the run. The
   first element of Test is what tells them apart. *)
let test_health_wait_command_reads_a_disabled_healthcheck () =
  let command =
    Health.wait_command ~container_name:"ib-gateway" ~timeout_seconds:120
  in
  check bool "reads what the healthcheck's test actually is" true
    (contains ~needle:"index .Config.Healthcheck.Test 0" command);
  check bool "and recognises the word that disables one" true
    (contains ~needle:"NONE" command)

(* The bound is reported to an operator in seconds, so it has to be seconds. A
   loop counting iterations of "inspect a few times, then sleep 1" runs for
   materially longer than the number the row prints, and on a loaded host the
   gap is not small. A deadline read from the clock makes the printed number
   true. *)
let test_health_wait_command_bounds_by_the_clock () =
  let command =
    Health.wait_command ~container_name:"ib-gateway" ~timeout_seconds:120
  in
  check bool "reads the host's clock to fix a deadline" true
    (contains ~needle:"date +%s" command);
  check bool "rather than counting how many times it looked" false
    (contains ~needle:"attempt=$((attempt + 1))" command)

(* A reading that could not be taken is reported as such by the command itself,
   rather than left to arrive as an empty string that compares unequal to
   "running". *)
let test_health_wait_command_says_when_it_could_not_read () =
  let command =
    Health.wait_command ~container_name:"ib-gateway" ~timeout_seconds:120
  in
  check bool "carries a marker for a reading it could not take" true
    (contains ~needle:"BONDI_CONTAINER_UNREADABLE" command);
  check bool "and asks whether the daemon answers at all before saying gone"
    true
    (contains ~needle:"docker version" command)

let () =
  run "Container_health"
    [
      ( "verdict",
        [
          test_case "a passing healthcheck is healthy" `Quick
            test_health_verdict_healthy;
          test_case "a failing healthcheck carries its failing streak" `Quick
            test_health_verdict_unhealthy_carries_the_failing_streak;
          test_case "no healthcheck defined is not a pass" `Quick
            test_health_verdict_no_healthcheck;
          test_case "an exhausted bound is a timeout naming it" `Quick
            test_health_verdict_timeout;
          test_case "a container that stopped is gone, not a timeout" `Quick
            test_health_verdict_gone_when_container_stops;
          test_case "a read that could not be taken is unreadable" `Quick
            test_health_verdict_unreadable;
          test_case "a host that answered is not a host never reached" `Quick
            test_a_host_that_answered_is_not_a_host_that_could_not_be_reached;
          test_case "a reading that failed is not a stopped container" `Quick
            test_health_verdict_unreadable_read_is_not_a_stopped_container;
          test_case "output carrying no marker is a rejection" `Quick
            test_health_verdict_empty_output_is_rejection;
        ] );
      ( "wait_command",
        [
          test_case "carries the bound and stops early on a stopped container"
            `Quick test_health_wait_command_carries_the_bound;
          test_case "never asks for what the check printed" `Quick
            test_health_wait_command_never_reads_what_the_check_printed;
          test_case "reads a healthcheck the operator disabled" `Quick
            test_health_wait_command_reads_a_disabled_healthcheck;
          test_case "bounds itself by the clock, not by attempts" `Quick
            test_health_wait_command_bounds_by_the_clock;
          test_case "says when it could not read rather than guessing" `Quick
            test_health_wait_command_says_when_it_could_not_read;
        ] );
    ]
