open Alcotest
module Listing = Bondi_client.Crontab_listing
module Remote_exec = Bondi_client.Remote_exec

let contains = Test_helpers.contains

(* --- Fixtures ---

   Every fixture below is a spool file as the orchestrator writes it: a marked
   section of curl invocations, each carrying its job description inside the
   payload of a -d argument. The payload is where the secrets live, so the
   fixtures carry a realistic one rather than a sanitised placeholder — a
   sanitised entry cannot catch a parser that hands the payload back.

   The one builder every test reads through takes the spool's lines, because
   that is the only input a listing has: two arms differing in their outcome
   can only differ because of what the file said. *)

(* Single quotes reach the spool file the way the writer puts them there, as
   '\'' — so a payload carrying one is only readable by a parser that undoes
   the escaping. Alert titles and secrets both carry apostrophes in practice,
   and an entry made unreadable by one would be a job reported as broken for no
   reason. *)
let escape_for_shell value =
  String.concat "'\\''" (String.split_on_char '\'' value)

let entry ~schedule ~job ~secret =
  let payload =
    Printf.sprintf
      "{\"job\":\"%s\",\"image\":\"acme/%s:latest\",\"env_vars\":{\"API_SECRET\":\"%s\",\"ALERT_TITLE\":\"o'clock \
       close\"}}"
      job job secret
  in
  Printf.sprintf
    "%s /usr/bin/curl -sS --fail-with-body -X POST \
     http://localhost:3030/api/v1/run -H \"Content-Type: application/json\" -d \
     '%s'"
    schedule (escape_for_shell payload)

let secret = "sk-live-9f3c1d77b0e24a8e"
let daily_close = entry ~schedule:"5 21 * * 1-5" ~job:"daily-close" ~secret
let rebalance = entry ~schedule:"0 6 * * *" ~job:"rebalance" ~secret

(* The same entry as [rebalance], cut where a partial write or a hand-edit would
   leave it: the payload is still on the line, and still carries the secret, but
   its quoting no longer closes. Its twin above is what makes the pair
   meaningful — the two differ only in the three characters that end it. *)
let rebalance_truncated = String.sub rebalance 0 (String.length rebalance - 3)

(* A line an operator added by hand, outside anything Bondi wrote. It carries
   the same secret shape, so a parser that reads the whole file rather than the
   marked section leaks it just as surely as one that quotes a Bondi entry. *)
let hand_added = entry ~schedule:"*/5 * * * *" ~job:"operator-cleanup" ~secret
let begin_marker = "# BEGIN BONDI CRON"
let end_marker = "# END BONDI CRON"

(* What the read command prints, as it prints it. The contents marker comes
   first and the file follows it, which is the property the redaction below
   rests on: nothing the file holds can appear ahead of the marker. *)
let contents_marker = "BONDI_CRONTAB_CONTENTS"
let absent_marker = "BONDI_CRONTAB_ABSENT"
let unreadable_marker = "BONDI_CRONTAB_UNREADABLE"

let spool_of lines =
  Listing.of_read_output (Ok (String.concat "\n" (contents_marker :: lines)))

let well_formed = [ begin_marker; daily_close; rebalance; end_marker; "" ]

let with_truncated_entry =
  [ begin_marker; daily_close; rebalance_truncated; end_marker; "" ]

let empty_section = [ begin_marker; end_marker; "" ]
let no_markers = [ hand_added; "" ]
let end_without_begin = [ daily_close; end_marker; "" ]
let never_ends = [ begin_marker; daily_close; "" ]

let nested =
  [ begin_marker; daily_close; begin_marker; rebalance; end_marker; "" ]

(* The shape the orchestrator writes now: a schedule, a [docker exec] into the
   orchestrator, and the path of the job's run file. There is no payload on the
   line, which is the whole point of it — and it is also why the job's name can
   only come from the path.

   The command and the path are Bondi_common.Cron_exec_line's, which is where
   the orchestrator's writer takes them from too. Spelled out by hand they were
   a fixture that goes on passing after the emitted line changes, while every
   job on every box reports as unnamed. *)
