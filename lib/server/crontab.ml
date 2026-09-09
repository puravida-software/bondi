(* Crontab management for Bondi cron jobs.
   Writes to root's crontab at /var/spool/cron/crontabs/root.
   A generated line carries a schedule, a command and a path; the job itself
   sits in the file that path names. The curl shape it replaced is read but
   never written, and the reader for it is Bondi_common.Cron_legacy_line. *)

open Json_helpers
module Alert = Bondi_common.Alert

let ( let* ) = Result.bind

type scheduled_job = { name : string; image : string } [@@deriving eq, show]
(** A cron job found in the system crontab. *)

(** A Bondi line as the reader could resolve it. *)
type listed_job = Job of scheduled_job | Unreadable of { position : int }
[@@deriving eq, show]

let crontab_path = "/var/spool/cron/crontabs/root"
let crontab_spool_dir = "/var/spool/cron/crontabs"
let bondi_begin_marker = Bondi_common.Cron_section.begin_marker
let bondi_end_marker = Bondi_common.Cron_section.end_marker

(* Run payload sent to /run endpoint *)
type run_payload = {
  job : string;
  image : string;
  network : string option; [@default None]
  env_vars : string_map option; [@default None]
  alert_sinks : Alert.sinks option; [@default None]
  exit_code_severities : Strategy.Simple.exit_code_severities option;
      [@default None]
}
[@@deriving yojson]

(* Serialised through the deriving encoder rather than assembled by hand, so
   this and Run's decoder are one record and a field added to either without the
   other fails to compile. secret_env_vars is absent from the payload type and
   therefore cannot be written into the file by accident: secrets keep their own
   file, written by Cron_secrets. *)
let run_payload_of_cron_job (c : Strategy.Simple.cron_job) : Yojson.Safe.t =
  run_payload_to_yojson
    {
      job = c.name;
      image = c.image;
      network = c.network;
      env_vars = c.env_vars;
      alert_sinks = c.alert_sinks;
      exit_code_severities = c.exit_code_severities;
    }

let read_crontab () : (string, string) result =
  try
    let ic = open_in crontab_path in
    let contents = really_input_string ic (in_channel_length ic) in
    close_in ic;
    Ok contents
  with
  | Sys_error _ -> Ok ""
  | exn -> Error (Printexc.to_string exn)

(* The legacy [curl -d '<json>'] line's readers are
   Bondi_common.Cron_legacy_line's, not a second copy of them. The client reads
   a host's spool file with the same grammar, and one reader undoing the
   writer's quoting while the other did not is how the same line came to name a
   job on one side and nothing on the other.

   What stays here is the parse. That module hands back the shell's argument as
   the bytes curl would have been given, which are not required to be JSON at
   all; this module's callers want a value, so this is where the text becomes
   one and where a payload that does not parse becomes None. *)
let json_from_cron_line line =
  match Bondi_common.Cron_legacy_line.payload_of line with
  | None -> None
  | Some payload -> (
      match Yojson.Safe.from_string payload with
      | json -> Some json
      | exception Yojson.Json_error _ -> None)

let job_name_from_cron_line = Bondi_common.Cron_legacy_line.job_name_of
let image_from_cron_line = Bondi_common.Cron_legacy_line.image_of

(* The path in a generated line, recovered and then re-derived: the name is the
   directory the run file sits in, and the line is accepted only when
   run_file_of rebuilds the very string the line carried, so a hand-edited line
   naming ../../somewhere cannot be followed.

   Bondi_common.Cron_exec_line's, not a copy of it. The client reads a host's
   spool file with the same function and entry_of_cron_job below writes the
   marker that function looks for, so writer and both readers are one shape. *)
let job_name_from_exec_line = Bondi_common.Cron_exec_line.job_name_of
let string_of_lines lines = String.concat "\n" lines ^ "\n"

