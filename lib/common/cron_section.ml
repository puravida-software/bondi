type malformation = End_without_begin | Begin_without_end | Nested_begin

type split = {
  before : string list;
  section : string list option;
  after : string list;
}

let begin_marker = "# BEGIN BONDI CRON"
let end_marker = "# END BONDI CRON"

type marker = Begin | End | Neither

(* Markers are recognised after trimming, so an editor that left a carriage
   return or a trailing space on one still leaves a section a reader can see.
   The alternative reports a plainly marked section as having none, and the next
   write appends a second section beneath the first. *)
let marker_of_line line =
  let trimmed = String.trim line in
  match trimmed with
  | _ when String.equal trimmed begin_marker -> Begin
  | _ when String.equal trimmed end_marker -> End
  | _ -> Neither

(* One walk over the file, in three phases. The phase is the recursive function
   rather than a flag, so a line can only be added to the list its phase names
   and there is no state in which a line could land in two of them.

   The walk does not stop at the end marker. A file holding a second, separately
   balanced section is not malformed -- an earlier reader that matched markers
   untrimmed answered a marker carrying a carriage return as no section, and the
   next write appended one below the first -- so its lines join the first
   section's rather than being kept verbatim among the lines after it, where
   nothing reads them and every rewrite leaves them standing. A marker that does
   not balance anywhere in the file is still the error it would have been inside
   the section. A reader that stopped would call a file with a stray end marker
   well formed on the strength of the part it had read. *)
let rec scan_before acc = function
  | [] -> Ok { before = List.rev acc; section = None; after = [] }
  | line :: rest -> (
      match marker_of_line line with
      | Begin ->
          scan_section ~before:(List.rev acc) ~closed:[] ~after:[] [] rest
      | End -> Error End_without_begin
      | Neither -> scan_before (line :: acc) rest)

and scan_section ~before ~closed ~after acc = function
  | [] -> Error Begin_without_end
  | line :: rest -> (
      match marker_of_line line with
      | Begin -> Error Nested_begin
      | End -> scan_outside ~before ~closed:(List.rev acc :: closed) ~after rest
      | Neither -> scan_section ~before ~closed ~after (line :: acc) rest)

and scan_outside ~before ~closed ~after = function
  | [] ->
      Ok
        {
          before;
          section = Some (List.concat (List.rev closed));
          after = List.rev after;
        }
  | line :: rest -> (
      match marker_of_line line with
      | Begin -> scan_section ~before ~closed ~after [] rest
      | End -> Error End_without_begin
      | Neither -> scan_outside ~before ~closed ~after:(line :: after) rest)

let split_lines lines = scan_before [] lines

(* Trimmed rather than tested for emptiness, so a line an editor left a space or
   a carriage return on is the blank line it looks like. *)
let is_entry_line line = not (String.equal (String.trim line) "")

let join { before; section; after } =
  let bracketed =
    match section with
    | None -> []
    | Some lines -> (begin_marker :: lines) @ [ end_marker ]
  in
  before @ bracketed @ after
