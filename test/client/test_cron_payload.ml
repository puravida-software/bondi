open Alcotest
module Cron_payload = Bondi_client.Cron_payload
module Remote_exec = Bondi_client.Remote_exec
module Cron_exec_line = Bondi_common.Cron_exec_line
module Crontab_listing = Bondi_client.Crontab_listing

let contains = Test_helpers.contains

(* --- Fixtures ---

   The two jobs every case reads through. Both are names a deploy could have
   created, so a job the fixtures report on is a job the host could hold. *)
let reporting_job = "nightly-report"
let alerting_job = "price-alert"

(* The server every report below names. A sentence that omitted it would read
   the same in a single-server run and lose the host in a multi-server one. *)
let server = "203.0.113.9"

(* The two line shapes a job's name can arrive from, built as the section reader
   builds them. What is true of a job's files depends entirely on which one
   named it, so a fixture that could only produce one shape could not tell the
   two apart. *)
let from_exec_line job : Crontab_listing.named_job =
  { job; shape = Crontab_listing.Exec_line }

let from_legacy_line job : Crontab_listing.named_job =
  { job; shape = Crontab_listing.Legacy_line }

(* The paths the writer of the files uses, taken from the writer's own module
   rather than spelled here: a fixture spelling them a second time would keep
   passing after the two had drifted apart, which is the one failure the shared
   path exists to prevent. *)
let env_file = Cron_exec_line.env_file_of
let run_file = Cron_exec_line.run_file_of

(* The markers are the listing command's own words, and the command is asserted
   to still carry all three below. A fixture built from bare paths would be read
   as an answer that carried no marker at all, which is the outcome that means
   "unknown" -- so every case here would assert nothing. *)
let listed_marker = "BONDI_CRON_PAYLOAD_LISTED"
let absent_marker = "BONDI_CRON_PAYLOAD_ABSENT"
let unreadable_marker = "BONDI_CRON_PAYLOAD_UNREADABLE"

(* Every listing is built by feeding the command's output through the reader
   production uses. A fixture that constructed the outcome directly could pin a
   state no host can produce. *)
let listing_of_output output = Cron_payload.of_listing_output (Ok output)

let listed files =
  listing_of_output (String.concat "\n" (listed_marker :: files))

(* One distinctive transport failure. An assertion that a listing was not taken
   cannot pass on a generic failure the way "an error was returned" would. *)
let transport_failure =
  Remote_exec.Ssh_failed
    { code = 255; output = "Connection closed by 203.0.113.9 port 22" }

let render (job, shortfall) =
  let missing =
    match shortfall with
    | Cron_payload.Env_file_missing -> "env"
    | Cron_payload.Run_file_missing -> "run"
    | Cron_payload.Both_files_missing -> "both"
    | Cron_payload.Payload_on_the_line -> "legacy"
  in
  job ^ ": " ^ missing

let check_shortfalls ~expected ~jobs listing =
  check (list string) "shortfalls" expected
    (List.map render (Cron_payload.shortfalls ~jobs listing))

let both_jobs = [ from_exec_line reporting_job; from_exec_line alerting_job ]

let check_report ~expected ~jobs listing =
  check (list string) "report" expected
    (Cron_payload.report ~server ~jobs listing)

(* --- Cases --- *)

(* The ordinary case, and the one every other case here is a departure from: a
   job whose two files are both on the host is not something to tell an operator
   about. *)
let test_payload_job_holding_both_files_is_not_reported () =
  let listing =
    listed
      [
        env_file reporting_job;
        run_file reporting_job;
        env_file alerting_job;
        run_file alerting_job;
      ]
  in
  check_shortfalls ~expected:[] ~jobs:both_jobs listing