(* The redirection is evaluated inside the container, not by the host's shell,
   which is why the command is wrapped in sh -c. /etc/bondi/cron is the
   orchestrator's own view of the job's files; setup bind-mounts the host
   directory at the same path so a rebuilt container does not lose them, and the
   reader inside the container is the only side that has to be right about where
   they are.

   The job name is the only thing interpolated, and it arrives having already
   passed Cron_secrets.is_valid_name: the deploy writes the job's files before
   it writes its line, and that check refuses a name holding a quote, a slash or
   a leading dot. So there is nothing here to escape, and the path is taken from
   Cron_secrets so the line and the writer cannot name different files.

   The command and the redirection are not spelled here either: they are
   Bondi_common.Cron_exec_line's marker, which is the string both readers search
   for. A change to what this line runs is therefore a change every reader
   follows, rather than one that leaves them naming nothing.

   docker exec exits with the exec'd command's status, so a failing run is a
   non-zero line and cron mails it. That is what the curl flags used to buy. *)
let entry_of_cron_job (c : Strategy.Simple.cron_job) =
  Printf.sprintf "%s docker exec bondi-orchestrator sh -c '%s%s'" c.schedule
    Bondi_common.Cron_exec_line.exec_marker
    (Cron_secrets.run_file_of c.name)

let generate_bondi_entries cron_jobs =
  (bondi_begin_marker :: List.map entry_of_cron_job cron_jobs)
  @ [ bondi_end_marker ]

let write_crontab contents : (unit, string) result =
  try
    let oc = open_out crontab_path in
    Fun.protect
      ~finally:(fun () -> close_out oc)
      (fun () ->
        output_string oc contents;
        Ok ())
  with
  | exn -> Error (Printexc.to_string exn)

let chmod path mode : (unit, string) result =
  try
    Unix.chmod path mode;
    Ok ()
  with
  | Unix.Unix_error (e, _, _) ->
      Error (Printf.sprintf "chmod %s: %s" path (Unix.error_message e))

(* Touch the spool directory so cron detects the change. Cron checks directory mtime,
   not file mtime; modifying a file in place does not update the directory. *)
let touch_spool_dir () : (unit, string) result =
  try
    let now = Unix.time () in
    Unix.utimes crontab_spool_dir now now;
    Ok ()
  with
  | Unix.Unix_error (e, _, _) ->
      Error
        (Printf.sprintf "touch %s: %s" crontab_spool_dir (Unix.error_message e))

(* An entry inside the section, as the merge can address it. A closed variant
   rather than a [string option] beside the line: the merge has to answer for
   the nameless entry, and the compiler is what makes it. An entry is Anonymous
   when neither reader names it -- a hand-written line, or one whose payload
   carries no job -- and such an entry cannot be merged by name, which is the
   whole reason it has to be carried through rather than looked up. *)
type section_entry =
  | Named of { name : string; line : string }
  | Anonymous of string

