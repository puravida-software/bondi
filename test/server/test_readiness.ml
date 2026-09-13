open Alcotest
module Readiness = Bondi_server__Readiness
module Handler_error = Bondi_server__Handler_error
module String_utils = Bondi_common.String_utils
module Cron_section = Bondi_common.Cron_section

(* An observation list is the one thing the compiler cannot check for
   completeness, so the probe set is named arm by arm here. A probe added to the
   variant later makes this [function] inexhaustive in this file, which is where
   the missing coverage would otherwise have gone unnoticed. *)
let probe_name = function
  | Readiness.Docker_socket -> "docker socket"
  | Readiness.Crontab_spool -> "crontab spool"
  | Readiness.Diagnostic_sink -> "diagnostic sink"
  | Readiness.Cron_divergence -> "cron divergence"

let passing probe = { Readiness.probe; outcome = Ok () }
let failing probe reason = { Readiness.probe; outcome = Error reason }

let is_ready = function
  | Readiness.Ready -> true
  | Readiness.Not_ready _ -> false

(* The verdict is compared through the names of the probes it reports rather
   than through a structural equality on the verdict itself: what the operator
   is owed is which probes failed, and a comparison on names fails with that
   list printed rather than with a record dump. *)
let failing_probe_names = function
  | Readiness.Ready -> []
  | Readiness.Not_ready observations ->
      List.map
        (fun (observation : Readiness.observation) ->
          probe_name observation.probe)
        observations

let test_all_probes_passing_is_ready () =
  let verdict =
    Readiness.plan
      [
        passing Readiness.Docker_socket;
        passing Readiness.Crontab_spool;
        passing Readiness.Diagnostic_sink;
      ]
  in
  check bool "every probe returned Ok, so the box is ready" true
    (is_ready verdict);
  check (list string) "a ready verdict carries no failing probe" []
    (failing_probe_names verdict)

let test_a_failing_probe_is_not_ready () =
  let verdict =
    Readiness.plan
      [
        passing Readiness.Docker_socket;
        failing Readiness.Crontab_spool "the spool directory is not writable";
        passing Readiness.Diagnostic_sink;
      ]
  in
  check bool "one failing probe is enough to withhold ready" false
    (is_ready verdict);
  check (list string) "the verdict names the probe that failed and no other"
    [ "crontab spool" ]
    (failing_probe_names verdict)

(* A box with two faults that reports one costs a second trip to a machine the
   operator had to reach, so the verdict carries every failing probe. A [plan]
   that stops at the first failure passes the case above and fails here. *)
let test_every_failing_probe_is_reported () =
  let verdict =
    Readiness.plan
      [
        failing Readiness.Docker_socket "the docker socket cannot be opened";
        passing Readiness.Crontab_spool;
        failing Readiness.Diagnostic_sink
          "the diagnostic sink cannot be written";
      ]
  in
  check (list string) "both failures are named, in the order observed"
    [ "docker socket"; "diagnostic sink" ]
    (failing_probe_names verdict);
  match Readiness.error_of_verdict verdict with
  | None -> fail "a not-ready verdict must produce an error"
  | Some error ->
      let message = Handler_error.message error in
      check bool "the message names the socket failure" true
        (String_utils.contains ~needle:"the docker socket cannot be opened"
           message);
      check bool "the message names the sink failure" true
        (String_utils.contains ~needle:"the diagnostic sink cannot be written"
           message)

(* The [None] arm is an assertion of absence, so the same probe set is run again
   with one probe failing. Without that arm a [error_of_verdict] that answered
   [None] for everything would pass. *)
let test_ready_produces_no_error () =
  let ready =
    Readiness.plan
      [ passing Readiness.Docker_socket; passing Readiness.Diagnostic_sink ]
  in
  check bool "a ready verdict produces no error" true
    (Option.is_none (Readiness.error_of_verdict ready));
  let not_ready =
    Readiness.plan
      [
        failing Readiness.Docker_socket "the docker socket cannot be opened";
        passing Readiness.Diagnostic_sink;
      ]
  in
  check bool "the same probe set with one failure does produce an error" true
    (Option.is_some (Readiness.error_of_verdict not_ready))

(* The verdict on stdout is a wire contract: the subcommand's bytes are read by
   a script, so the field names and their order are asserted as bytes rather
   than by re-encoding through the same function. The keys are the probe
   constructors in snake_case -- the operator-facing names ("crontab spool")
   belong in the message on stderr, where a human is reading them. *)