let exec_line ~schedule ~path =
  Printf.sprintf "%s docker exec bondi-orchestrator sh -c '%s%s'" schedule
    Bondi_common.Cron_exec_line.exec_marker path

let exec_entry ~schedule ~job =
  exec_line ~schedule ~path:(Bondi_common.Cron_exec_line.run_file_of job)

let daily_close_exec = exec_entry ~schedule:"5 21 * * 1-5" ~job:"daily-close"
let rebalance_exec = exec_entry ~schedule:"0 6 * * *" ~job:"rebalance"

(* A line carrying the exec command and a path no writer could have written.
   The name a reader would lift straight out of it is a fragment of somebody
   else's path, so this is a line of neither shape and has to go unnamed. The
   path is the one thing written out here: it is precisely a path the builder
   above cannot produce. *)
let escaping_exec =
  exec_line ~schedule:"0 3 * * *" ~path:"/etc/bondi/cron/../../passwd/run.json"

let legacy_only_section = [ begin_marker; daily_close; end_marker; "" ]
let exec_only_section = [ begin_marker; daily_close_exec; end_marker; "" ]
let mixed_shapes = [ begin_marker; daily_close; rebalance_exec; end_marker; "" ]

let mixed_with_unresolvable =
  [ begin_marker; daily_close; escaping_exec; rebalance_exec; end_marker; "" ]

(* A legacy payload whose [job] field is text no job could have been deployed
   under. The name on a legacy line comes out of JSON the host wrote and nothing
   else on the line constrains it -- unlike the exec shape, where the path is
   rebuilt from the name and the line is named only when the two agree. So this
   is the one shape by which host-controlled text can reach standard output, and
   the path a later reader builds from a reported name. *)
let hostile_legacy = entry ~schedule:"0 4 * * *" ~job:"../../etc/passwd" ~secret

let hostile_legacy_section =
  [ begin_marker; daily_close; hostile_legacy; end_marker; "" ]

(* Two separately balanced sections, which is a state boxes are actually in: an
   earlier reader matched its markers untrimmed, read a section carrying a
   carriage return as absent, and the next write appended a second one below it.
   Both sections' jobs fire, so a report naming only the first describes a box
   that does not exist. *)
let two_sections =
  [
    begin_marker;
    daily_close;
    end_marker;
    hand_added;
    begin_marker;
    rebalance_exec;
    end_marker;
    "";
  ]

(* An expected entry states which shape named it as well as what it named. The
   two are different facts about a job -- an exec-line name has a run file
   beside it and a legacy name has none and never had one -- so a case that
   pinned the name alone would go on passing while a reader that had lost the
   distinction reported every unmigrated job as about to fail. *)
let named_by_exec_line job = Listing.Named { job; shape = Listing.Exec_line }

let named_by_legacy_line job =
  Listing.Named { job; shape = Listing.Legacy_line }

(* Entries are compared as a list rather than one at a time, so a case states
   the whole of what the section reads as: the entries around the one it is
   about are asserted by the same call that asserts it, and a case about an
   entry that must go unnamed cannot pass because nothing else was read. *)
let entry_testable =
  of_pp (fun formatter entry ->
      match entry with
      | Listing.Named { job; shape } ->
          Format.fprintf formatter "Named %S from %s" job
            (match shape with
            | Listing.Exec_line -> "an exec line"
            | Listing.Legacy_line -> "a legacy line")
      | Listing.Unnamed { position } ->
          Format.fprintf formatter "Unnamed %d" position)

let check_entries label expected listing =
  match listing with
  | Listing.Section { entries } ->
      check (list entry_testable) label expected entries
  | Listing.No_section
  | Listing.Malformed _
  | Listing.Unreadable _ ->
      failf "%s: this fixture is a well-formed section and must read as one"
        label

(* The names alone, read out of the one reader that reports them. Every case
   below is about which jobs are named and in what order; the shape each name
   came from is the subject of its own case. *)
