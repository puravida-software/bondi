type entry = Named of string | Unnamed of { position : int }

type malformation = Bondi_common.Cron_section.malformation =
  | End_without_begin
  | Begin_without_end
  | Nested_begin

type t =
  | Section of { entries : entry list }
  | No_section
  | Malformed of malformation
  | Unreadable of string

let spool_path = "/var/spool/cron/crontabs/root"

(* The contents marker separates the command's own words from the file's. It is
   printed before the file's first byte and nothing the file holds can appear
   ahead of it, so everything from the marker onwards is the file and everything
   before it is not. That is what makes [redacted] a cut at a known place rather
   than a filter guessing which bytes matter. *)
let contents_marker = "BONDI_CRONTAB_CONTENTS"

(* The end marker closes what the contents marker opened, and the read's own
   success is what prints it. The guard only asks whether the file can be
   opened, so a [cat] that then fails -- refused by the same sudoers rule that
   permitted the [test], or killed part-way through -- would print the contents
   marker and a truncated file, and the command ends [exit 0] so that the host's
   answer survives the ssh layer. Printed as a statement of its own the marker
   ran whatever the read did, and said the file had ended whether it had or not.

   Joined to the read, it is emitted only when [cat] exited 0, and the trailing
   [exit 0] still carries the answer out. That is the right way round: a
   complete read becomes something the reader is told rather than something it
   infers from the absence of a complaint. What it attests is the read having
   run to its end and the stream having arrived whole -- a [cat] that failed and
   a connection cut mid-transfer both leave it unprinted. What it cannot attest
   is a file whose own bytes spell it, which is [contents_complete]'s half. *)
let end_of_contents_marker = "BONDI_CRONTAB_END"
let absent_marker = "BONDI_CRONTAB_ABSENT"
let unreadable_marker = "BONDI_CRONTAB_UNREADABLE"

(* A spool file that is not there is a host with no crontab, which is a fact
   about its jobs; a spool file that is there and will not open is a fact about
   the read. The two are separated on standard output rather than by an exit
   status, which is the channel a dropped connection arrives on as well.

   The read is privileged because the write is: the orchestrator writes this
   file as root into a directory only root may traverse, so the SSH user is
   routinely one that cannot even stat it. An unprivileged guard answers "not
   there" for a file that is plainly there, which is a false statement about
   the host's jobs.

   [cat] prints the file as it reads it, after the marker announcing it. It used
   to run inside a command substitution so that a failure part-way through
   emitted no fragment of the file, and what that cost was the whole spool held
   in the shell's memory before a byte of it was printed. The fragment is still
   not something to hand back -- a spool line may be the shape Bondi wrote
   before this one, carrying the job's secrets on the line itself -- so
   [redacted] cuts it at the marker on the way out instead.

   The guard therefore asks whether the file can be read and not merely whether
   it is there. A file that stops being readable between the guard and the read
   is a [cat] that exits non-zero, and the closing marker is joined to that exit
   rather than printed after it, so what such a read hands back is contents with
   nothing closing them and not a section read as far as the read got. *)
let read_command =
  let quoted = Filename.quote spool_path in
  Printf.sprintf
    "if sudo -n test -r %s 2>/dev/null; then echo %s; sudo -n cat %s \
     2>/dev/null && echo %s; elif sudo -n test -e %s 2>/dev/null; then echo \
     %s; elif sudo -n true 2>/dev/null; then echo %s; else echo %s; fi; exit 0"
    quoted contents_marker quoted end_of_contents_marker quoted
    unreadable_marker absent_marker unreadable_marker

(* The one shape this reads: a schedule, a docker exec into the orchestrator,
   and the path of the job's run file. The line carries nothing else, so the
   name is in the path or it is nowhere.

   The reader is Bondi_common.Cron_exec_line's rather than a second copy of it.
   The client may not depend on bondi_server, but both libraries depend on
   bondi_common, so the marker the server writes and the marker this looks for
   are one string and the two cannot drift.

   That reader re-derives the path from the name taken out of it and accepts the
   line only when the two are the same string. A hand-edited line reading
   ../../passwd/run.json therefore names nothing rather than reporting a job
   called "passwd": what leaves this module is a name some valid job produces,
   never a fragment of whatever path the line happened to carry. *)
let job_name_of_exec_line = Bondi_common.Cron_exec_line.job_name_of

(* A crontab is a file anything may write, and a line the exec grammar does not
   accept is one this cannot name -- whether it is a shape Bondi wrote before
   this one, or something an operator put there by hand. It keeps its place and
   its position all the same: it is on the box, it fires, and the next rewrite
   removes it. *)
let entry_of_line ~position line =
  match job_name_of_exec_line line with
  | Some job -> Named job
  | None -> Unnamed { position }

(* Where the section is, is Bondi_common.Cron_section's answer and not a second
   one taken here. This module and the orchestrator's writer disagreeing about
   which line opens a section is the defect that reports every job on a box as
   absent while both suites stay green.

   What this adds is what only a reader needs: a blank line inside the section
   is not an entry and does not advance the count, so the position a report
   names is the position of an entry rather than of a line. *)
let entries_of_section section =
  section
  |> List.filter Bondi_common.Cron_section.is_entry_line
  |> List.mapi (fun index line -> entry_of_line ~position:(index + 1) line)

let scan lines =
  match Bondi_common.Cron_section.split_lines lines with
  | Error malformation -> Malformed malformation
  | Ok { before = _; section = None; after = _ } -> No_section
  | Ok { before = _; section = Some section; after = _ } ->
      Section { entries = entries_of_section section }

(* A transport's account of why it could not answer is the merged output of a
   command that may already have streamed the file. Everything from the contents
   marker onwards is the file, so the message is cut there and the tail is
   dropped rather than inspected: a filter deciding line by line whether
   something looks like a secret is a filter that is one day wrong, and this
   module's guarantee cannot rest on one. *)
let redacted message =
  match Bondi_common.String_utils.index_of ~needle:contents_marker message with
  | None -> message
  | Some index ->
      String.sub message 0 index
      ^ "(the read had begun returning the file, and what it returned is not \
         reported)"

let contents_after_marker output =
  match Bondi_common.String_utils.index_of ~needle:contents_marker output with
  | None -> None
  | Some index ->
      let start = index + String.length contents_marker in
      Some (String.sub output start (String.length output - start))

(* Contents the end marker closes are the whole file; contents it does not are
   as much of the file as the read got to.

   The marker is looked for as its own line at the end, newline and all. A
   crontab is a file anything may write and the word is a word like any other,
   so a bare suffix cannot tell the command's marker from the tail of the last
   line a dying read delivered: a file cut on a line reading "# BONDI_CRONTAB_END"
   would pass as a read that finished, and the cut that removes the marker would
   take the end of that line with it. With the newline in the match, only a line
   that is the marker and nothing else can close the read.

   An empty file read whole prints the marker with no byte of the file ahead of
   it, and that is the one case the newline is not there to require: it is a
   complete read of a file holding nothing, which is an answer. A file whose
   last byte is not a newline runs its last line into the marker and reads as
   incomplete -- the one place this shape is less precise than the file
   deserves, and it errs towards a read that did not finish rather than a line
   quietly shortened.

   A truncated read is not a smaller file, and the difference is the one the
   caller acts on. Cut before the section, this would otherwise be a file with
   no Bondi markers -- an answer, and the answer "nothing on this host fires any
   of Bondi's jobs", which reports every job in the payload directory as having
   lost its line. Cut after a section that happens to close, it would be a
   section holding a subset, which reports the jobs below the cut as orphaned
   files. Both are a disagreement invented out of a read that never finished. *)
let contents_complete contents =
  let trimmed = String.trim contents in
  let closing_line = "\n" ^ end_of_contents_marker in
  if String.equal trimmed end_of_contents_marker then Some ""
  else if String.ends_with ~suffix:closing_line trimmed then
    Some
      (String.sub trimmed 0
         (String.length trimmed - String.length closing_line))
  else None

let said marker output =
  Bondi_common.String_utils.contains ~needle:marker output

(* A spool the host read and refused is not a spool the host was never asked
   about. The first is a permission or a missing file on the box; the second is
   the connection. Both leave the section unknown, and only the wording tells an
   operator which of the two to go and look at. *)
let unreadable_of_failure failure =
  Unreadable (redacted (Remote_exec.explain ~subject:"the read" failure))

let of_read_output reading =
  match reading with
  | Error failure -> unreadable_of_failure failure
  | Ok output -> (
      (* The contents marker is answered first, because everything after it is
         the file and a line of the file is free to hold any of the words
         below. *)
      match contents_after_marker output with
      | Some contents -> (
          match contents_complete contents with
          | Some complete -> scan (String.split_on_char '\n' complete)
          | None ->
              Unreadable
                "the read of the host's crontab spool file stopped before the \
                 end of the file, so what it holds is unknown")
      | None -> (
          match (said unreadable_marker output, said absent_marker output) with
          | true, _ ->
              Unreadable
                "the host could not read its crontab spool file, so what it \
                 holds is unknown"
          | false, true -> No_section
          | false, false ->
              Unreadable
                "the host answered without saying whether it could read its \
                 crontab spool file"))

(* The names the section holds, in the order the entries appear. An entry whose
   job could not be read contributes nothing: what it is is unknown, and a
   position is not a job any other reader could act on.

   The three other outcomes split two ways, and the split is the whole point of
   the option. A file the host read that carries no Bondi section is the host
   answering: no line on that box fires anything of Bondi's, which is a fact a
   caller may act on. Markers that do not balance and a read that never
   delivered are not answers at all, and a caller comparing this against the
   payload directory would otherwise read them as "the host fires nothing" and
   report every job on the box as having lost its line. *)
let jobs_read listing =
  match listing with
  | Section { entries } ->
      Some
        (List.filter_map
           (fun entry ->
             match entry with
             | Named job -> Some job
             | Unnamed { position = _ } -> None)
           entries)
  | No_section -> Some []
  | Malformed _
  | Unreadable _ ->
      None

let job_count listing =
  match listing with
  | Section { entries } -> Some (List.length entries)
  | No_section
  | Malformed _
  | Unreadable _ ->
      None