let encoded observations =
  Yojson.Safe.to_string (Readiness.observations_to_yojson observations)

let test_a_ready_observation_list_encodes_every_probe () =
  check string "ready is true and every probe taken is named"
    {|{"ready":true,"probes":[{"name":"docker_socket","ok":true},{"name":"crontab_spool","ok":true},{"name":"diagnostic_sink","ok":true}]}|}
    (encoded
       [
         passing Readiness.Docker_socket;
         passing Readiness.Crontab_spool;
         passing Readiness.Diagnostic_sink;
       ])

(* The failing document is the one a program acts on, and [check] emits it:
   [Cmd_io.diagnostic_of] writes the document on both arms and leaves the prose
   to stderr. This pins the bytes of that arm -- ready is false and every failing
   probe carries its own reason -- as a wire contract, the same way the passing
   arm above is pinned. The spool probe is absent here rather than reported as
   passing, which is what a deployment without cron produces. *)
let test_a_failing_observation_carries_its_reason () =
  check string "ready is false and the failing probe carries its reason"
    {|{"ready":false,"probes":[{"name":"docker_socket","ok":true},{"name":"diagnostic_sink","ok":false,"reason":"/proc/1/fd/2: Permission denied"}]}|}
    (encoded
       [
         passing Readiness.Docker_socket;
         failing Readiness.Diagnostic_sink "/proc/1/fd/2: Permission denied";
       ])

(* The divergence probe is the only one whose sources the caller can write, so
   it is the only one this file takes through [observe] rather than through
   hand-built observations. Both arms below run against the same two paths and
   differ only in what those paths hold, which is what stops an arm that
   reported nothing because the probe never reached them from passing.

   The other three probes are taken in the same run and are not asserted here:
   they are [test_readiness_probes.ml]'s subject and their fixtures are its. The
   socket path names nothing, so that probe fails; the spool and the sink are
   the scratch directory and a file in it, so those pass. None of that reaches
   an assertion below, which reads the divergence observation by name. *)

let write_lines path lines =
  let channel = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out channel)
    (fun () ->
      List.iter (fun line -> output_string channel (line ^ "\n")) lines)

let exec_line = Test_helpers.exec_line

let crontab_firing jobs =
  (Cron_section.begin_marker :: List.map exec_line jobs)
  @ [ Cron_section.end_marker ]

let payload_for dir job =
  let job_dir = Filename.concat dir job in
  Unix.mkdir job_dir 0o700;
  write_lines (Filename.concat job_dir "run.json") [ "{}" ]

(* One level of nesting is all the fixture has -- a job directory holding two
   files at most -- so the removal is written for that shape rather than for an
   arbitrary tree, and it runs on the failing path as well as the passing one. *)
let remove_tree root =
  let remove_quietly remove path =
    try remove path with
    | Sys_error _ -> ()
    | Unix.Unix_error _ -> ()
  in
  match Sys.readdir root with
  | exception Sys_error _ -> ()
  | entries ->
      Array.iter
        (fun entry ->
          let path = Filename.concat root entry in
          match Sys.is_directory path with
          | false -> remove_quietly Sys.remove path
          | true ->
              (match Sys.readdir path with
              | exception Sys_error _ -> ()
              | inner ->
                  Array.iter
                    (fun name ->
                      remove_quietly Sys.remove (Filename.concat path name))
                    inner);
              remove_quietly Unix.rmdir path
          | exception Sys_error _ -> ())
        entries;
      remove_quietly Unix.rmdir root

