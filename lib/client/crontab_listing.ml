type entry = Named of string | Unnamed of { position : int }
type malformation = End_without_begin | Begin_without_end | Nested_begin

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

(* The section the server writes, delimited exactly as it delimits it. *)
let begin_marker = "# BEGIN BONDI CRON"
let end_marker = "# END BONDI CRON"

type line_kind = Begin | End | Blank | Entry of string

(* Markers are recognised after trimming, so an editor that left a carriage
   return or a trailing space on one still leaves a section a reader can see.
   The alternative reports a plainly marked section as having none. *)
let kind_of_line line =
  let trimmed = String.trim line in
  match trimmed with
  | "" -> Blank
  | _ when String.equal trimmed begin_marker -> Begin
  | _ when String.equal trimmed end_marker -> End
  | _ -> Entry line

let payload_prefix = "-d '"
let shell_escaped_quote = "'\\''"

(* The argument the writer quoted, taken back out of the line. A single quote
   inside it was escaped by ending the quoted run, emitting one, and starting a
   new run, so the sequence that does that is not the end of the argument. *)
let quoted_argument line ~from =
  let start = from + String.length payload_prefix in
  let length = String.length line in
  let escape_length = String.length shell_escaped_quote in
  let rec find_end index =
    if index >= length then None
    else if line.[index] <> '\'' then find_end (index + 1)
    else if
      index + escape_length <= length
      && String.sub line index escape_length = shell_escaped_quote
    then find_end (index + escape_length)
    else Some index
  in
  match find_end start with
  | None -> None
  | Some stop -> Some (String.sub line start (stop - start))

(* Undo the writer's escaping, so what is parsed is what the shell would have
   handed to curl rather than the spool file's rendering of it. *)
let unescape_shell_quotes value =
  let buffer = Buffer.create (String.length value) in
  let length = String.length value in
  let escape_length = String.length shell_escaped_quote in
  let rec loop index =
    if index >= length then Buffer.contents buffer
    else if
      index + escape_length <= length
      && String.sub value index escape_length = shell_escaped_quote
    then (
      Buffer.add_char buffer '\'';
      loop (index + escape_length))
    else (
      Buffer.add_char buffer value.[index];
      loop (index + 1))
  in
  loop 0

(* The job's name is the only field this reads, and the only one it can return.
   A payload that does not parse yields nothing at all rather than a fragment of
   itself: every other field on that line is a secret or a command, and there is
   no rendering of them this report is allowed to make. *)
let job_name_of_payload payload =
  match Yojson.Safe.from_string payload with
  | `Assoc fields -> (
      match List.assoc_opt "job" fields with
      | Some (`String name) -> Some name
      | Some
          (`Assoc _ | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null)
      | None ->
          None)
  | `Bool _
  | `Float _
  | `Int _
  | `Intlit _
  | `List _
  | `Null
  | `String _ ->
      None
  | exception Yojson.Json_error _ -> None

let job_name_of_line line =
  match Bondi_common.String_utils.index_of ~needle:payload_prefix line with
  | None -> None
  | Some from -> (
      match quoted_argument line ~from with
      | None -> None
      | Some argument -> job_name_of_payload (unescape_shell_quotes argument))

let entry_of_line ~position line =
  match job_name_of_line line with
  | Some name -> Named name
  | None -> Unnamed { position }

let rec scan lines ~inside ~seen_section ~position ~entries =
  match lines with
  | [] -> (
      match (inside, seen_section) with
      | true, _ -> Malformed Begin_without_end
      | false, true -> Section { entries = List.rev entries }
      | false, false -> No_section)
  | line :: rest -> (
      match (kind_of_line line, inside) with
      | Begin, true -> Malformed Nested_begin
      | Begin, false ->
          scan rest ~inside:true ~seen_section:true ~position ~entries
      | End, true -> scan rest ~inside:false ~seen_section ~position ~entries
      | End, false -> Malformed End_without_begin
      | Blank, _
      | Entry _, false ->
          scan rest ~inside ~seen_section ~position ~entries
      | Entry text, true ->
          scan rest ~inside ~seen_section ~position:(position + 1)
            ~entries:(entry_of_line ~position text :: entries))

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

let of_read_output reading =
  match reading with
  | Error message -> Unreadable (redacted message)
  | Ok output -> (
      (* The contents marker is answered first, because everything after it is
         the file and a line of the file is free to hold any of the words
         below. *)
      match contents_after_marker output with
      | Some contents ->
          scan
            (String.split_on_char '\n' contents)
            ~inside:false ~seen_section:false ~position:1 ~entries:[]
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

let job_count listing =
  match listing with
  | Section { entries } -> Some (List.length entries)
  | No_section
  | Malformed _
  | Unreadable _ ->
      None