let check_named_jobs label expected listing =
  check (list string) label expected
    (List.map
       (fun (named : Listing.named_job) -> named.job)
       (Listing.named_jobs_with_shape listing))

let rendered_named_job (named : Listing.named_job) =
  Printf.sprintf "%s from %s" named.job
    (match named.shape with
    | Listing.Exec_line -> "an exec line"
    | Listing.Legacy_line -> "a legacy line")

let check_named_jobs_with_shape label expected listing =
  check (list string) label expected
    (List.map rendered_named_job (Listing.named_jobs_with_shape listing))

(* --- Tests --- *)

let test_crontab_section_counts_jobs () =
  match Listing.job_count (spool_of well_formed) with
  | Some count -> check int "counts the entries between the markers" 2 count
  | None -> fail "a well-formed section must report how many jobs it holds"

let test_crontab_section_returns_job_names () =
  check_entries "names the jobs in the order the file lists them"
    [ named_by_legacy_line "daily-close"; named_by_legacy_line "rebalance" ]
    (spool_of well_formed)

(* The affirmative arm the absence test below is measured against: a section
   really can hold zero jobs and report the count, so an implementation that
   never reports one does not satisfy the pair by accident. *)
let test_crontab_empty_section_is_zero_jobs () =
  let listing = spool_of empty_section in
  match listing with
  | Listing.Section { entries } ->
      check int "an empty section holds no entries" 0 (List.length entries);
      check (option int) "and still has a count to report" (Some 0)
        (Listing.job_count listing)
  | Listing.No_section ->
      fail "a section present and empty must not be read as no section at all"
  | Listing.Malformed _
  | Listing.Unreadable _ ->
      fail "a section carrying both its markers is well formed"

(* Nothing marked as Bondi's is the state a host is in before its first setup,
   and after one that removed every job. Collapsing it into "zero jobs" states
   that the section is there and empty, which is a claim about a file that may
   not even exist. *)
(* The line the orchestrator writes now holds no payload at all, so the only
   place its job's name can come from is the path it reads. Without this every
   correctly written line reports as unnamed: a false alarm on every job on
   every box, and the exact inverse of the failure the unnamed arm exists for. *)
let test_crontab_exec_line_is_named_from_its_path () =
  check_entries "takes the job's name from the run file's directory"
    [ named_by_exec_line "daily-close" ]
    (spool_of exec_only_section)

(* Every crontab in the estate still holds legacy lines and they still fire, so
   teaching the reader the new shape may not cost it the old one. This is the
   case that goes red if the new reader replaces the old rather than standing
   in front of it. *)
let test_crontab_legacy_line_is_still_named_from_its_payload () =
  check_entries "takes the job's name from the payload the line carries"
    [ named_by_legacy_line "daily-close" ]
    (spool_of legacy_only_section)

(* A box mid-migration holds both shapes at once, because a job's line is
   rewritten by the deploy that names it and by no other. So a section holds the
   new shape for the jobs deployed since and the legacy shape for the rest, and
   a reader that names only one of the two describes a box that does not exist. *)
let test_crontab_mixed_section_names_every_job () =
  check_entries "names both shapes, in the order the file lists them"
    [ named_by_legacy_line "daily-close"; named_by_exec_line "rebalance" ]
    (spool_of mixed_shapes)

(* A line of neither shape keeps its place and reports its position, and the
   named entries on either side of it are asserted by the same call — so this
   cannot pass because nothing reached the reader. The path is one the writer
   could not have produced, which is what re-deriving it from the name is for:
   taken at face value it would name a job "passwd". *)
let test_crontab_line_of_neither_shape_is_unnamed_with_its_position () =
  check_entries "leaves the line of neither shape unnamed, at its position"
    [
      named_by_legacy_line "daily-close";
      Listing.Unnamed { position = 2 };
      named_by_exec_line "rebalance";
    ]
    (spool_of mixed_with_unresolvable)