type sources = { crontab : string; payload : string }
(** The two paths the divergence probe compares, and nothing else: what each
    holds is the arm's own business. *)

let with_sources ~fires ~holds body =
  let root = Filename.temp_file "bondi-divergence" "" in
  Sys.remove root;
  Unix.mkdir root 0o700;
  Fun.protect
    ~finally:(fun () -> remove_tree root)
    (fun () ->
      let crontab = Filename.concat root "crontab" in
      let payload = Filename.concat root "payload" in
      write_lines crontab (crontab_firing fires);
      Unix.mkdir payload 0o700;
      List.iter (payload_for payload) holds;
      body { crontab; payload } ~scratch:root)

let observe_sources ~cron_configured sources ~scratch =
  let sink = Filename.concat scratch "sink" in
  write_lines sink [];
  Readiness.observe ~cron_configured
    ~docker_socket:(Filename.concat scratch "no-engine-here")
    ~spool_dir:scratch ~diagnostic_sink:sink ~crontab_path:sources.crontab
    ~payload_dir:sources.payload

let divergence_outcome observations =
  List.find_map
    (fun (observation : Readiness.observation) ->
      match observation.probe with
      | Readiness.Cron_divergence -> Some observation.outcome
      | Readiness.Docker_socket
      | Readiness.Crontab_spool
      | Readiness.Diagnostic_sink ->
          None)
    observations

(* Both directions in one fixture, because they are not symmetric: the job the
   section fires and the directory has lost is the one no command clears, and
   the job whose files are there under no line is closed by a deploy. A probe
   that found only the direction it was written for would pass a fixture holding
   one of them.

   The reasons are matched on the job names and on the file an operator has to
   open, never transcribed whole: the sentences are
   [Bondi_common.Cron_divergence]'s and are pinned there. What is owed here is
   that the probe reported this host's jobs and named this host's own two
   sources -- the crontab it read the section from and the directory it listed
   the payloads in -- rather than the paths a production box happens to use. *)
let test_a_cron_divergence_is_a_fault_and_agreement_is_silence () =
  with_sources ~fires:[ "rotate" ] ~holds:[ "archive" ] (fun sources ~scratch ->
      match
        divergence_outcome
          (observe_sources ~cron_configured:true sources ~scratch)
      with
      | None -> fail "the divergence probe was not taken at all"
      | Some (Ok ()) ->
          fail "a host whose two sources disagree reported silence"
      | Some (Error reason) ->
          check bool "the line whose files are gone is named" true
            (String_utils.contains ~needle:"rotate" reason);
          check bool "the files no line fires are named too" true
            (String_utils.contains ~needle:"archive" reason);
          check bool "the unfixable direction names the file to open" true
            (String_utils.contains ~needle:sources.crontab reason);
          check bool "and the directory this probe actually read is named" true
            (String_utils.contains ~needle:sources.payload reason));
  with_sources ~fires:[ "rotate" ] ~holds:[ "rotate" ] (fun sources ~scratch ->
      match
        divergence_outcome
          (observe_sources ~cron_configured:true sources ~scratch)
      with
      | None -> fail "the divergence probe was not taken at all"
      | Some (Error reason) ->
          fail ("a host whose two sources agree reported: " ^ reason)
      | Some (Ok ()) -> ())

(* Two entries the writer could not have made, and one it could. The names in
   this directory come from [readdir] and go straight into a sentence that
   reaches an operator's terminal, an HTTP response and the container log, so
   what a caller may be told about is held to what the writer is able to create:
   a name the job-name rule accepts, under a directory holding at least one of
   the job's own files.

   [not a job] is the first filter -- a name with spaces in it, which no
   deployment could have produced -- and [archive] made bare is the second, the
   directory a run killed between the mkdir and the first write leaves behind.

   The affirmative arm is the same fixture with the same extra entry given a
   name the writer could have made and a file in it. Without it, a probe that
   had stopped reading the directory at all would report silence here and pass.
   *)
let test_a_payload_entry_the_writer_could_not_have_made_is_not_a_job () =
  with_sources ~fires:[ "rotate" ] ~holds:[ "rotate" ] (fun sources ~scratch ->
      payload_for sources.payload "not a job";
      Unix.mkdir (Filename.concat sources.payload "archive") 0o700;
      match
        divergence_outcome
          (observe_sources ~cron_configured:true sources ~scratch)
      with
      | None -> fail "the divergence probe was not taken at all"
      | Some (Error reason) ->
          fail ("neither entry is a job, yet the probe reported: " ^ reason)
      | Some (Ok ()) -> ());
  with_sources ~fires:[ "rotate" ] ~holds:[ "rotate"; "archive" ]
    (fun sources ~scratch ->
      match
        divergence_outcome
          (observe_sources ~cron_configured:true sources ~scratch)
      with
      | None -> fail "the divergence probe was not taken at all"
      | Some (Ok ()) ->
          fail "an entry the writer could have made is a job and must be named"
      | Some (Error reason) ->
          check bool "the job whose files no line fires is named" true
            (String_utils.contains ~needle:"archive" reason))

(* The contract the [.mli] states outright -- a source that could not be read
   yields no disagreement in either direction and the probe passes -- driven
   through [observe] rather than only through the pure rule, because the pure
   rule is reached with a [None] some reader had to produce and this is the
   reader that produces it. The crontab's own reader has this arm on the same
   file as its readable one; the payload directory's had none, and the arm it
   lacked is the dangerous one: a listing that failed reported as an empty
   directory names every line the host fires as a job whose files are gone, a
   fault whose own sentence says no command clears it, and sends an operator to
   hand-edit root's crontab on the strength of a read nobody obtained.

   The crontab side stays readable and keeps firing a job throughout, so the
   silence asserted below is the unread directory's and not a second empty
   source agreeing with the first. The affirmative arm is the same fixture one
   [chmod] earlier: readable, the probe is loud about exactly that job.

   Root would find the directory readable, so the arm asserts it is not running
   as root rather than skipping -- an arm that silently does not run proves
   nothing. *)
let test_a_payload_directory_that_will_not_open_is_no_disagreement () =
  check bool "the suite does not run as root, or this arm proves nothing" false
    (Int.equal (Unix.geteuid ()) 0);
  with_sources ~fires:[ "rotate" ] ~holds:[] (fun sources ~scratch ->
      Fun.protect
        ~finally:(fun () ->
          try Unix.chmod sources.payload 0o700 with
          | Unix.Unix_error _ -> ())
        (fun () ->
          (match
             divergence_outcome
               (observe_sources ~cron_configured:true sources ~scratch)
           with
          | None -> fail "the divergence probe was not taken at all"
          | Some (Ok ()) ->
              fail
                "a readable directory holding no files for the job the section \
                 fires must be loud"
          | Some (Error reason) ->
              check bool "the readable arm names the job whose files are gone"
                true
                (String_utils.contains ~needle:"rotate" reason));
          Unix.chmod sources.payload 0o000;
          match
            divergence_outcome
              (observe_sources ~cron_configured:true sources ~scratch)
          with
          | None -> fail "the divergence probe was not taken at all"
          | Some (Error reason) ->
              fail
                ("a directory that would not open was reported as empty: "
               ^ reason)
          | Some (Ok ()) -> ()))

(* Absent, not passing. A probe recorded as having passed on a box that was
   never asked the question is a claim about a source nobody read, and the
   document would carry it.

   The affirmative arm runs on the same fixture, and it is a fixture that
   diverges: without it a probe that had stopped being taken at all would satisfy
   the absence and nothing would notice. *)
let test_the_divergence_probe_is_absent_when_cron_is_not_configured () =
  with_sources ~fires:[ "rotate" ] ~holds:[ "archive" ] (fun sources ~scratch ->
      check
        (option (result unit string))
        "a deployment with no cron does not ask about the divergence" None
        (divergence_outcome
           (observe_sources ~cron_configured:false sources ~scratch));
      match
        divergence_outcome
          (observe_sources ~cron_configured:true sources ~scratch)
      with
      | None -> fail "the same fixture with cron configured must be asked"
      | Some (Ok ()) ->
          fail "the same fixture with cron configured must be loud"
      | Some (Error _) -> ())

let () =
  run "readiness"
    [
      ( "verdict",
        [
          test_case "all probes passing is ready" `Quick
            test_all_probes_passing_is_ready;
          test_case "a failing probe is not ready" `Quick
            test_a_failing_probe_is_not_ready;
          test_case "every failing probe is reported, not the first" `Quick
            test_every_failing_probe_is_reported;
          test_case "ready produces no error" `Quick
            test_ready_produces_no_error;
        ] );
      ( "cron divergence",
        [
          test_case "a divergence is a fault and agreement is silence" `Quick
            test_a_cron_divergence_is_a_fault_and_agreement_is_silence;
          test_case "the probe is absent when cron is not configured" `Quick
            test_the_divergence_probe_is_absent_when_cron_is_not_configured;
          test_case
            "a payload entry the writer could not have made is not a job" `Quick
            test_a_payload_entry_the_writer_could_not_have_made_is_not_a_job;
          test_case "a payload directory that will not open is no disagreement"
            `Quick
            test_a_payload_directory_that_will_not_open_is_no_disagreement;
        ] );
      ( "verdict json",
        [
          test_case "a ready observation list encodes every probe" `Quick
            test_a_ready_observation_list_encodes_every_probe;
          test_case "a failing observation carries its reason" `Quick
            test_a_failing_observation_carries_its_reason;
        ] );
    ]
