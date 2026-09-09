type shape = Exec_line | Legacy_line
type named_job = { job : string; shape : shape }
type entry = Named of named_job | Unnamed of { position : int }

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

(* The contents marker is printed before the first byte of the file and nothing
   the file holds can appear ahead of it. That is what makes {!redacted}
   provable rather than a filter over what a line might look like: everything
   from the marker onwards is the file, and everything before it is not. *)
let contents_marker = "BONDI_CRONTAB_CONTENTS"
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

   [cat] runs inside a command substitution so that nothing is printed while it
   reads. A failure part-way through therefore emits no fragment of the file,
   and the marker is only ever reached once the whole of it has been read. *)
let read_command =
  let quoted = Filename.quote spool_path in
  Printf.sprintf
    "if contents=$(sudo -n cat %s 2>/dev/null); then echo %s; printf '%%s\\n' \
     \"$contents\"; elif sudo -n test -e %s 2>/dev/null; then echo %s; elif \
     sudo -n true 2>/dev/null; then echo %s; else echo %s; fi; exit 0"
    quoted contents_marker quoted unreadable_marker absent_marker
    unreadable_marker

(* The legacy shape, still on every box: the whole job as a single-quoted JSON
   argument to curl, secrets included. The grammar is Bondi_common's rather than
   a second copy of it -- the orchestrator reads these lines to merge a deploy
   into the section and this reads them to report what is scheduled, and one
   reader undoing the writer's quoting while the other does not is how the same
   line names a job on one side and nothing on the other.

   The name that comes back is a JSON field the host wrote, and nothing else on
   the line constrains it. So it is held to the rule a declared job's name is
   held to: one [Managed_container.create] would have rejected cannot have come
   from a job Bondi deployed, and it is not reported at all rather than reported
   and then interpolated into a path by whoever reads it next. The line stays an
   entry -- it is on the box, and the next rewrite removes it. *)
let job_name_of_legacy_line line =
  match Bondi_common.Cron_legacy_line.job_name_of line with
  | None -> None
  | Some name ->
      if Bondi_common.Managed_container.is_valid_name name then Some name
      else None

(* The shape the orchestrator writes now: a schedule, a docker exec into it, and
   the path of the job's run file. The line carries nothing else, so the name is
   in the path or it is nowhere.

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

(* Both shapes are tried, and the one this reads before the other is the one
   nothing on a box will hold much longer. A line is only ever of one shape:
   the exec line carries no -d argument and the legacy line carries no exec
   marker. *)
let entry_of_line ~position line =
  match job_name_of_exec_line line with
  | Some job -> Named { job; shape = Exec_line }
  | None -> (
      match job_name_of_legacy_line line with
      | Some job -> Named { job; shape = Legacy_line }
      | None -> Unnamed { position })

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
   command that may already have streamed the file. Everything from the
   contents marker onwards is the file, so the message is cut there and the tail
   is dropped rather than inspected: a filter deciding line by line whether
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
      | Some contents -> scan (String.split_on_char '\n' contents)
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
   position is not a job any other reader could act on. Every other outcome
   yields nothing at all rather than an empty section, for the reason
   {!job_count} gives -- a file that was never read supports no claim about what
   is scheduled on the host. *)
let named_jobs_with_shape listing =
  match listing with
  | Section { entries } ->
      List.filter_map
        (fun entry ->
          match entry with
          | Named named -> Some named
          | Unnamed { position = _ } -> None)
        entries
  | No_section
  | Malformed _
  | Unreadable _ ->
      []

let job_count listing =
  match listing with
  | Section { entries } -> Some (List.length entries)
  | No_section
  | Malformed _
  | Unreadable _ ->
      None
