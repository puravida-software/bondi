type verdict = All_present | Missing of string list | Unreadable of string

(* The prefix of the one line the command prints per missing path, and the
   marker it prints once it has tested every path. Both are words no shell, ssh
   or sudo prints on its own, so a line the command did not write is not read
   as one it did. *)
let missing_prefix = "BONDI_VOLUME_MISSING "
let unchecked_prefix = "BONDI_VOLUME_UNCHECKED "
let done_marker = "BONDI_VOLUME_CHECK_DONE"

(* The login user's test first, then root's, which is how the daemon will ask.
   [sudo -n] never waits on a password. When it is refused, root was not asked,
   so a path the login user cannot see is reported unchecked and not missing:
   a check that could not ask is never read as an answer. Its complaint goes to
   /dev/null so a refusal leaves no line behind. *)
let path_test host =
  let quoted = Filename.quote host in
  let report prefix =
    Printf.sprintf "printf '%%s%%s\\n' %s %s" (Filename.quote prefix) quoted
  in
  Printf.sprintf
    "[ -e %s ] || { sudo -n true 2>/dev/null && { sudo -n test -e %s \
     2>/dev/null || %s; }; } || %s"
    quoted quoted (report missing_prefix) (report unchecked_prefix)

let command mounts =
  let tests =
    List.map
      (fun mount -> path_test (Bondi_common.Bind_mount.host mount))
      mounts
  in
  String.concat "; "
    (tests @ [ Printf.sprintf "printf '%%s\\n' %s" done_marker; "exit 0" ])

let shown output =
  Bondi_common.String_utils.bounded ~limit:256
    (Bondi_common.String_utils.single_line output)

let unrecognised output =
  Unreadable
    (Printf.sprintf
       "the host-path check answered in a shape this client does not read: %S"
       (shown output))

type line = Missing_line of string | Unchecked_line of string

let path_after ~prefix line =
  let start = String.length prefix in
  String.sub line start (String.length line - start)

let read_line line =
  match
    ( Bondi_common.String_utils.starts_with ~prefix:missing_prefix line,
      Bondi_common.String_utils.starts_with ~prefix:unchecked_prefix line )
  with
  | true, _ -> Some (Missing_line (path_after ~prefix:missing_prefix line))
  | false, true ->
      Some (Unchecked_line (path_after ~prefix:unchecked_prefix line))
  | false, false -> None

(* The lines ahead of the marker arrive last-first, so consing them back gives
   the declared order. One line that is not the command's makes the whole
   answer one this module does not read. *)
let command_lines lines_last_first =
  List.fold_left
    (fun lines line ->
      match (lines, read_line line) with
      | None, (None | Some _) -> None
      | Some _, None -> None
      | Some lines, Some read -> Some (read :: lines))
    (Some []) lines_last_first

let unchecked_reason paths =
  Unreadable
    (Printf.sprintf "%s could not be checked as root (sudo -n refused)"
       (String.concat ", " (List.map (Printf.sprintf "%S") paths)))

let of_lines lines =
  let unchecked =
    List.filter_map
      (function
        | Unchecked_line path -> Some path
        | Missing_line _ -> None)
      lines
  in
  let missing =
    List.filter_map
      (function
        | Missing_line path -> Some path
        | Unchecked_line _ -> None)
      lines
  in
  match (unchecked, missing) with
  | _ :: _, _ -> unchecked_reason unchecked
  | [], [] -> All_present
  | [], _ :: _ -> Missing missing

(* The answer is the path lines, then the marker on a line of its own, then the
   newline that ends it. Anything else -- no marker, a marker that is not last,
   a line before it that is not the command's -- is not its whole answer. *)
let read_answer output =
  match List.rev (String.split_on_char '\n' output) with
  | "" :: marker :: lines_last_first when String.equal marker done_marker -> (
      match command_lines lines_last_first with
      | Some lines -> of_lines lines
      | None -> unrecognised output)
  | _ -> unrecognised output

let verdict = function
  | Ok output -> read_answer output
  | Error failure ->
      Unreadable (Remote_exec.explain ~subject:"the host-path check" failure)

let refusal = function
  | All_present -> Ok ()
  | Missing paths ->
      Error
        (Printf.sprintf
           "the service mounts host paths that do not exist on the server: %s. \
            Bondi does not create them: create each one, owned by the user the \
            container runs as, then deploy again."
           (String.concat ", " (List.map (Printf.sprintf "%S") paths)))
  | Unreadable reason ->
      Error
        (Printf.sprintf
           "the host paths the service mounts could not be checked, and a \
            deploy is not sent to a server whose paths have not been seen: %s"
           reason)

let refusal_for ~check volumes =
  match volumes with
  | None
  | Some [] ->
      Ok ()
  | Some (_ :: _ as mounts) -> refusal (verdict (check (command mounts)))