let test_crontab_no_section_is_not_zero_jobs () =
  let listing = spool_of no_markers in
  match listing with
  | Listing.No_section ->
      check (option int) "no section has no count to report" None
        (Listing.job_count listing)
  | Listing.Section { entries } ->
      failf "a spool with no markers must not be read as a section of %d jobs"
        (List.length entries)
  | Listing.Malformed _
  | Listing.Unreadable _ ->
      fail "a spool with no markers is not a spool with broken ones"

let test_crontab_end_marker_without_begin_is_malformed () =
  match spool_of end_without_begin with
  | Listing.Malformed Listing.End_without_begin -> ()
  | Listing.Malformed Listing.Begin_without_end
  | Listing.Malformed Listing.Nested_begin ->
      fail "an end marker on its own is the defect that must be named"
  | Listing.Section { entries } ->
      failf "an unbalanced marker must not be read as a section of %d jobs"
        (List.length entries)
  | Listing.No_section ->
      fail
        "an end marker on its own is a broken section, not the absence of one"
  | Listing.Unreadable _ ->
      fail "the spool was read; it is its contents that do not make sense"

(* A begin marker inside a section leaves the file with no unambiguous end, and
   a section with no end marker at all leaves every later line inside it. Either
   way a job count over it would state a number nothing on the host agrees
   with. *)
let test_crontab_nested_markers_are_malformed () =
  (match spool_of nested with
  | Listing.Malformed Listing.Nested_begin -> ()
  | Listing.Malformed Listing.End_without_begin
  | Listing.Malformed Listing.Begin_without_end ->
      fail "a begin marker inside a section is the defect that must be named"
  | Listing.Section { entries } ->
      failf "nested markers must not be read as a section of %d jobs"
        (List.length entries)
  | Listing.No_section
  | Listing.Unreadable _ ->
      fail "nested markers are a broken section, not a missing one");
  match spool_of never_ends with
  | Listing.Malformed Listing.Begin_without_end -> ()
  | Listing.Malformed Listing.End_without_begin
  | Listing.Malformed Listing.Nested_begin ->
      fail "a section that never ends is the defect that must be named"
  | Listing.Section { entries } ->
      failf "a section that never ends must not be read as one of %d jobs"
        (List.length entries)
  | Listing.No_section
  | Listing.Unreadable _ ->
      fail "a begin marker with no end is a broken section, not a missing one"

(* Entries an operator added by hand are not Bondi's to report on or to
   converge, and counting them would make the row disagree with what the next
   setup writes. The section here holds the same entry the well-formed fixture
   opens with, so the difference in outcome can only come from the lines outside
   it. *)
let test_crontab_entries_outside_markers_are_not_counted () =
  match
    spool_of
      [ hand_added; begin_marker; daily_close; end_marker; hand_added; "" ]
  with
  | Listing.Section { entries } ->
      check int "reads only what lies between the markers" 1
        (List.length entries)
  | Listing.No_section
  | Listing.Malformed _
  | Listing.Unreadable _ ->
      fail "a well-formed section surrounded by hand-added entries is still one"

(* An entry whose job cannot be read is still an entry. Dropping it would report
   a section of two over a file holding three, and the next setup rewrites the
   section and deletes that third line — so the one report that could have
   warned about the writer would instead have agreed with it.

   Both arms are the same fixture: [rebalance] and [rebalance_truncated] are the
   same line, one of them cut short. Without the affirmative arm, an
   implementation that reported every entry as unreadable would pass. *)
