open Alcotest
module Cron_payload = Bondi_client.Cron_payload
module Crontab_listing = Bondi_client.Crontab_listing
module Remote_exec = Bondi_client.Remote_exec
module Cron_exec_line = Bondi_common.Cron_exec_line

let contains = Test_helpers.contains

(* --- Fixtures ---

   The two jobs every case reads through. Both are names a deploy could have
   created, so a job the fixtures report on is a job the host could hold. *)
let reporting_job = "nightly-report"
let alerting_job = "price-alert"

(* The server every report below names. A sentence that omitted it would read
   the same in a single-server run and lose the host in a multi-server one. *)
let server = "203.0.113.9"

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

(* The word the command prints after the last path, and only when the listing
   itself succeeded. A fixture that leaves it off is a listing that stopped
   part-way through, which is a different outcome carrying a different report --
   so every fixture below meaning "the directory was listed" closes with it, and
   the ones meaning "the listing never finished" leave it off deliberately. *)
let end_of_listing_marker = "BONDI_CRON_PAYLOAD_END"

(* Every listing is built by feeding the command's output through the reader
   production uses. A fixture that constructed the outcome directly could pin a
   state no host can produce. *)
let listing_of_output output = Cron_payload.of_listing_output (Ok output)

let listed files =
  listing_of_output
    (String.concat "\n" ((listed_marker :: files) @ [ end_of_listing_marker ]))

(* One distinctive transport failure. An assertion that a listing was not taken
   cannot pass on a generic failure the way "an error was returned" would. *)
let transport_failure =
  Remote_exec.Ssh_failed
    { code = 255; output = "Connection closed by 203.0.113.9 port 22" }

(* A third name, and one the sections below deliberately do not hand over: it is
   the job whose files are on the box with no line firing them, which is the
   direction nothing checked before. *)
let withdrawn_job = "stale-digest"

(* The shape an older bondi wrote, and the shape this estate still holds between
   a deploy and the rewrite that migrates it: the whole job inside a
   single-quoted JSON payload, secrets and all. The section reader cannot name
   it -- a name comes out of a run file's path and there is no such path on this
   line -- so it arrives as an entry with a position and nothing else, while
   going on firing on its schedule. Built as a real line rather than as a
   placeholder, because a placeholder cannot catch a report that echoed what the
   line carried. *)
let legacy_secret = "sk-live-9f3c1d77b0e24a8e"

let legacy_line ~schedule ~job =
  Printf.sprintf
    "%s /usr/bin/curl -sS --fail-with-body -X POST \
     http://localhost:3030/api/v1/run -H \"Content-Type: application/json\" -d \
     '{\"job\":\"%s\",\"env_vars\":{\"API_SECRET\":\"%s\"}}'"
    schedule job legacy_secret

(* What the crontab read command prints, as it prints it: the contents marker,
   the file, and the marker that says the read reached the last byte. Spelled
   here as the command spells it, and asserted against the command itself below
   -- a fixture carrying no marker would be read as a spool that never arrived,
   which is a different case with a different report. *)
let contents_marker = "BONDI_CRONTAB_CONTENTS"
let end_of_contents_marker = "BONDI_CRONTAB_END"
let begin_marker = "# BEGIN BONDI CRON"
let end_marker = "# END BONDI CRON"

let spool_of lines =
  Crontab_listing.of_read_output
    (Ok
       (String.concat "\n"
          ((contents_marker :: lines) @ [ end_of_contents_marker ])))

let render divergence =
  match divergence with
  | Cron_payload.Job_missing_files { job; shortfall } ->
      let missing =
        match shortfall with
        | Cron_payload.Env_file_missing -> "env"
        | Cron_payload.Run_file_missing -> "run"
        | Cron_payload.Both_files_missing -> "both"
      in
      job ^ ": " ^ missing
  | Cron_payload.Files_without_a_line { job; unnamed_entries } -> (
      match unnamed_entries with
      | [] -> job ^ ": no line"
      | positions ->
          job
          ^ ": no line (unnamed "
          ^ String.concat "," (List.map string_of_int positions)
          ^ ")")