(* Both shapes, one name. The exec reader is asked first because it is the shape
   this module writes; a line it names carries no [-d '] payload for the legacy
   reader to find, so the two cannot both answer. *)
let name_of_section_line line =
  match job_name_from_exec_line line with
  | Some name -> Some name
  | None -> job_name_from_cron_line line

let malformed_section = "the Bondi section of the crontab is malformed: "

(* The refusal for a crontab whose markers do not balance. It names which of the
   three malformations it is and nothing else -- not the line, not the contents
   of the position it stopped at, not a payload. Every line in a crontab may be
   a job's payload including its credentials, and this text is returned over
   HTTP, mailed by cron and shipped with the diagnostics stream; the convention
   that a decode error carries the input it rejected is inverted here for that
   reason. The three sentences are pairwise distinct, so the message alone
   answers which defect an operator is going to look for.

   A message rather than a classified failure: this module's other error path is
   a string, both callers turn the refusal straight back into one, and neither
   handler asks it what HTTP status or exit code it deserves. A vocabulary no
   consumer reads is a vocabulary that goes out of step with the ones that do. *)
let refusal_of_malformation : Bondi_common.Cron_section.malformation -> string =
  function
  | End_without_begin ->
      malformed_section ^ "an end marker closes a section that was never opened"
  | Begin_without_end ->
      malformed_section ^ "a begin marker opens a section the file never closes"
  | Nested_begin ->
      malformed_section
      ^ "a begin marker opens a section inside one already open"

(* A blank line inside the section is an entry of neither shape: it is dropped
   here rather than carried, which is why parse_listed_jobs gives it no position
   and the merge does not write it back. Whether a line inside the section
   counts as an entry is Bondi_common.Cron_section's answer, so the position
   this module addresses and the position the client reports are one rule. *)
let entry_of_section_line line =
  if not (Bondi_common.Cron_section.is_entry_line line) then None
  else
    match name_of_section_line line with
    | Some name -> Some (Named { name; line })
    | None -> Some (Anonymous line)

(* Split the crontab into the lines outside the section and the entries inside
   it, both in their original order and, inside the section, byte for byte.

   The walk is not this module's. Where the section is, what an unbalanced
   marker does and whether a marker an editor left whitespace on is still a
   marker are decided in one place for both libraries, so the file the
   orchestrator writes and the file the client reads back are cut the same way.
   This module keeps only what an entry is, which is the half the client has no
   use for.

   An unbalanced marker is a refusal rather than a section read short. Answering
   it as no section is what appended a second section beneath the first, leaving
   a job's old line outside the markers and its new line inside them, both
   firing. A crontab already in that state is not refused -- both its sections
   balance -- and every section's entries arrive here in one list, so the merge
   below writes them back as one section and the box heals. *)
let split_bondi_section lines =
  match Bondi_common.Cron_section.split_lines lines with
  | Error malformation -> Error (refusal_of_malformation malformation)
  | Ok Bondi_common.Cron_section.{ before; section; after } ->
      let entries =
        match section with
        | None -> []
        | Some section_lines ->
            List.filter_map entry_of_section_line section_lines
      in
      Ok (before @ after, entries)

let name_of_entry = function
  | Named { name; _ } -> Some name
  | Anonymous _ -> None

let line_of_entry = function
  | Named { line; _ } -> line
  | Anonymous line -> line

(* Merge deploy jobs into the existing Bondi section. A job the deploy names
   replaces whichever shape held it, in the place that shape held; every other
   entry -- a job the deploy does not name, and a line no reader names -- is
   emitted as it was read. Jobs the section did not hold follow, in the order
   given. None or an empty list removes the section.

   A section can hold one name twice: a restored backup, or a hand edit applied
   to half the file, leaves a legacy line and an exec line for the same job side
   by side. Rewriting each of them in place would emit the job's line twice and
   fire the job twice a schedule, so the first entry a deploy names is replaced
   and later entries of that name are dropped. The written names are carried
   through the fold for exactly that: the answer depends on what has already
   been emitted, which a map over the entries cannot see.

   A crontab holding two whole sections is collapsed for the same reason: the
   markers written back are one pair, whichever number the file arrived with,
   and the entries of every section it held are merged into that one. Otherwise
   each deploy updates one section and leaves the other stale, and both fire. *)
let merge_bondi_section (cron_jobs : Strategy.Simple.cron_job list option)
    (lines : string list) : (string list, string) result =
  let* outside, entries = split_bondi_section lines in
  let trimmed =
    outside |> List.map String.trim |> List.filter (fun l -> l <> "")
  in
  match cron_jobs with
  | None
  | Some [] ->
      Ok trimmed
  | Some jobs ->
      let deployed name =
        List.find_opt
          (fun (c : Strategy.Simple.cron_job) -> String.equal c.name name)
          jobs
      in
      let kept =
        entries
        |> List.fold_left
             (fun (written, acc) entry ->
               match entry with
               | Anonymous line -> (written, line :: acc)
               | Named { name; line } -> (
                   match deployed name with
                   | None -> (written, line :: acc)
                   | Some job ->
                       if List.exists (String.equal name) written then
                         (written, acc)
                       else (name :: written, entry_of_cron_job job :: acc)))
             ([], [])
        |> snd
        |> List.rev
      in
      let held = List.filter_map name_of_entry entries in
      let added =
        jobs
        |> List.filter (fun (c : Strategy.Simple.cron_job) ->
            not (List.exists (String.equal c.name) held))
        |> List.map entry_of_cron_job
      in
      (* Assembled by the module that cut the file rather than by hand here, so
         the markers this writes and the markers both libraries look for cannot
         come apart. *)
      Ok
        (Bondi_common.Cron_section.join
           { before = trimmed; section = Some (kept @ added); after = [] })

let upsert (cron_jobs : Strategy.Simple.cron_job list option) :
    (unit, string) result =
  let* current = read_crontab () in
  let lines = String.split_on_char '\n' current in
  let* merged = merge_bondi_section cron_jobs lines in
  let contents = string_of_lines merged in
  let* () = write_crontab contents in
  let* () = chmod crontab_path 0o600 in
  touch_spool_dir ()

(* The two shapes a line inside the section can have, plus the answer for one
   that is neither. A closed variant rather than nested options: when the
   legacy scanner goes, [Legacy] loses its only producer and warning 37 makes
   the deletion a compiler event rather than a silent change of behaviour. *)
type line_shape =
  | Exec of string  (** the job name, taken from its run file's path *)
  | Legacy of string  (** the line, for the surviving [curl] scanner *)
  | Unrecognised  (** neither reader can address it *)

let shape_of_line line =
  match job_name_from_exec_line line with
  | Some name -> Exec name
  | None -> (
      match json_from_cron_line line with
      | Some _ -> Legacy line
      | None -> Unrecognised)

(* Decoded through the same record the writer encodes, so the file and the
   generator are one contract. Nothing about the file's contents reaches the
   answer on any failing path: [Unreadable] carries a position and has nowhere
   to put a payload. *)
let resolve_exec_line ~read_file ~position name =
  match read_file (Cron_secrets.run_file_of name) with
  | None -> Unreadable { position }
  | Some contents -> (
      match Yojson.Safe.from_string contents with
      | exception Yojson.Json_error _ -> Unreadable { position }
      | json -> (
          match run_payload_of_yojson json with
          | Error _ -> Unreadable { position }
          | Ok payload ->
              if String.equal payload.job name then
                Job { name; image = payload.image }
              else Unreadable { position }))

let resolve_legacy_line ~position line =
  match (job_name_from_cron_line line, image_from_cron_line line) with
  | Some name, Some image -> Job { name; image }
  | Some _, None
  | None, Some _
  | None, None ->
      Unreadable { position }

let resolve_line ~read_file ~position line =
  match shape_of_line line with
  | Exec name -> resolve_exec_line ~read_file ~position name
  | Legacy legacy -> resolve_legacy_line ~position legacy
  | Unrecognised -> Unreadable { position }

(* The section as split_bondi_section reads it, each entry resolved as far as it
   can be. A position is the entry's place in that list counting from one, so
   blank lines take no position -- they were never entries. Reading the section
   through the merge's own walk is what makes "the entry at position 3" mean the
   same line to a report and to the next rewrite; the same way
   Crontab_listing.scan counts, the crontab being split on newlines, a trailing
   newline alone would otherwise become an entry. *)
let parse_listed_jobs ~read_file (lines : string list) :
    (listed_job list, string) result =
  let* _outside, entries = split_bondi_section lines in
  Ok
    (List.mapi
       (fun index entry ->
         resolve_line ~read_file ~position:(index + 1) (line_of_entry entry))
       entries)

(* What a run file may be, before anything looks at it. The whole file is read
   into memory first, and the path is root-owned and written by this server, so
   an oversized one is a fault rather than an attack -- but Remote_exec bounds
   its own interpolated output for the same reason, and an unbounded read beside
   a bounded one is the asymmetry that gets copied. 64 KB is far past any
   payload run_payload_of_cron_job produces; a file longer than this is read
   short, does not decode, and reports as Unreadable.

   Narrowed to the two exceptions a read raises. A catch-all here would answer
   Stdlib.Exit or Stack_overflow with "this entry is unreadable" and send an
   operator to look at a file that is fine. *)
let run_file_size_limit = 65536

let read_job_file path =
  try
    let ic = open_in_bin path in
    Fun.protect
      ~finally:(fun () -> close_in_noerr ic)
      (fun () ->
        Some
          (really_input_string ic
             (min (in_channel_length ic) run_file_size_limit)))
  with
  | Sys_error _ -> None
  | End_of_file -> None

let list_scheduled_jobs () : (listed_job list, string) result =
  let* contents = read_crontab () in
  let lines = String.split_on_char '\n' contents in
  parse_listed_jobs ~read_file:read_job_file lines