let test_crontab_unreadable_entry_is_counted_and_located () =
  (match spool_of with_truncated_entry with
  | Listing.Section { entries } -> (
      check (option int) "an entry that could not be read is still counted"
        (Some 2)
        (Listing.job_count (spool_of with_truncated_entry));
      match entries with
      | [
       Listing.Named { job = "daily-close"; shape = _ };
       Listing.Unnamed { position };
      ] ->
          check int "says which entry it was, so the operator can find it" 2
            position
      | [ Listing.Named _; Listing.Named { job = name; shape = _ } ] ->
          failf "an entry whose payload does not parse must not be named %S"
            name
      | [ _; _ ]
      | []
      | [ _ ]
      | _ :: _ :: _ :: _ ->
          failf
            "expected the named entry and the unreadable one, got %d entries"
            (List.length entries))
  | Listing.No_section
  | Listing.Malformed _
  | Listing.Unreadable _ ->
      fail "an entry that does not parse does not break the section around it");
  match spool_of well_formed with
  | Listing.Section { entries } -> (
      match entries with
      | [ Listing.Named _; Listing.Named { job = "rebalance"; shape = _ } ] ->
          ()
      | [ Listing.Named _; Listing.Unnamed { position } ] ->
          failf "the same entry, intact, must be read as named, not as entry %d"
            position
      | [ _; _ ]
      | []
      | [ _ ]
      | _ :: _ :: _ :: _ ->
          failf "expected two named entries, got %d" (List.length entries))
  | Listing.No_section
  | Listing.Malformed _
  | Listing.Unreadable _ ->
      fail "a well-formed section must be read as one"

(* The read never happened, which is a fact about the spool file's readability
   and not about what it holds. Reading it as "no section" would tell an
   operator their cron jobs are gone on the strength of a permission error. *)
let test_crontab_unreadable_spool_is_not_no_section () =
  let listing =
    Listing.of_read_output
      (Error
         (Remote_exec.Command_failed
            {
              code = 1;
              output = "cat: /var/spool/cron/crontabs/root: Permission denied";
            }))
  in
  match listing with
  | Listing.Unreadable message ->
      check bool "carries what went wrong" true
        (contains ~needle:"Permission denied" message);
      check (option int) "a read that never happened has no count" None
        (Listing.job_count listing)
  | Listing.No_section ->
      fail
        "a spool that could not be read must not be reported as having no \
         section"
  | Listing.Section _
  | Listing.Malformed _ ->
      fail "a read that never happened tells us nothing about the file"

(* The spool file carries several strategies' API secrets in plaintext inside
   the payloads of its curl lines, so anything this module returns lands in
   stdout, in scrollback, and in every transcript of the run. Counts, names and
   positions are the whole permitted output, and that has to hold on the failure
   paths too: a malformed result quoting the offending line, or an unreadable
   entry helpfully carrying what could not be read, is the leak this test exists
   to catch.

   Every string a result can carry is enumerated rather than sampled, so a
   constructor that later gains a payload stops compiling here and has to be
   given an answer deliberately. *)
let strings_returned listing =
  match listing with
  | Listing.Section { entries } ->
      List.concat_map
        (fun entry ->
          match entry with
          | Listing.Named { job; shape = _ } -> [ job ]
          | Listing.Unnamed { position = _ } -> [])
        entries
  | Listing.No_section -> []
  | Listing.Malformed defect -> (
      match defect with
      | Listing.End_without_begin
      | Listing.Begin_without_end
      | Listing.Nested_begin ->
          [])
  | Listing.Unreadable message -> [ message ]

(* The hole the type alone does not close. [Unreadable] carries a string, and
   the string it is handed is the transport's own error — which is the merged
   output of a command that had already begun streaming the spool file when the
   session died. A payload assembled that way carries the file, so the module's
   guarantee has to hold against the failure path as well as the successful
   one, and only redaction at the boundary makes it.

   The marker is what makes the redaction provable rather than a filter: the
   command prints it before the first byte of the file, so everything from it
   onwards is content and everything before it is not. *)
let test_crontab_transport_error_never_carries_the_spool_it_streamed () =
  let listing =
    Listing.of_read_output
      (Error
         (Remote_exec.Ssh_failed
            {
              code = 255;
              output =
                Printf.sprintf "%s\n%s\n%s\n%s" contents_marker begin_marker
                  daily_close rebalance;
            }))
  in
  match listing with
  | Listing.Unreadable message ->
      check bool "the secret in the streamed payload is not reported" false
        (contains ~needle:secret message);
      check bool "nor the command line carrying it" false
        (contains ~needle:"curl" message);
      check bool "nor the payload it was inside" false
        (contains ~needle:"env_vars" message);
      check bool "and what did go wrong is still said" true
        (contains ~needle:"255" message)
  | Listing.No_section
  | Listing.Section _
  | Listing.Malformed _ ->
      fail "a read that failed part-way through must still be unreadable"

