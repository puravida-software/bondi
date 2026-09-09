(* Crontab management for Bondi cron jobs.
   Writes to root's crontab at /var/spool/cron/crontabs/root.
   A generated line carries a schedule, a command and a path; the job itself
   sits in the file that path names. The curl shape below is read, never
   written. *)

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
let bondi_begin_marker = "# BEGIN BONDI CRON"
let bondi_end_marker = "# END BONDI CRON"

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

(* Extract the JSON payload from a cron line's -d '...' argument. *)
let json_from_cron_line line =
  let prefix = "-d '" in
  let rec find_prefix i =
    if i + String.length prefix > String.length line then None
    else if String.sub line i (String.length prefix) = prefix then Some i
    else find_prefix (i + 1)
  in
  match find_prefix 0 with
  | None -> None
  | Some idx -> (
      let start = idx + String.length prefix in
      let rec find_end i =
        if i >= String.length line then None
        else if line.[i] = '\'' then
          if i + 4 <= String.length line && String.sub line i 4 = "'\\''" then
            find_end (i + 4)
          else Some i
        else find_end (i + 1)
      in
      match find_end start with
      | None -> None
      | Some end_idx -> (
          try
            let json_str = String.sub line start (end_idx - start) in
            Some (Yojson.Safe.from_string json_str)
          with
          | _ -> None))

(* Extract a string field from the JSON payload in a cron line. *)
let string_field_from_cron_line ~field line =
  match json_from_cron_line line with
  | Some (`Assoc assoc) -> (
      match List.assoc_opt field assoc with
      | Some (`String v) -> Some v
      | _ -> None)
  | _ -> None

(* Extract job name from a Bondi cron line by parsing the JSON in -d '...' *)
let job_name_from_cron_line line = string_field_from_cron_line ~field:"job" line

(** Extract the image field from a cron line's embedded JSON payload. *)
let image_from_cron_line line = string_field_from_cron_line ~field:"image" line

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

(* Split the crontab into the lines outside the section and the entries inside
   it, both in their original order and, inside the section, byte for byte.
   Blank lines inside the section are entries of neither shape and are dropped.

   The one walk over a crontab. The merge and parse_listed_jobs both read the
   section through it, so what counts as inside the section, what an unbalanced
   marker does and which lines are entries at all are decided once. Two walks
   agreeing by prose is how they come to disagree: the rules are the same rules
   because they are the same fold, not because a comment says so. *)
let split_bondi_section lines =
  let rec loop in_bondi outside entries = function
    | [] -> (List.rev outside, List.rev entries)
    | line :: rest ->
        if String.equal line bondi_begin_marker then
          loop true outside entries rest
        else if String.equal line bondi_end_marker then
          loop false outside entries rest
        else if not in_bondi then loop in_bondi (line :: outside) entries rest
        else if String.equal (String.trim line) "" then
          loop in_bondi outside entries rest
        else
          let entry =
            match name_of_section_line line with
            | Some name -> Named { name; line }
            | None -> Anonymous line
          in
          loop in_bondi outside (entry :: entries) rest
  in
  loop false [] [] lines

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
   been emitted, which a map over the entries cannot see. *)
let merge_bondi_section (cron_jobs : Strategy.Simple.cron_job list option)
    (lines : string list) : string list =
  let outside, entries = split_bondi_section lines in
  let trimmed =
    outside |> List.map String.trim |> List.filter (fun l -> l <> "")
  in
  match cron_jobs with
  | None
  | Some [] ->
      trimmed
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
      trimmed @ (bondi_begin_marker :: (kept @ added)) @ [ bondi_end_marker ]

let upsert (cron_jobs : Strategy.Simple.cron_job list option) :
    (unit, string) result =
  let* current = read_crontab () in
  let lines = String.split_on_char '\n' current in
  let contents = string_of_lines (merge_bondi_section cron_jobs lines) in
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
let parse_listed_jobs ~read_file (lines : string list) : listed_job list =
  let _outside, entries = split_bondi_section lines in
  List.mapi
    (fun index entry ->
      resolve_line ~read_file ~position:(index + 1) (line_of_entry entry))
    entries

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
  Ok (parse_listed_jobs ~read_file:read_job_file lines)