(* The secret environment file survives nowhere. Nothing can recover it -- it
   never travelled in the crontab line -- so the job is named and the run goes
   on. The second job holds both files in the same listing, which is what makes
   the first one's absence the file's and not the fixture's. *)
let test_payload_job_without_its_env_file_is_named () =
  let listing =
    listed
      [ run_file reporting_job; env_file alerting_job; run_file alerting_job ]
  in
  check_shortfalls ~expected:[ reporting_job ^ ": env" ] ~jobs:both_jobs listing

(* The run file survives nowhere. The line that reads it is still in the
   section, so the job fails at its next fire, and the same listing holds a job
   with both files to keep the absence the file's. *)
let test_payload_job_without_its_run_file_is_named () =
  let listing =
    listed
      [ env_file reporting_job; env_file alerting_job; run_file alerting_job ]
  in
  check_shortfalls ~expected:[ reporting_job ^ ": run" ] ~jobs:both_jobs listing

(* A listing that was never taken is not a directory that is empty. Both ways of
   failing to take one -- the call never reaching the host, and the host saying
   it could not read the directory -- name no job at all.

   The affirmative arm is the same job list against the host positively
   answering that the directory is not there. That is the host's answer, every
   job has lost both files, and every job is named -- so the two empty results
   above are the refusal to guess rather than a fixture that names nobody. *)
let test_payload_unlisted_directory_is_not_an_absence () =
  check_shortfalls ~expected:[] ~jobs:both_jobs
    (Cron_payload.of_listing_output (Error transport_failure));
  check_shortfalls ~expected:[] ~jobs:both_jobs
    (listing_of_output unreadable_marker);
  check_shortfalls
    ~expected:[ reporting_job ^ ": both"; alerting_job ^ ": both" ]
    ~jobs:both_jobs
    (listing_of_output absent_marker);
  (* The fixtures above are only honest while the command still says these three
     words. *)
  List.iter
    (fun marker ->
      check bool
        ("the listing command says " ^ marker)
        true
        (contains ~needle:marker Cron_payload.listing_command))
    [ listed_marker; absent_marker; unreadable_marker ]

(* Output carrying none of the command's three markers is a command that
   answered without saying which of the three happened, and the plausible wrong
   reading is the one this module's own interface warns against: a stub, a
   truncated stream and a shell that never ran the command all answer with
   nothing, so reading that as the host positively saying the directory is not
   there would name every job on the box as having lost both its files, on the
   strength of a read that never happened. The sibling reader of the crontab
   carries this same case for this same reason. *)
let test_payload_output_without_a_marker_is_not_an_answer () =
  let unmarked = "Warning: Permanently added '10.0.0.1' to known hosts.\n" in
  (match Cron_payload.of_listing_output (Ok unmarked) with
  | Cron_payload.Unlisted _ -> ()
  | Cron_payload.Root_absent ->
      fail
        "output carrying no marker is not the host answering that the \
         directory is absent"
  | Cron_payload.Payloads _ -> fail "output carrying no marker reports no file");
  (* And the consequence the distinction is kept for: no job is named. The
     affirmative arm is the same job list against the host positively saying the
     directory is not there, where every job is named -- so the emptiness above
     is this reader refusing to guess and not a fixture that reaches nobody. *)
  check_shortfalls ~expected:[] ~jobs:both_jobs (listing_of_output unmarked);
  check_shortfalls
    ~expected:[ reporting_job ^ ": both"; alerting_job ^ ": both" ]
    ~jobs:both_jobs
    (listing_of_output absent_marker)

(* The copy names the directory and nothing inside it. A per-job copy would put
   a job's name into a command line on both machines, and a path assembled from
   anything the host reported would put that there too. Every path the command
   carries is therefore the payload root itself, whether or not it is prefixed
   by the container it is read from. *)
let test_payload_preserve_command_names_no_job_and_no_inner_path () =
  let root = Cron_exec_line.cron_root in
  let strip_prefix ~prefix value =
    let n = String.length prefix in
    if String.length value >= n && String.sub value 0 n = prefix then
      String.sub value n (String.length value - n)
    else value
  in
  let strip_suffix ~suffix value =
    let n = String.length suffix and len = String.length value in
    if len >= n && String.sub value (len - n) n = suffix then
      String.sub value 0 (len - n)
    else value
  in
  let paths =
    Cron_payload.preserve_command
    |> String.split_on_char ' '
    |> List.concat_map (String.split_on_char '\t')
    |> List.filter (fun token -> String.contains token '/')
  in
  check bool "the command carries paths at all" true (paths <> []);
  List.iter
    (fun path ->
      let reduced =
        path
        |> strip_prefix ~prefix:"'"
        |> strip_suffix ~suffix:"'"
        |> strip_prefix ~prefix:"bondi-orchestrator:"
        |> strip_suffix ~suffix:"/."
      in
      check string "every path is the payload root" root reduced)
    paths;
  List.iter
    (fun (named : Crontab_listing.named_job) ->
      check bool
        ("the command does not name " ^ named.job)
        false
        (contains ~needle:named.job Cron_payload.preserve_command))
    both_jobs

(* The preserve command runs on hosts whose crontab could not be read, because a
   read that failed is deliberately planned as a preserve. A crontab that could
   not be read is a host without passwordless sudo, so the copy is planned
   precisely where its own [sudo -n] calls will be refused -- and a non-zero exit
   there reaches the caller as a transport error and aborts the run at the
   orchestrator phase. A cron-only box that set up yesterday would stop setting
   up today. The listing is the reporter; this command never is. *)
let test_payload_preserve_command_always_exits_zero () =
  check bool "the preserve command ends by exiting 0" true
    (String.ends_with ~suffix:"; exit 0"
       (String.trim Cron_payload.preserve_command))

(* The copy must not run where the payload directory the container writes is the
   host directory being written into: [docker cp] streams, so the extraction
   would truncate a file the archiver has not finished reading. What decides
   that is whether the container holds the directory as a mount, and the
   container is what knows. Guarding on the host directory holding anything
   answers a different question, and answers it wrong after any interrupted
   copy: the residue left behind is non-empty and incomplete, and every later
   run skips the copy on the strength of it, forever. *)
let test_payload_preserve_guard_asks_docker_for_the_mount () =
  let says needle = contains ~needle Cron_payload.preserve_command in
  check bool "asks the container what it has mounted" true
    (says "docker inspect");
  check bool "reads the mount destinations" true (says ".Mounts");
  check bool "compares against the payload root" true
    (says ("grep -Fxq " ^ Filename.quote Cron_exec_line.cron_root));
  check bool "does not guard on what the host directory holds" false
    (says "-mindepth")

(* A legacy line carries its whole payload, so the job it names has no run file
   and no environment file and never had either. Reporting that absence the way
   an exec-line job's is reported would tell an operator that every unmigrated
   job on the box fails at its next fire -- on the boxes this phase was written
   for, that is most of them, and it is the sentence an operator pages on. The
   exec-line job in the same call has genuinely lost both files, so the two
   cannot be collapsed without the check seeing it. *)
let test_payload_legacy_job_is_not_a_loss () =
  check_shortfalls
    ~expected:[ reporting_job ^ ": legacy"; alerting_job ^ ": both" ]
    ~jobs:[ from_legacy_line reporting_job; from_exec_line alerting_job ]
    (listed []);
  (* And no answer the directory gives changes it. What makes this job legacy
     was read from the crontab, not from the directory, so the arm that refuses
     to guess from a listing nobody took does not silence it either. *)
  check_shortfalls
    ~expected:[ reporting_job ^ ": legacy" ]
    ~jobs:[ from_legacy_line reporting_job ]
    (Cron_payload.of_listing_output (Error transport_failure));
  check_shortfalls
    ~expected:[ reporting_job ^ ": legacy" ]
    ~jobs:[ from_legacy_line reporting_job ]
    (listing_of_output absent_marker)

(* --- The report --- *)

(* The sentence is the whole of what an operator gets, and a report that named
   the right job while saying the wrong thing about it is exactly the defect
   this phase was rewritten for. Each outcome is asserted whole, against the
   listing that produces it. *)
let test_payload_report_says_what_each_outcome_costs () =
  let intact = [ env_file alerting_job; run_file alerting_job ] in
  let jobs = both_jobs in
  check_report
    ~expected:
      [
        "cron job nightly-report on server 203.0.113.9 has no secret \
         environment file on the box, so it runs with an empty one until it is \
         deployed again";
      ]
    ~jobs
    (listed (run_file reporting_job :: intact));
  check_report
    ~expected:
      [
        "cron job nightly-report on server 203.0.113.9 has no run file on the \
         box, so it fails at its next fire until it is deployed again";
      ]
    ~jobs
    (listed (env_file reporting_job :: intact));
  check_report
    ~expected:
      [
        "cron job nightly-report on server 203.0.113.9 has neither its run \
         file nor its secret environment file on the box, so it fails at its \
         next fire until it is deployed again";
      ]
    ~jobs (listed intact);
  check_report
    ~expected:
      [
        "cron job nightly-report on server 203.0.113.9 still runs from its \
         legacy crontab line, which carries its payload rather than reading \
         files, so it has lost nothing: deploy it again to move it onto a run \
         file";
      ]
    ~jobs:[ from_legacy_line reporting_job; from_exec_line alerting_job ]
    (listed intact)

(* The ordinary host says nothing at all, and a host whose directory could not
   be read says so out loud -- silence there would read as every job holding its
   files. The directory the host says is not there is its answer and not a
   failure to get one, so it adds no such sentence and names every job
   instead. *)
let test_payload_report_is_silent_only_when_there_is_nothing_to_say () =
  check_report ~expected:[] ~jobs:both_jobs
    (listed
       [
         env_file reporting_job;
         run_file reporting_job;
         env_file alerting_job;
         run_file alerting_job;
       ]);
  check_report
    ~expected:
      [
        "which cron jobs on server 203.0.113.9 still hold their files could \
         not be read: the host could not read the directory its cron jobs keep \
         their files in, so which of them still have theirs is unknown";
      ]
    ~jobs:both_jobs
    (listing_of_output unreadable_marker);
  check_report
    ~expected:
      [
        "cron job nightly-report on server 203.0.113.9 has neither its run \
         file nor its secret environment file on the box, so it fails at its \
         next fire until it is deployed again";
        "cron job price-alert on server 203.0.113.9 has neither its run file \
         nor its secret environment file on the box, so it fails at its next \
         fire until it is deployed again";
      ]
    ~jobs:both_jobs
    (listing_of_output absent_marker)

let () =
  run "cron payload"
    [
      ( "what survives",
        [
          test_case "a job holding both files is not reported" `Quick
            test_payload_job_holding_both_files_is_not_reported;
          test_case "a job whose env file is absent is named" `Quick
            test_payload_job_without_its_env_file_is_named;
          test_case "a job whose run file is absent is named" `Quick
            test_payload_job_without_its_run_file_is_named;
          test_case "a directory that could not be listed is not an absence"
            `Quick test_payload_unlisted_directory_is_not_an_absence;
          test_case "a job named by a legacy line has lost nothing" `Quick
            test_payload_legacy_job_is_not_a_loss;
          test_case "output carrying no marker is not an answer" `Quick
            test_payload_output_without_a_marker_is_not_an_answer;
        ] );
      ( "the report",
        [
          test_case "says what each outcome costs the operator" `Quick
            test_payload_report_says_what_each_outcome_costs;
          test_case "is silent only when there is nothing to say" `Quick
            test_payload_report_is_silent_only_when_there_is_nothing_to_say;
        ] );
      ( "secrets",
        [
          test_case
            "the preserve command names no job and no path outside the payload \
             root"
            `Quick test_payload_preserve_command_names_no_job_and_no_inner_path;
        ] );
      ( "the copy",
        [
          test_case "the preserve command always exits 0" `Quick
            test_payload_preserve_command_always_exits_zero;
          test_case "the copy's guard asks the container for its mounts" `Quick
            test_payload_preserve_guard_asks_docker_for_the_mount;
        ] );
    ]