let check_divergences ~expected ~crontab listing =
  check (list string) "divergences" expected
    (List.map render (Cron_payload.divergences ~crontab listing))

let both_jobs = [ reporting_job; alerting_job ]

(* The section the host answered with, in the shape the reader of it hands over.
   Every case below that means "the section was read" says so here, so the one
   case that means "it was not" cannot be mistaken for a fixture that forgot to
   name anybody. *)
let read jobs =
  Crontab_listing.Section
    { entries = List.map (fun job -> Crontab_listing.Named job) jobs }

let section_never_read =
  Crontab_listing.Unreadable "the host was not reached (255): Permission denied"

let check_report ~expected ~crontab listing =
  check (list string) "report" expected
    (Cron_payload.report ~server ~crontab listing)

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
  check_divergences ~expected:[] ~crontab:(read both_jobs) listing

(* The secret environment file survives nowhere. Nothing can recover it -- it
   never travelled in the crontab line -- so the job is named and the run goes
   on. The second job holds both files in the same listing, which is what makes
   the first one's absence the file's and not the fixture's. *)
let test_payload_job_without_its_env_file_is_named () =
  let listing =
    listed
      [ run_file reporting_job; env_file alerting_job; run_file alerting_job ]
  in
  check_divergences
    ~expected:[ reporting_job ^ ": env" ]
    ~crontab:(read both_jobs) listing

(* The run file survives nowhere. The line that reads it is still in the
   section, so the job fails at its next fire, and the same listing holds a job
   with both files to keep the absence the file's. *)
let test_payload_job_without_its_run_file_is_named () =
  let listing =
    listed
      [ env_file reporting_job; env_file alerting_job; run_file alerting_job ]
  in
  check_divergences
    ~expected:[ reporting_job ^ ": run" ]
    ~crontab:(read both_jobs) listing

(* A listing that was never taken is not a directory that is empty. Both ways of
   failing to take one -- the call never reaching the host, and the host saying
   it could not read the directory -- name no job at all.

   The affirmative arm is the same job list against the host positively
   answering that the directory is not there. That is the host's answer, every
   job has lost both files, and every job is named -- so the two empty results
   above are the refusal to guess rather than a fixture that names nobody. *)
let test_payload_unlisted_directory_is_not_an_absence () =
  check_divergences ~expected:[] ~crontab:(read both_jobs)
    (Cron_payload.of_listing_output (Error transport_failure));
  check_divergences ~expected:[] ~crontab:(read both_jobs)
    (listing_of_output unreadable_marker);
  check_divergences
    ~expected:[ reporting_job ^ ": both"; alerting_job ^ ": both" ]
    ~crontab:(read both_jobs)
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
  check_divergences ~expected:[] ~crontab:(read both_jobs)
    (listing_of_output unmarked);
  check_divergences
    ~expected:[ reporting_job ^ ": both"; alerting_job ^ ": both" ]
    ~crontab:(read both_jobs)
    (listing_of_output absent_marker)

(* The listing says where the paths end as well as where they begin. The guard
   only asks whether the directory can be opened, and a [find] that dies after
   it has answered -- refused by the same sudoers rule that permitted the
   [test], killed part-way through, or stopped on a subdirectory it could not
   descend -- still leaves the command exiting 0. So without a word after the
   last path there is nothing in the output to tell a listing that finished from
   one that stopped, and the sibling reader of the crontab carries exactly this
   marker for exactly this reason. *)
let test_payload_listing_command_marks_where_the_listing_ends () =
  let command = Cron_payload.listing_command in
  check bool "says where the paths end" true
    (contains ~needle:end_of_listing_marker command);
  match
    ( Bondi_common.String_utils.index_of ~needle:"find" command,
      Bondi_common.String_utils.index_of ~needle:end_of_listing_marker command
    )
  with
  | Some listed_at, Some marker_at ->
      check bool "and says it only once the directory has been listed" true
        (listed_at < marker_at);
      (* Printed as a statement of its own, joined by [;], the marker would run
         whatever the listing did and say the paths had ended whether they had
         or not. Joined to the listing, it is the listing's own success that
         prints it. *)
      check bool "and only when the listing succeeded" true
        (contains ~needle:"&&"
           (String.sub command listed_at (marker_at - listed_at)))
  | Some _, None -> fail "the command must say where the paths end"
  | None, Some _
  | None, None ->
      fail "the command must list the directory"

(* What the closing marker is for, and the failure it closes. A listing cut
   after the marker used to be a directory holding whatever the listing got to,
   so every job below the cut was reported as having lost its files -- a
   disagreement invented out of a read that never finished, and the same defect
   the crontab side carried in the opposite direction.

   Paired with the same paths listed to their end, because a reader answering
   "not listed" for everything would otherwise satisfy the first half. *)
let test_payload_truncated_listing_is_not_a_short_directory () =
  let cut_after_the_marker =
    String.concat "\n"
      [ listed_marker; env_file reporting_job; run_file reporting_job ]
  in
  check_divergences ~expected:[] ~crontab:(read both_jobs)
    (listing_of_output cut_after_the_marker);
  check_divergences
    ~expected:[ alerting_job ^ ": both" ]
    ~crontab:(read both_jobs)
    (listed [ env_file reporting_job; run_file reporting_job ])

(* The listing announced and never delivered: the guard passed, the marker was
   printed, and [find] then refused. That is not a directory holding nothing --
   answering it as one names every job the section fires as having lost both its
   files, on a listing nobody received. *)
let test_payload_listing_that_delivered_nothing_is_not_an_empty_directory () =
  let listing = listing_of_output (listed_marker ^ "\n") in
  (match listing with
  | Cron_payload.Unlisted message ->
      check bool "says the listing is what did not finish" true
        (contains ~needle:"listing" message)
  | Cron_payload.Root_absent ->
      fail "paths announced and never delivered is not an absent directory"
  | Cron_payload.Payloads _ ->
      fail "paths announced and never delivered are no paths at all");
  check_divergences ~expected:[] ~crontab:(read both_jobs) listing

(* The other side of that boundary, and the reason the case above cannot be read
   off the absence of paths alone. A directory the host listed and found empty
   prints the marker and then the closing one with nothing between, because
   there was nothing between -- and that is an answer: every job the section
   fires has lost both its files, which is a report worth making. *)
let test_payload_an_empty_directory_listed_whole_is_an_answer () =
  check_divergences
    ~expected:[ reporting_job ^ ": both"; alerting_job ^ ": both" ]
    ~crontab:(read both_jobs) (listed []);
  match listed [] with
  | Cron_payload.Payloads { files } ->
      check (list string) "and it holds no path" [] files
  | Cron_payload.Root_absent ->
      fail "a directory listed and found empty is not a directory that is gone"
  | Cron_payload.Unlisted message ->
      failf "a directory listed to its end is not a listing that failed: %s"
        message

(* A path is a name the host wrote, and what it may end in includes the word the
   command prints after the last path. Looked for as a bare suffix that word is
   indistinguishable from the tail of the last path a dying listing managed to
   deliver, so a listing cut on such a path would pass as one that finished.

   The marker is its own line or it is not the marker. The pair below is the
   difference: the same paths cut at that word are a listing that did not
   finish, and listed to their end are the directory they describe. *)
let path_ending_in_the_marker_word =
  Filename.concat
    (Filename.dirname (run_file withdrawn_job))
    ("run-" ^ end_of_listing_marker)

let test_payload_a_path_ending_in_the_marker_word_does_not_close_it () =
  let cut_on_a_path_carrying_the_word =
    String.concat "\n"
      [
        listed_marker;
        env_file reporting_job;
        run_file reporting_job;
        path_ending_in_the_marker_word;
      ]
  in
  check_divergences ~expected:[] ~crontab:(read both_jobs)
    (listing_of_output cut_on_a_path_carrying_the_word);
  check_divergences
    ~expected:[ alerting_job ^ ": both" ]
    ~crontab:(read both_jobs)
    (listed
       [
         env_file reporting_job;
         run_file reporting_job;
         path_ending_in_the_marker_word;
       ])

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
    (fun job ->
      check bool
        ("the command does not name " ^ job)
        false
        (contains ~needle:job Cron_payload.preserve_command))
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

(* A job the section names and whose two files are both absent is one loss, not
   two: the pair is reported as the single outcome that describes it, so the
   operator gets one sentence naming the job rather than one per file. The
   second job in the same call holds both files, which is what keeps the
   absence the directory's and not the fixture's -- without it a [divergences]
   that answered for nothing at all would pass.

   This is also the arm that keeps the reporting honest now that a job can no
   longer be answered from anywhere but the listing: every name the section
   hands over is asked of the directory, and the answer is one row. *)
let test_payload_job_missing_both_files_is_reported_once () =
  check_divergences
    ~expected:[ reporting_job ^ ": both" ]
    ~crontab:(read both_jobs)
    (listed [ env_file alerting_job; run_file alerting_job ]);
  (* The same job on a host that says the directory is not there: still one
     row, and still the outcome that names both files. *)
  check_divergences
    ~expected:[ reporting_job ^ ": both" ]
    ~crontab:(read [ reporting_job ])
    (listing_of_output absent_marker)

(* --- The report --- *)

(* The sentence is the whole of what an operator gets, and a report that named
   the right job while saying the wrong thing about it is exactly the defect
   this phase was rewritten for. Each outcome is asserted whole, against the
   listing that produces it. *)
let test_payload_report_says_what_each_outcome_costs () =
  let intact = [ env_file alerting_job; run_file alerting_job ] in
  let crontab = read both_jobs in
  check_report
    ~expected:
      [
        "cron job nightly-report on server 203.0.113.9 has no secret \
         environment file on the box, so it runs with an empty one until it is \
         deployed again";
      ]
    ~crontab
    (listed (run_file reporting_job :: intact));
  check_report
    ~expected:
      [
        "cron job nightly-report on server 203.0.113.9 has no run file on the \
         box, so it fails at its next fire until it is deployed again";
      ]
    ~crontab
    (listed (env_file reporting_job :: intact));
  check_report
    ~expected:
      [
        "cron job nightly-report on server 203.0.113.9 has neither its run \
         file nor its secret environment file on the box, so it fails at its \
         next fire until it is deployed again";
      ]
    ~crontab (listed intact)

(* The ordinary host says nothing at all, and a host whose directory could not
   be read says so out loud -- silence there would read as every job holding its
   files. The directory the host says is not there is its answer and not a
   failure to get one, so it adds no such sentence and names every job
   instead. *)
let test_payload_report_is_silent_only_when_there_is_nothing_to_say () =
  check_report ~expected:[] ~crontab:(read both_jobs)
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
    ~crontab:(read both_jobs)
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
    ~crontab:(read both_jobs)
    (listing_of_output absent_marker)

(* --- Both directions --- *)

(* The direction nothing checked before. A job whose files are on the box and
   whose line no longer fires them never runs at all, and no deploy repairs it:
   the configuration stopped declaring it, so nothing writes its line back.

   The affirmative arm is the same listing against a section that does name the
   job, where the report is empty -- so the entry above is the section's silence
   and not the fixture's. The third arm is the rule that keeps a name honest: a
   path under the payload root that is neither of a job's two files answers for
   no job rather than becoming one, so a stray file cannot invent a cron job. *)
let test_payload_files_the_section_does_not_name_are_reported () =
  let listing =
    listed
      [
        env_file reporting_job;
        run_file reporting_job;
        env_file withdrawn_job;
        run_file withdrawn_job;
      ]
  in
  check_divergences
    ~expected:[ withdrawn_job ^ ": no line" ]
    ~crontab:(read [ reporting_job ]) listing;
  check_report
    ~expected:
      [
        "cron job stale-digest on server 203.0.113.9 keeps its files on the \
         box and no crontab line fires them, so it never runs until it is \
         declared again";
      ]
    ~crontab:(read [ reporting_job ]) listing;
  check_divergences ~expected:[]
    ~crontab:(read [ reporting_job; withdrawn_job ])
    listing;
  check_divergences ~expected:[] ~crontab:(read [ reporting_job ])
    (listed
       [
         env_file reporting_job;
         run_file reporting_job;
         Filename.concat
           (Filename.concat Cron_exec_line.cron_root withdrawn_job)
           "notes.txt";
       ])

(* The claim the sentence above makes is a claim about the whole section, and it
   is only available when the whole section could be read. An entry no reader
   could name is a line that fires on its schedule all the same, and it may be
   the very line firing this job -- so the report hedges, and names the position
   an operator opens the file at.

   The affirmative arm is the same directory against a section read whole. There
   the unhedged sentence is the true one and stays: every line was read, none of
   them fires this job, and the job genuinely never runs. *)
let test_payload_an_unnamed_entry_hedges_the_orphan_sentence () =
  let listing =
    listed
      [
        env_file reporting_job;
        run_file reporting_job;
        env_file withdrawn_job;
        run_file withdrawn_job;
      ]
  in
  let section_with_an_unnamed_entry =
    Crontab_listing.Section
      {
        entries =
          [
            Crontab_listing.Named reporting_job;
            Crontab_listing.Unnamed { position = 2 };
          ];
      }
  in
  check_divergences
    ~expected:[ withdrawn_job ^ ": no line (unnamed 2)" ]
    ~crontab:section_with_an_unnamed_entry listing;
  check_report
    ~expected:
      [
        "cron job stale-digest on server 203.0.113.9 keeps its files on the \
         box and no crontab line that could be read fires them: entry 2 of the \
         section could not be read, and an entry nobody could read may be the \
         line that fires it";
      ]
    ~crontab:section_with_an_unnamed_entry listing;
  check_report
    ~expected:
      [
        "cron job stale-digest on server 203.0.113.9 keeps its files on the \
         box and no crontab line fires them, so it never runs until it is \
         declared again";
      ]
    ~crontab:(read [ reporting_job ]) listing

(* Every entry nobody could name is a line that may be the one firing this job,
   so every one of their positions is on the line an operator reads -- naming
   the first and stopping would send them to one line of a file holding three.
   The three arms of the phrase are all here: one position, and a list whose
   last is joined differently from the rest. *)
let test_payload_every_unnamed_entry_is_named () =
  let listing = listed [ env_file withdrawn_job; run_file withdrawn_job ] in
  let section_of positions =
    Crontab_listing.Section
      {
        entries =
          List.map
            (fun position -> Crontab_listing.Unnamed { position })
            positions;
      }
  in
  check_report
    ~expected:
      [
        "cron job stale-digest on server 203.0.113.9 keeps its files on the \
         box and no crontab line that could be read fires them: entries 1 and \
         2 of the section could not be read, and an entry nobody could read \
         may be the line that fires it";
      ]
    ~crontab:(section_of [ 1; 2 ])
    listing;
  check_report
    ~expected:
      [
        "cron job stale-digest on server 203.0.113.9 keeps its files on the \
         box and no crontab line that could be read fires them: entries 1, 3 \
         and 4 of the section could not be read, and an entry nobody could \
         read may be the line that fires it";
      ]
    ~crontab:(section_of [ 1; 3; 4 ])
    listing

(* The host that makes the hedge worth having, and it is not hypothetical: the
   orchestrator migrates a legacy line when it next rewrites the section, so a
   partially migrated host sits in this state between deploys. Its line fires
   [daily-close] and its files are on the box -- the job runs -- and the reader
   of the section cannot name the line. Read as an orphan it would be reported
   as a job that never runs, on the strength of a line that fires it.

   The spool is a real one, read through the reader production uses, so the
   entry is unnamed because the line's own shape made it so. And the line
   carries a live secret in its payload, so the report saying anything about
   this job is also the assertion that it says nothing of what the line held. *)
let test_payload_a_legacy_line_is_not_an_orphan () =
  let job = "daily-close" in
  let crontab =
    spool_of
      [ begin_marker; legacy_line ~schedule:"5 21 * * 1-5" ~job; end_marker ]
  in
  (match crontab with
  | Crontab_listing.Section { entries = [ Crontab_listing.Unnamed _ ] } -> ()
  | Crontab_listing.Section _
  | Crontab_listing.No_section
  | Crontab_listing.Malformed _
  | Crontab_listing.Unreadable _ ->
      fail "the fixture must reach a section holding one entry nobody can name");
  let listing = listed [ env_file job; run_file job ] in
  let report = Cron_payload.report ~server ~crontab listing in
  check (list string) "report"
    [
      "cron job daily-close on server 203.0.113.9 keeps its files on the box \
       and no crontab line that could be read fires them: entry 1 of the \
       section could not be read, and an entry nobody could read may be the \
       line that fires it";
    ]
    report;
  check bool "no part of the line reaches the report" false
    (List.exists (contains ~needle:legacy_secret) report);
  (* The fixture is only a spool for as long as the command still says these
     two words. *)
  List.iter
    (fun marker ->
      check bool
        ("the crontab read command says " ^ marker)
        true
        (contains ~needle:marker Crontab_listing.read_command))
    [ contents_marker; end_of_contents_marker ]

(* The other direction, in the same answer as the first. A host can be wrong
   both ways at once -- a line whose files are gone and files whose line is gone
   -- and an operator reading one report has to see both, in a fixed order, with
   the job named on each line.

   The contrast arm is the same listing against a section naming both jobs: the
   second entry disappears and the first stays, which is what shows each entry
   is answered from its own source rather than from the fixture's shape. *)
let test_payload_a_job_the_section_names_and_the_directory_lacks_is_reported ()
    =
  let listing = listed [ env_file withdrawn_job; run_file withdrawn_job ] in
  check_divergences
    ~expected:[ reporting_job ^ ": both"; withdrawn_job ^ ": no line" ]
    ~crontab:(read [ reporting_job ]) listing;
  check_divergences
    ~expected:[ reporting_job ^ ": both" ]
    ~crontab:(read [ reporting_job; withdrawn_job ])
    listing

(* Silence is the whole of what an agreeing host says, and it is only meaningful
   if it is reachable: every loud case above is legible because this one prints
   nothing. The affirmative arm is the same listing with one of the two names
   withheld from the section, which turns the silence into a named entry -- so
   the emptiness is the two sources agreeing and not a call that answered
   nothing. *)
let test_payload_agreeing_sources_report_nothing () =
  let listing =
    listed
      [
        env_file reporting_job;
        run_file reporting_job;
        env_file alerting_job;
        run_file alerting_job;
      ]
  in
  check_divergences ~expected:[] ~crontab:(read both_jobs) listing;
  check_report ~expected:[] ~crontab:(read both_jobs) listing;
  check_divergences
    ~expected:[ alerting_job ^ ": no line" ]
    ~crontab:(read [ reporting_job ]) listing

(* A listing that was never taken is not a directory that is empty, and it is
   not agreement either. No job is named in either direction -- the first would
   be a claim about files nobody looked at, the second a claim about their
   absence -- and the report says so on its own line rather than printing
   nothing, because nothing here reads as "the two sources agree".

   The line carries the transport's own account of the failure, which is the
   operator's only evidence of what went wrong. The affirmative arm is the same
   job list against the host answering that the directory is not there, where
   every job is named and no such line prints. *)
let test_payload_a_listing_never_taken_is_said_out_loud () =
  let never_taken = Cron_payload.of_listing_output (Error transport_failure) in
  check_divergences ~expected:[] ~crontab:(read both_jobs) never_taken;
  (match Cron_payload.report ~server ~crontab:(read both_jobs) never_taken with
  | [ line ] ->
      check bool "the report says the listing was not taken" true
        (contains ~needle:"still hold their files could not be read" line);
      check bool "and carries the transport's own account of it" true
        (contains ~needle:"Connection closed by 203.0.113.9 port 22" line)
  | lines ->
      failf "a listing never taken says one thing, not %d" (List.length lines));
  check_divergences
    ~expected:[ reporting_job ^ ": both"; alerting_job ^ ": both" ]
    ~crontab:(read both_jobs)
    (listing_of_output absent_marker)

(* The directory the host says is not there is the host answering. Every job the
   section names has lost both its files, every one of them is named, and no
   line says the listing could not be read -- that would be this report claiming
   it never got an answer when it got one.

   Nothing is reported in the other direction, because a directory that is not
   there holds no file whose line could be missing. *)
let test_payload_an_absent_directory_is_the_host_answering () =
  let absent = listing_of_output absent_marker in
  check_divergences
    ~expected:[ reporting_job ^ ": both"; alerting_job ^ ": both" ]
    ~crontab:(read both_jobs) absent;
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
    ~crontab:(read both_jobs) absent

(* The same discipline on the other source. A section nobody could read names no
   job, and a section a host answered with no Bondi lines at all names no job
   either -- but only the second is an answer. Told apart by nothing, a host
   whose crontab could not be read would have every job in its payload directory
   reported as having no line firing it, which is the same false report the
   unread listing above exists to prevent.

   The affirmative arm is the same directory against a section the host did
   answer with, holding no line: there the files with no line are exactly what
   the report exists to name. *)
let test_payload_a_section_never_read_is_said_out_loud () =
  let listing = listed [ env_file withdrawn_job; run_file withdrawn_job ] in
  check_divergences ~expected:[] ~crontab:section_never_read listing;
  check_report
    ~expected:
      [
        "which cron jobs on server 203.0.113.9 are scheduled to run could not \
         be read, so whether the files on the box still have a line firing \
         them is unknown";
      ]
    ~crontab:section_never_read listing;
  check_divergences
    ~expected:[ withdrawn_job ^ ": no line" ]
    ~crontab:(read []) listing

(* Markers that do not balance are not a section that names nobody, and the
   distinction is the same one the unread section above turns on. The file was
   delivered, so it is tempting to treat what it holds as read -- but which
   lines are Bondi's is exactly what an unbalanced file does not say, and the
   entries it does hold may include the very line firing a job whose files are
   in the directory. Answered as a section holding no names, every one of those
   files is reported as having lost its line, which is the invented
   disagreement this module refuses everywhere else.

   {!Malformed} and {!Unreadable} are separate values and earn this silence for
   separate reasons -- a file whose markers are broken against a file that never
   arrived -- so neither may stand in for the other in a case. The affirmative
   arm is the same directory against a section the host answered with, holding
   no Bondi line at all: there every file is an orphan and is named. *)
let test_payload_a_malformed_section_is_not_a_section_naming_nobody () =
  let listing = listed [ env_file withdrawn_job; run_file withdrawn_job ] in
  let crontab =
    spool_of
      [ begin_marker; legacy_line ~schedule:"0 3 * * *" ~job:withdrawn_job ]
  in
  (match crontab with
  | Crontab_listing.Malformed _ -> ()
  | Crontab_listing.Section _
  | Crontab_listing.No_section
  | Crontab_listing.Unreadable _ ->
      fail "the fixture must reach a section whose markers do not balance");
  check_divergences ~expected:[] ~crontab listing;
  check_report
    ~expected:
      [
        "which cron jobs on server 203.0.113.9 are scheduled to run could not \
         be read, so whether the files on the box still have a line firing \
         them is unknown";
      ]
    ~crontab listing;
  check_divergences
    ~expected:[ withdrawn_job ^ ": no line" ]
    ~crontab:(read []) listing

(* One cause, one sentence. The host whose ssh user cannot take a privileged
   read fails both reads for that one reason, and the operator was told it three
   times: the crontab cell, then the section's line, then the directory's, with
   the transport's account of the failure carried in two of them. Both sources
   are named in one sentence here, and the account is carried once.

   What does not collapse is one source failing on its own. A section read
   against a directory that was not, and the reverse, are different facts about
   the host and each keeps its own wording -- which is what the two cases above
   assert. *)
let test_payload_neither_source_read_is_one_sentence () =
  check_report
    ~expected:
      [
        "which cron jobs on server 203.0.113.9 are scheduled to run could not \
         be read, and neither could which of them still hold their files: the \
         host was not reached (255): Connection closed by 203.0.113.9 port 22";
      ]
    ~crontab:section_never_read
    (Cron_payload.of_listing_output (Error transport_failure))

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
          test_case "a job missing both files is reported once" `Quick
            test_payload_job_missing_both_files_is_reported_once;
          test_case "output carrying no marker is not an answer" `Quick
            test_payload_output_without_a_marker_is_not_an_answer;
          test_case "the command says where the paths end" `Quick
            test_payload_listing_command_marks_where_the_listing_ends;
          test_case "a truncated listing is not a shorter directory" `Quick
            test_payload_truncated_listing_is_not_a_short_directory;
          test_case
            "paths announced and never delivered are not an empty directory"
            `Quick
            test_payload_listing_that_delivered_nothing_is_not_an_empty_directory;
          test_case "a directory listed and found empty is an answer" `Quick
            test_payload_an_empty_directory_listed_whole_is_an_answer;
          test_case
            "a path ending in the marker word does not close the listing" `Quick
            test_payload_a_path_ending_in_the_marker_word_does_not_close_it;
        ] );
      ( "the report",
        [
          test_case "says what each outcome costs the operator" `Quick
            test_payload_report_says_what_each_outcome_costs;
          test_case "is silent only when there is nothing to say" `Quick
            test_payload_report_is_silent_only_when_there_is_nothing_to_say;
        ] );
      ( "both directions",
        [
          test_case
            "a job whose files the directory holds and whose line the section \
             lacks is reported"
            `Quick test_payload_files_the_section_does_not_name_are_reported;
          test_case
            "a job the section names and the directory does not hold is \
             reported"
            `Quick
            test_payload_a_job_the_section_names_and_the_directory_lacks_is_reported;
          test_case
            "an entry nobody could name hedges the sentence about files with \
             no line"
            `Quick test_payload_an_unnamed_entry_hedges_the_orphan_sentence;
          test_case
            "a legacy line that fires a job is not that job's files going \
             unfired"
            `Quick test_payload_a_legacy_line_is_not_an_orphan;
          test_case "every entry nobody could name is on the line" `Quick
            test_payload_every_unnamed_entry_is_named;
          test_case "a host whose two sources agree reports nothing" `Quick
            test_payload_agreeing_sources_report_nothing;
          test_case
            "a listing that was never taken yields no divergence and is said \
             out loud"
            `Quick test_payload_a_listing_never_taken_is_said_out_loud;
          test_case
            "a directory the host says is absent is the host answering, and \
             every job is named"
            `Quick test_payload_an_absent_directory_is_the_host_answering;
          test_case
            "a section that was never read yields no divergence and is said \
             out loud"
            `Quick test_payload_a_section_never_read_is_said_out_loud;
          test_case
            "a section whose markers do not balance is not a section naming \
             nobody"
            `Quick
            test_payload_a_malformed_section_is_not_a_section_naming_nobody;
          test_case
            "two reads that both failed are one sentence naming both sources"
            `Quick test_payload_neither_source_read_is_one_sentence;
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