(* The other half of the pair: an error carrying no content is passed through
   whole, so redaction costs nothing on the paths where there is nothing to
   redact. Without this arm, discarding every message would satisfy the test
   above. *)
let test_crontab_transport_error_without_contents_is_kept_whole () =
  match
    Listing.of_read_output
      (Error
         (Remote_exec.Ssh_failed { code = 255; output = "Connection closed" }))
  with
  | Listing.Unreadable message ->
      check bool "an error that streamed nothing keeps its detail" true
        (contains ~needle:"Connection closed" message)
  | Listing.No_section
  | Listing.Section _
  | Listing.Malformed _ ->
      fail "a transport failure is a failed read"

(* The spool file lives under a directory only root may traverse, and the
   orchestrator writes it as root, so the reading user is routinely one that
   cannot stat it. A guard that answers the same way for "not there" and "may
   not look" reports a host whose jobs are all present as a host with no
   section — the exact conflation this feature exists to remove, and the reason
   the command says which on standard output instead of leaving it to an exit
   status. *)
let test_crontab_read_command_asks_with_privilege_and_says_which () =
  let command = Listing.read_command in
  check bool "reads the spool with the privilege the writer used" true
    (contains ~needle:"sudo" command);
  check bool "never blocks on a password prompt" true
    (contains ~needle:"-n" command);
  check bool "says when the file is not there" true
    (contains ~needle:absent_marker command);
  check bool "says when it is there and could not be read" true
    (contains ~needle:unreadable_marker command);
  check bool "marks where the file's own contents begin" true
    (contains ~needle:contents_marker command);
  check bool "and always exits 0, so the marker survives the ssh layer" true
    (contains ~needle:"exit 0" command)

(* The two answers the guard now separates, read back. A file that is not there
   is a fact about the host's jobs; a file that could not be read is a fact
   about the read, and only one of them may be reported as having no section. *)
let test_crontab_absent_and_denied_are_different_outcomes () =
  (match Listing.of_read_output (Ok (absent_marker ^ "\n")) with
  | Listing.No_section -> ()
  | Listing.Unreadable message ->
      failf "a spool file that is not there is not a failed read: %s" message
  | Listing.Section _
  | Listing.Malformed _ ->
      fail "a host with no crontab has no section");
  match Listing.of_read_output (Ok (unreadable_marker ^ "\n")) with
  | Listing.Unreadable _ -> ()
  | Listing.No_section ->
      fail
        "a spool file that could not be read must not be reported as having no \
         section"
  | Listing.Section _
  | Listing.Malformed _ ->
      fail "a read that never happened tells us nothing about the file"

(* Output carrying no marker at all is a command that answered without saying
   which, and that is a read that did not happen rather than a host with no
   jobs. *)
let test_crontab_output_without_a_marker_is_unreadable () =
  match
    Listing.of_read_output
      (Ok "Warning: Permanently added '10.0.0.1' to known hosts.\n")
  with
  | Listing.Unreadable _ -> ()
  | Listing.No_section
  | Listing.Section _
  | Listing.Malformed _ ->
      fail "output carrying no marker must be a rejection"

let test_crontab_never_returns_command_lines () =
  let spools =
    [
      ("a well-formed section", well_formed);
      ("a section holding an entry that does not parse", with_truncated_entry);
      ("no section at all", no_markers);
      ("an unbalanced end marker", end_without_begin);
      ("a section that never ends", never_ends);
      ("nested markers", nested);
      ("a section mixing both shapes", mixed_with_unresolvable);
    ]
  in
  List.iter
    (fun (label, lines) ->
      let returned = String.concat " " (strings_returned (spool_of lines)) in
      check bool
        (label ^ " returns no secret from a payload")
        false
        (contains ~needle:secret returned);
      check bool
        (label ^ " returns no command it read")
        false
        (contains ~needle:"curl" returned);
      check bool
        (label ^ " returns no payload it parsed")
        false
        (contains ~needle:"env_vars" returned))
    spools

