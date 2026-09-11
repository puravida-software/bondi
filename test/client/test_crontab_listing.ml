open Alcotest
module Listing = Bondi_client.Crontab_listing
module Remote_exec = Bondi_client.Remote_exec

let contains = Test_helpers.contains

(* --- Fixtures ---

   Every fixture below is a spool file, and two kinds of line appear in them.
   The shape the orchestrator writes, and the only one this reader understands,
   is built by [exec_entry] further down. The shape it wrote before that one is
   built by [entry] just below: a curl invocation carrying its whole job
   description inside the payload of a -d argument. Nothing writes that shape
   any more and this reader cannot name it, but a crontab is a file anything may
   write and the payload is where the secrets live — so the fixtures carry a
   realistic one rather than a sanitised placeholder, because a sanitised entry
   cannot catch a parser that hands the payload back.

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
let begin_marker = "# BEGIN BONDI CRON"
let end_marker = "# END BONDI CRON"

(* What the read command prints, as it prints it. The contents marker comes
   first and the file follows it, which is the property the redaction below
   rests on: nothing the file holds can appear ahead of the marker.

   The end marker is printed after the last byte of the file, and it is what
   makes a complete read a thing the reader is told rather than a thing it
   infers. Every fixture built through [spool_of] is a read that finished, so a
   case about a read that did not finish has to say so by leaving it off. *)
let contents_marker = "BONDI_CRONTAB_CONTENTS"
let end_of_contents_marker = "BONDI_CRONTAB_END"
let absent_marker = "BONDI_CRONTAB_ABSENT"
let unreadable_marker = "BONDI_CRONTAB_UNREADABLE"

let spool_of lines =
  Listing.of_read_output
    (Ok
       (String.concat "\n"
          ((contents_marker :: lines) @ [ end_of_contents_marker ])))

let empty_section = [ begin_marker; end_marker; "" ]

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

(* A line an operator added by hand, outside anything Bondi wrote. It is a line
   the reader can name, which is what makes the pair it appears in about the
   markers: the same line names its job inside them and nothing outside them, so
   an outcome that differed could only have come from where it sat. *)
let hand_added = exec_entry ~schedule:"*/5 * * * *" ~job:"operator-cleanup"

(* The same line as [rebalance_exec], cut where a partial write or a hand-edit
   would leave it: the path is still there and its quoting no longer closes. Its
   twin above is what makes the pair meaningful — the two differ only in the
   three characters that end it. *)
let rebalance_exec_truncated =
  String.sub rebalance_exec 0 (String.length rebalance_exec - 3)

(* A line carrying the exec command and a path no writer could have written.
   The name a reader would lift straight out of it is a fragment of somebody
   else's path, so this is a line of neither shape and has to go unnamed. The
   path is the one thing written out here: it is precisely a path the builder
   above cannot produce. *)
let escaping_exec =
  exec_line ~schedule:"0 3 * * *" ~path:"/etc/bondi/cron/../../passwd/run.json"

let well_formed =
  [ begin_marker; daily_close_exec; rebalance_exec; end_marker; "" ]

let with_truncated_entry =
  [ begin_marker; daily_close_exec; rebalance_exec_truncated; end_marker; "" ]

let no_markers = [ hand_added; "" ]
let end_without_begin = [ daily_close_exec; end_marker; "" ]
let never_ends = [ begin_marker; daily_close_exec; "" ]

let nested =
  [
    begin_marker; daily_close_exec; begin_marker; rebalance_exec; end_marker; "";
  ]

(* A section of nothing but the shape that is no longer written. Every line in
   it carries a secret and none of them can be named, which is the pair this
   fixture exists for: the entries are counted and located, and nothing they
   hold leaves. *)
let legacy_only_section =
  [ begin_marker; daily_close; rebalance; end_marker; "" ]

let exec_only_section = [ begin_marker; daily_close_exec; end_marker; "" ]
let mixed_shapes = [ begin_marker; daily_close; rebalance_exec; end_marker; "" ]

let mixed_with_unresolvable =
  [
    begin_marker;
    daily_close_exec;
    escaping_exec;
    rebalance_exec;
    end_marker;
    "";
  ]

(* Two separately balanced sections, which is a state boxes are actually in: an
   earlier reader matched its markers untrimmed, read a section carrying a
   carriage return as absent, and the next write appended a second one below it.
   Both sections' jobs fire, so a report naming only the first describes a box
   that does not exist. *)
let two_sections =
  [
    begin_marker;
    daily_close_exec;
    end_marker;
    hand_added;
    begin_marker;
    rebalance_exec;
    end_marker;
    "";
  ]

(* Entries are compared as a list rather than one at a time, so a case states
   the whole of what the section reads as: the entries around the one it is
   about are asserted by the same call that asserts it, and a case about an
   entry that must go unnamed cannot pass because nothing else was read. *)
let entry_testable =
  of_pp (fun formatter entry ->
      match entry with
      | Listing.Named job -> Format.fprintf formatter "Named %S" job
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
   below is about which jobs are named, in what order, and whether there was a
   section read to name them at all. *)
let check_jobs_read label expected listing =
  check (option (list string)) label expected (Listing.jobs_read listing)

(* Every string a listing can hand back, gathered in one place so a rule about
   what may leave the module is asserted against the whole of its surface rather
   than against the one constructor a case happened to think of. The match is
   exhaustive on purpose: a constructor added later that carries a string cannot
   be added without deciding, here, whether it is one of these. *)
let strings_returned listing =
  match listing with
  | Listing.Section { entries } ->
      List.concat_map
        (fun entry ->
          match entry with
          | Listing.Named job -> [ job ]
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

(* --- Tests --- *)

let test_crontab_section_counts_jobs () =
  match Listing.job_count (spool_of well_formed) with
  | Some count -> check int "counts the entries between the markers" 2 count
  | None -> fail "a well-formed section must report how many jobs it holds"

let test_crontab_section_returns_job_names () =
  check_entries "names the jobs in the order the file lists them"
    [ Listing.Named "daily-close"; Listing.Named "rebalance" ]
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
    [ Listing.Named "daily-close" ]
    (spool_of exec_only_section)

(* The shape nothing writes any more still sits in crontabs written before it
   went, and it still fires. This reader cannot name it: the job is inside the
   payload rather than in a path, and reading it back out would be the one route
   by which a line's own text reaches an operator. So each such line is an entry
   at its position, counted and never rendered -- and never dropped, because the
   next setup rewrites the section and removes exactly these lines, so a section
   reported as empty would agree with the rewrite instead of warning about it.

   The affirmative arm is [exec_only_section]: a reader that named nothing at
   all would satisfy the absence on its own. *)
let test_crontab_line_of_the_old_shape_is_counted_and_unnamed () =
  let listing = spool_of legacy_only_section in
  check (option int) "every line of the section is still an entry" (Some 2)
    (Listing.job_count listing);
  check_entries "and each one is located rather than named"
    [ Listing.Unnamed { position = 1 }; Listing.Unnamed { position = 2 } ]
    listing;
  check_entries "while a line of the shape it reads is named"
    [ Listing.Named "daily-close" ]
    (spool_of exec_only_section)

(* A box holds whatever its crontab was last written with, so a section can
   carry a line this reads beside one it cannot. Both are entries and only one
   is a name, and asserting the pair in a single call is what stops a reader
   that dropped the unnameable line from passing on the strength of the other. *)
let test_crontab_mixed_section_names_only_what_it_reads () =
  check_entries "names what it can and locates what it cannot"
    [ Listing.Unnamed { position = 1 }; Listing.Named "rebalance" ]
    (spool_of mixed_shapes)

(* A line of neither shape keeps its place and reports its position, and the
   named entries on either side of it are asserted by the same call — so this
   cannot pass because nothing reached the reader. The path is one the writer
   could not have produced, which is what re-deriving it from the name is for:
   taken at face value it would name a job "passwd". *)
let test_crontab_line_of_neither_shape_is_unnamed_with_its_position () =
  check_entries "leaves the line of neither shape unnamed, at its position"
    [
      Listing.Named "daily-close";
      Listing.Unnamed { position = 2 };
      Listing.Named "rebalance";
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
      [ hand_added; begin_marker; daily_close_exec; end_marker; hand_added; "" ]
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

   Both arms are the same fixture: [rebalance_exec] and
   [rebalance_exec_truncated] are the same line, one of them cut short. Without the affirmative arm, an
   implementation that reported every entry as unreadable would pass. *)
let test_crontab_unreadable_entry_is_counted_and_located () =
  (match spool_of with_truncated_entry with
  | Listing.Section { entries } -> (
      check (option int) "an entry that could not be read is still counted"
        (Some 2)
        (Listing.job_count (spool_of with_truncated_entry));
      match entries with
      | [ Listing.Named "daily-close"; Listing.Unnamed { position } ] ->
          check int "says which entry it was, so the operator can find it" 2
            position
      | [ Listing.Named _; Listing.Named name ] ->
          failf "an entry whose line does not parse must not be named %S" name
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
      | [ Listing.Named _; Listing.Named "rebalance" ] -> ()
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

(* The hole the type alone does not close. [Unreadable] carries a string, and
   the string it is handed is the transport's own error -- which is the merged
   output of a command that had already begun streaming the spool file when the
   session died. A crontab is a file anything may write, and the legacy shape
   below carries a job's whole payload, secrets included, on the line itself. So
   a failed read's message can hold the file, and the module's guarantee has to
   hold on the failure path as well as the successful one.

   The marker is what makes the cut provable rather than a filter: the command
   prints it before the first byte of the file, so everything from it onwards is
   content and everything before it is not. A filter deciding line by line what
   looks like a secret is a filter that is one day wrong. *)
let test_crontab_transport_error_never_carries_the_spool_it_streamed () =
  let listing =
    Listing.of_read_output
      (Error
         (Remote_exec.Ssh_failed
            {
              code = 255;
              output =
                String.concat "\n"
                  [ contents_marker; begin_marker; daily_close; rebalance ];
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
   whole, so the cut costs nothing on the paths where there is nothing to cut.
   Without this arm, discarding every message would satisfy the test above --
   and the transport's own account of the failure is the operator's only pointer
   to where to go and look. *)
let test_crontab_transport_error_without_contents_is_kept_whole () =
  match
    Listing.of_read_output
      (Error
         (Remote_exec.Ssh_failed { code = 255; output = "Connection closed" }))
  with
  | Listing.Unreadable message ->
      check bool "an error that streamed nothing keeps its detail" true
        (contains ~needle:"Connection closed" message);
      check bool "and still says what went wrong" true
        (contains ~needle:"255" message)
  | Listing.No_section
  | Listing.Section _
  | Listing.Malformed _ ->
      fail "a transport failure is a failed read"

(* The rule stated over the whole surface rather than one constructor at a time.
   Whatever the file held and however it was malformed, what leaves this module
   is a count, a job's name or a position -- never a line it read. The legacy
   fixtures are the ones that make the sweep worth running: their payloads carry
   a realistic secret, so a parser that handed a line back would be caught by
   the value it returned rather than by inspection. *)
let test_crontab_never_returns_command_lines () =
  let spools =
    [
      ("a well-formed section", well_formed);
      ("a section holding an entry that does not parse", with_truncated_entry);
      ("no section at all", no_markers);
      ("an unbalanced end marker", end_without_begin);
      ("a section that never ends", never_ends);
      ("nested markers", nested);
      ("a section of nothing but the old shape", legacy_only_section);
      ("a section mixing both shapes", mixed_shapes);
      ( "a section mixing both shapes and one of neither",
        mixed_with_unresolvable );
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

(* The file goes onto standard output as it is read rather than into a shell
   variable first. The capture was there so that a failure part-way through
   printed no fragment of the file; the file holds no fragment worth
   withholding, and the capture costs the whole spool held in the shell's
   memory before a byte of it is printed.

   The marker still comes first, because it is the only thing separating the
   command's own words from the file's. Streaming without moving the marker
   ahead of the read would put the file's first line before the announcement of
   it, so the two checks below are one requirement and not two. *)
let test_crontab_read_command_streams_the_file () =
  let command = Listing.read_command in
  check bool "captures nothing into a shell variable" false
    (contains ~needle:"$(" command);
  match
    ( Bondi_common.String_utils.index_of ~needle:contents_marker command,
      Bondi_common.String_utils.index_of ~needle:"cat" command )
  with
  | Some marker_at, Some read_at ->
      check bool "and announces the contents ahead of reading them" true
        (marker_at < read_at)
  | None, Some _
  | None, None ->
      fail "the command must say where the file's contents begin"
  | Some _, None -> fail "the command must read the file"

(* [jobs_read] is what the preserve action and the operator report are built
   from, and until now it was reached only through a plan test asserting on the
   order of actions. The names it returns are the section's, in the order its
   lines appear. *)
let test_jobs_read_names_the_section_in_order () =
  check_jobs_read "names the section's jobs in file order"
    (Some [ "daily-close"; "rebalance" ])
    (spool_of well_formed);
  check_jobs_read "and reports only the entries it could read"
    (Some [ "rebalance" ]) (spool_of mixed_shapes)

(* An entry whose job could not be read is a line for a human to go and look at
   and not a job another reader can act on, so it is not one of the names. The
   affirmative arm is the same fixture's other two entries: without them, a
   [jobs_read] returning nothing at all would satisfy the absence. *)
let test_jobs_read_omits_an_entry_that_could_not_be_read () =
  let listing = spool_of mixed_with_unresolvable in
  check (option int) "the unreadable entry is still counted" (Some 3)
    (Listing.job_count listing);
  check_jobs_read "but it is not one of the names it reports"
    (Some [ "daily-close"; "rebalance" ])
    listing

(* Every section is the section. A file holding a second, separately balanced
   one holds jobs that fire, and the next write folds the two together -- so a
   report that named only the first would disagree with both the box and the
   rewrite. The hand-added line between them is outside both, and stays out. *)
let test_jobs_read_covers_every_section_in_the_file () =
  check_jobs_read "names the jobs of both sections, in file order"
    (Some [ "daily-close"; "rebalance" ])
    (spool_of two_sections)

(* A file the host read that carries no Bondi section names nothing, and it is
   still an answer: no line on that box fires any of Bondi's jobs. Markers that
   do not balance and a read that never delivered are not answers, and the
   caller that compares this against the host's payload directory acts on the
   difference -- told apart by nothing, a host whose crontab could not be read
   would have every job in that directory reported as having no line firing it.

   Each arm is paired with the same lines read as a section, because a
   [jobs_read] that always answered the same thing would otherwise pass. *)
let test_jobs_read_separates_an_answer_from_a_read_that_did_not_happen () =
  check_jobs_read "a file carrying no markers is an answer that names nothing"
    (Some []) (spool_of no_markers);
  check_jobs_read "though the same line inside markers is named"
    (Some [ "operator-cleanup" ])
    (spool_of [ begin_marker; hand_added; end_marker; "" ]);
  check_jobs_read "an end marker without a begin is not an answer" None
    (spool_of end_without_begin);
  check_jobs_read "though the same lines with both markers are named"
    (Some [ "daily-close" ])
    (spool_of [ begin_marker; daily_close_exec; end_marker; "" ]);
  check_jobs_read "a section that never ends is not an answer" None
    (spool_of never_ends);
  check_jobs_read "nested markers are not an answer" None (spool_of nested);
  check_jobs_read "a read that never happened is not an answer" None
    (Listing.of_read_output
       (Error
          (Remote_exec.Ssh_failed { code = 255; output = "Connection closed" })));
  check_jobs_read "though the same section read successfully is named"
    (Some [ "daily-close"; "rebalance" ])
    (spool_of well_formed)

(* The read says where the file's contents end as well as where they begin. The
   guard only asks whether the file could be opened, and a [cat] that dies after
   it has answered still leaves the command exiting 0 -- so without a word after
   the last byte, a read that stopped part-way through is a read that finished,
   and the difference is invisible in the output. *)
let test_crontab_read_command_marks_where_the_contents_end () =
  let command = Listing.read_command in
  check bool "says where the file's contents end" true
    (contains ~needle:end_of_contents_marker command);
  match
    ( Bondi_common.String_utils.index_of ~needle:"cat" command,
      Bondi_common.String_utils.index_of ~needle:end_of_contents_marker command
    )
  with
  | Some read_at, Some marker_at ->
      check bool "and says it only once the file has been read" true
        (read_at < marker_at);
      (* Printed as a statement of its own, joined by [;], the marker ran
         whatever the read did and said the file had ended whether it had or
         not. Joined to the read, it is the read's own success that prints it. *)
      check bool "and only when the read succeeded" true
        (contains ~needle:"&&"
           (String.sub command read_at (marker_at - read_at)))
  | Some _, None -> fail "the command must say where the file's contents end"
  | None, Some _
  | None, None ->
      fail "the command must read the file"

(* What the end marker is for. A read that stopped part-way through is a read
   that did not happen, and the two shapes of truncation below are the two ways
   it was previously reported as one that did.

   Cut before the section, the output is a file with no Bondi markers, which
   [jobs_read] answers as "this host fires nothing" -- and a caller comparing
   that against the payload directory reports every job on the box as having
   lost its line. Cut after a section that happens to close, the output is a
   section holding whatever the read got to, so the jobs below the cut are
   reported as orphaned files. The second is worse in kind and not in degree: it
   is a disagreement invented out of a read that never finished.

   Each arm is paired with the same lines read to the end, because a
   [of_read_output] that answered [None] for everything would otherwise pass. *)
let test_crontab_truncated_read_is_not_a_host_with_no_jobs () =
  let cut_before_the_section =
    String.concat "\n" [ contents_marker; "# m h  dom mon dow   command" ]
  in
  check_jobs_read "a read cut before the section is not a host firing nothing"
    None
    (Listing.of_read_output (Ok cut_before_the_section));
  check_jobs_read "though the same file read to the end is that answer"
    (Some [])
    (spool_of [ "# m h  dom mon dow   command"; "" ]);
  let cut_after_a_section_that_closed =
    String.concat "\n"
      [ contents_marker; begin_marker; daily_close_exec; end_marker ]
  in
  check_jobs_read "a read cut after a section that closed is not that section"
    None
    (Listing.of_read_output (Ok cut_after_a_section_that_closed));
  check_jobs_read "though the same lines read to the end are"
    (Some [ "daily-close" ])
    (spool_of [ begin_marker; daily_close_exec; end_marker; "" ])

(* The other half of the pair above, read through the outcome rather than
   through [jobs_read]: a truncated read is [Unreadable] and not [No_section],
   so it counts nothing and says why. Without this, answering [Malformed] for
   every truncation would satisfy the [None]s above while telling an operator to
   go and fix markers that are not broken. *)
let test_crontab_truncated_read_says_the_read_did_not_finish () =
  let listing =
    Listing.of_read_output
      (Ok (String.concat "\n" [ contents_marker; begin_marker ]))
  in
  match listing with
  | Listing.Unreadable message ->
      check bool "says the read is what did not finish" true
        (contains ~needle:"read" message);
      check (option int) "and counts nothing" None (Listing.job_count listing)
  | Listing.No_section ->
      fail "a read that stopped part-way through is not a host with no section"
  | Listing.Section _ ->
      fail "a read that stopped part-way through is not a section"
  | Listing.Malformed _ ->
      fail "a read that stopped part-way through is not a broken marker"

(* The failure the closing marker was added for and did not close. The guard
   only asks whether the file can be opened; a [cat] that then refuses -- a
   sudoers rule permitting [test] and not [cat], or a read that dies on its
   first byte -- used to leave the marker printed all the same, because it was
   a statement of its own joined by [;] and ran whatever the read did.

   What arrives here in that case is the announcement of contents and no
   contents. That is not a host whose crontab is empty and it is not a host
   with no section: it is a read that delivered nothing, and answering [Some []]
   reports every job in the payload directory as having lost its line. *)
let test_crontab_read_that_delivered_nothing_is_not_an_empty_crontab () =
  let listing = Listing.of_read_output (Ok (contents_marker ^ "\n")) in
  check_jobs_read "a read that delivered no contents names no jobs" None listing;
  match listing with
  | Listing.Unreadable message ->
      check bool "and says the read is what did not finish" true
        (contains ~needle:"read" message)
  | Listing.No_section ->
      fail
        "contents announced and never delivered is not a host with no section"
  | Listing.Section _ -> fail "no contents were delivered to make a section of"
  | Listing.Malformed _ -> fail "no contents were delivered to hold a marker"

(* The other side of the same boundary, and the reason the case above cannot be
   read off the absence of file bytes alone. A spool the host read and found
   empty prints the contents marker and then the closing one with nothing
   between, because there was nothing between -- and that is an answer: the
   file is there, it was read whole, and no line on the box fires anything of
   Bondi's. It separates from the case above by the closing marker, which the
   read now prints only when it succeeded. *)
let test_crontab_empty_spool_is_a_file_read_whole () =
  let listing = spool_of [] in
  check_jobs_read "an empty spool read whole is a host that fires nothing"
    (Some []) listing;
  match listing with
  | Listing.No_section -> ()
  | Listing.Unreadable message ->
      failf "an empty file read to its end is not a failed read: %s" message
  | Listing.Section _ -> fail "an empty file carries no section"
  | Listing.Malformed _ -> fail "an empty file carries no marker to break"

(* A crontab is a file anything may write, and what it may write includes the
   word this command prints after the file's last byte. Looked for as a bare
   suffix, that word is indistinguishable from the tail of the last line a
   dying read managed to deliver -- so a read cut on a line ending in it passed
   as a read that finished, and the cut that removed the marker took the end of
   that line with it.

   The marker is its own line or it is not the marker. Matching it with the
   newline ahead of it is what makes the file's own bytes unable to forge it,
   and the pair below is the difference: the same lines cut at that word are a
   read that did not finish, and read to their end are the section they hold. *)
let marker_word_in_a_comment = "# " ^ end_of_contents_marker

let test_crontab_spool_line_ending_in_the_marker_word_is_not_the_marker () =
  let cut_on_a_line_carrying_the_word =
    String.concat "\n"
      [
        contents_marker;
        begin_marker;
        daily_close_exec;
        end_marker;
        marker_word_in_a_comment;
      ]
  in
  check_jobs_read "a line ending in the marker word does not close the read"
    None
    (Listing.of_read_output (Ok cut_on_a_line_carrying_the_word));
  check_jobs_read "though the same lines read to the end are the section"
    (Some [ "daily-close" ])
    (spool_of
       [
         begin_marker;
         daily_close_exec;
         end_marker;
         marker_word_in_a_comment;
         "";
       ])

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
          test_case "a line of the old shape is counted and unnamed" `Quick
            test_crontab_line_of_the_old_shape_is_counted_and_unnamed;
          test_case "a section mixing both shapes names only what it reads"
            `Quick test_crontab_mixed_section_names_only_what_it_reads;
          test_case "a line of neither shape is still unnamed with its position"
            `Quick
            test_crontab_line_of_neither_shape_is_unnamed_with_its_position;
        ] );
      ( "named jobs",
        [
          test_case "names the section's jobs in order" `Quick
            test_jobs_read_names_the_section_in_order;
          test_case "an entry that could not be read is not a name" `Quick
            test_jobs_read_omits_an_entry_that_could_not_be_read;
          test_case "every section in the file is covered" `Quick
            test_jobs_read_covers_every_section_in_the_file;
          test_case "a section nobody read is not a host that fires nothing"
            `Quick
            test_jobs_read_separates_an_answer_from_a_read_that_did_not_happen;
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
          test_case "a transport error never carries the spool it streamed"
            `Quick
            test_crontab_transport_error_never_carries_the_spool_it_streamed;
          test_case "a transport error carrying no contents is kept whole"
            `Quick test_crontab_transport_error_without_contents_is_kept_whole;
          test_case "no outcome returns a command line it read" `Quick
            test_crontab_never_returns_command_lines;
          test_case "the read streams the file" `Quick
            test_crontab_read_command_streams_the_file;
          test_case "the read marks where the contents end" `Quick
            test_crontab_read_command_marks_where_the_contents_end;
          test_case "a truncated read is not a host with no jobs" `Quick
            test_crontab_truncated_read_is_not_a_host_with_no_jobs;
          test_case "a truncated read says the read did not finish" `Quick
            test_crontab_truncated_read_says_the_read_did_not_finish;
          test_case "a read that delivered nothing is not an empty crontab"
            `Quick
            test_crontab_read_that_delivered_nothing_is_not_an_empty_crontab;
          test_case "an empty spool read whole is an answer" `Quick
            test_crontab_empty_spool_is_a_file_read_whole;
          test_case "a spool line ending in the marker word is not the marker"
            `Quick
            test_crontab_spool_line_ending_in_the_marker_word_is_not_the_marker;
        ] );
    ]