(* [named_jobs] is what the preserve action and the operator report are built
   from, and until now it was reached only through a plan test asserting on the
   order of actions. The names it returns are the section's, in the order its
   lines appear. *)
let test_named_jobs_names_the_section_in_order () =
  check_named_jobs "names the section's jobs in file order"
    [ "daily-close"; "rebalance" ]
    (spool_of well_formed);
  check_named_jobs "and does so across both line shapes"
    [ "daily-close"; "rebalance" ]
    (spool_of mixed_shapes)

(* An entry whose job could not be read is a line for a human to go and look at
   and not a job another reader can act on, so it is not one of the names. The
   affirmative arm is the same fixture's other two entries: without them, a
   [named_jobs] returning nothing at all would satisfy the absence. *)
let test_named_jobs_omits_an_entry_that_could_not_be_read () =
  let listing = spool_of mixed_with_unresolvable in
  check (option int) "the unreadable entry is still counted" (Some 3)
    (Listing.job_count listing);
  check_named_jobs "but it is not one of the names it reports"
    [ "daily-close"; "rebalance" ]
    listing

(* Every section is the section. A file holding a second, separately balanced
   one holds jobs that fire, and the next write folds the two together -- so a
   report that named only the first would disagree with both the box and the
   rewrite. The hand-added line between them is outside both, and stays out. *)
let test_named_jobs_covers_every_section_in_the_file () =
  check_named_jobs "names the jobs of both sections, in file order"
    [ "daily-close"; "rebalance" ]
    (spool_of two_sections)

(* A name read off a legacy line is a JSON field the host wrote, and it leaves
   here for standard output and for whatever path a caller builds from it. One
   [create] would have rejected cannot have come from a job Bondi deployed, so
   it is not reported at all. The line remains an entry: it is on the box and
   the next rewrite removes it, which is a fact the count still carries.
   The affirmative arm is the same builder with a name a job could carry. *)
let test_named_jobs_drops_a_legacy_name_no_job_could_carry () =
  let listing = spool_of hostile_legacy_section in
  check (option int) "the line is still an entry of the section" (Some 2)
    (Listing.job_count listing);
  check_named_jobs
    "a name no job could have been deployed under is not reported"
    [ "daily-close" ] listing;
  check_named_jobs "while the same line carrying a name one could is"
    [ "daily-close"; "rebalance" ]
    (spool_of well_formed)

(* Nothing on the host supports a claim about what is scheduled there unless a
   section was read, so every other outcome names nothing. Each absence arm is
   paired with the same lines read as a section: without the pair, a
   [named_jobs] that always answered [[]] would pass all four. *)
let test_named_jobs_is_empty_for_every_outcome_that_is_not_a_section () =
  check_named_jobs "a file carrying no markers names nothing" []
    (spool_of no_markers);
  check_named_jobs "though the same line inside markers is named"
    [ "operator-cleanup" ]
    (spool_of [ begin_marker; hand_added; end_marker; "" ]);
  check_named_jobs "an end marker without a begin names nothing" []
    (spool_of end_without_begin);
  check_named_jobs "though the same lines with both markers are named"
    [ "daily-close" ]
    (spool_of [ begin_marker; daily_close; end_marker; "" ]);
  check_named_jobs "a section that never ends names nothing" []
    (spool_of never_ends);
  check_named_jobs "nested markers name nothing" [] (spool_of nested);
  check_named_jobs "a read that never happened names nothing" []
    (Listing.of_read_output
       (Error
          (Remote_exec.Ssh_failed { code = 255; output = "Connection closed" })));
  check_named_jobs "though the same section read successfully is named"
    [ "daily-close"; "rebalance" ]
    (spool_of well_formed)

(* The shape that named a job, out where the caller reporting on its files can
   read it. A legacy line has no run file and no environment file by definition
   -- its payload is on the line -- so a report built from names alone tells the
   operator that every unmigrated job on the box fails at its next fire, which
   is the common case on the boxes this reads and the false alarm they would
   act on. The fixture holds one job of each shape, so a reader that answered
   the same shape for both cannot pass. *)
let test_named_jobs_carry_the_shape_that_named_them () =
  check_named_jobs_with_shape "says which shape named each job"
    [ "daily-close from a legacy line"; "rebalance from an exec line" ]
    (spool_of mixed_shapes);
  check_named_jobs_with_shape "and names nothing where nothing was read" []
    (spool_of no_markers)

let () =
  run "Crontab_listing"
    [
      ( "section",
        [
          test_case "counts the jobs it holds" `Quick
            test_crontab_section_counts_jobs;
          test_case "names the jobs it holds" `Quick
            test_crontab_section_returns_job_names;
          test_case "a section present and empty holds zero jobs" `Quick
            test_crontab_empty_section_is_zero_jobs;
          test_case "entries outside the markers are not Bondi's" `Quick
            test_crontab_entries_outside_markers_are_not_counted;
          test_case "an entry that could not be read is counted and located"
            `Quick test_crontab_unreadable_entry_is_counted_and_located;
          test_case "an exec line is named from its path" `Quick
            test_crontab_exec_line_is_named_from_its_path;
          test_case "a legacy line is still named from its payload" `Quick
            test_crontab_legacy_line_is_still_named_from_its_payload;
          test_case "a section mixing both shapes names every job" `Quick
            test_crontab_mixed_section_names_every_job;
          test_case "a line of neither shape is still unnamed with its position"
            `Quick
            test_crontab_line_of_neither_shape_is_unnamed_with_its_position;
        ] );
      ( "named jobs",
        [
          test_case "names the section's jobs in order" `Quick
            test_named_jobs_names_the_section_in_order;
          test_case "an entry that could not be read is not a name" `Quick
            test_named_jobs_omits_an_entry_that_could_not_be_read;
          test_case "every section in the file is covered" `Quick
            test_named_jobs_covers_every_section_in_the_file;
          test_case "a legacy name no job could carry is dropped" `Quick
            test_named_jobs_drops_a_legacy_name_no_job_could_carry;
          test_case "every outcome that is not a section names nothing" `Quick
            test_named_jobs_is_empty_for_every_outcome_that_is_not_a_section;
          test_case "each name carries the shape it was read from" `Quick
            test_named_jobs_carry_the_shape_that_named_them;
        ] );
      ( "absence and failure",
        [
          test_case "no section is not a section of zero jobs" `Quick
            test_crontab_no_section_is_not_zero_jobs;
          test_case "an end marker without a begin is malformed" `Quick
            test_crontab_end_marker_without_begin_is_malformed;
          test_case "nested and unclosed markers are malformed" `Quick
            test_crontab_nested_markers_are_malformed;
          test_case "a spool that could not be read is not a missing section"
            `Quick test_crontab_unreadable_spool_is_not_no_section;
          test_case "the read asks with privilege and says which" `Quick
            test_crontab_read_command_asks_with_privilege_and_says_which;
          test_case "absent and denied are different outcomes" `Quick
            test_crontab_absent_and_denied_are_different_outcomes;
          test_case "output carrying no marker is unreadable" `Quick
            test_crontab_output_without_a_marker_is_unreadable;
        ] );
      ( "secrets",
        [
          test_case "no result ever carries a command line" `Quick
            test_crontab_never_returns_command_lines;
          test_case "a transport error never carries the spool it streamed"
            `Quick
            test_crontab_transport_error_never_carries_the_spool_it_streamed;
          test_case "an error carrying no contents keeps its detail" `Quick
            test_crontab_transport_error_without_contents_is_kept_whole;
        ] );
    ]
