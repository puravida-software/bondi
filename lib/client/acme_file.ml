(* The probe always exits 0 and says which answer it found on standard output,
   leaving the exit status to mean "the command could be run on that host": a
   non-zero [test -f] is also what a dropped connection looks like, so the
   host's answer and the failure to get one used to be the same value.

   A file that is there is reported with its owner and mode, on the marker's own
   line, so a run can tell a file already at what Bondi declares from one it has
   to change. *)
let present_marker = "BONDI_ACME_PRESENT"
let absent_marker = "BONDI_ACME_ABSENT"

(* What Bondi declares for the file: Traefik refuses an acme.json any other user
   can read. Written as the probe prints it, owner then mode. *)
let declared_owner = "root:root"
let declared_mode = "600"
let declared = declared_owner ^ " " ^ declared_mode

(* Run under sudo like the writes: as the login user an unsearchable parent
   makes [test -f] false for a file that exists. Absent is printed only when
   [test ! -e] positively agrees, so a path that is there but is not a regular
   file, and a sudo that could not run, print nothing and read as undetermined
   (a failed classifier does not get a neighbour's class). *)
let probe_command ~path =
  let quoted = Filename.quote path in
  Printf.sprintf
    "if sudo test -f %s; then echo \"%s $(sudo stat -c '%%U:%%G %%a' %s)\"; \
     elif sudo test ! -e %s; then echo %s; fi"
    quoted present_marker quoted quoted absent_marker

type state =
  | As_declared
  | Differs of { observed : Host_answer.t }
  | Absent
  | Undetermined of string

(* One line of the probe's answer, parsed once. *)
type marker = Present_with of string | Present_bare | Absent_line | Other

let marker_of_line line =
  let present_prefix = present_marker ^ " " in
  if String.equal line absent_marker then Absent_line
  else if String.equal line present_marker then Present_bare
  else if Bondi_common.String_utils.starts_with ~prefix:present_prefix line then
    let from = String.length present_prefix in
    Present_with
      (String.trim (String.sub line from (String.length line - from)))
  else Other

let state_of_probe ~expected = function
  | Error message -> Undetermined message
  | Ok output -> (
      let markers =
        List.map
          (fun line -> marker_of_line (String.trim line))
          (String.split_on_char '\n' output)
      in
      if List.mem Absent_line markers then Absent
      else
        match
          List.find_map
            (function
              | Present_with reading -> Some reading
              | Present_bare -> Some ""
              | Absent_line
              | Other ->
                  None)
            markers
        with
        | Some "" ->
            Undetermined
              "the host said the file is there without its owner and mode"
        | Some reading ->
            if String.equal reading expected then As_declared
            else Differs { observed = Host_answer.of_host_output reading }
        | None ->
            Undetermined
              (Printf.sprintf "the host answered without saying which: %s"
                 (String.trim output)))

let permissions_command ~path =
  let quoted = Filename.quote path in
  Printf.sprintf "sudo chown %s %s && sudo chmod %s %s" declared_owner quoted
    declared_mode quoted

let create_command ~path =
  Printf.sprintf "sudo mkdir -p %s && sudo touch %s && %s"
    (Filename.quote (Filename.dirname path))
    (Filename.quote path)
    (permissions_command ~path)

type course =
  | Keep
  | Correct of { command : string; found : Host_answer.t }
  | Create of { command : string }
  | Refuse of string

let course ~path = function
  | As_declared -> Keep
  | Differs { observed } ->
      Correct { command = permissions_command ~path; found = observed }
  | Absent -> Create { command = create_command ~path }
  | Undetermined message ->
      Refuse
        (Printf.sprintf
           "could not read whether %s exists, or its owner and mode, on the \
            server, so setup will not act on it: %s"
           path message)

let confirmed ~path ~server = function
  | As_declared -> Ok ()
  | Differs { observed } ->
      Error
        (Printf.sprintf
           "%s on server %s is still %s after asking for %s -- refusing to \
            report success on a posture that was not applied"
           path server
           (Host_answer.to_string observed)
           declared)
  | Absent ->
      Error
        (Printf.sprintf
           "%s on server %s is not there after setting it to %s -- refusing to \
            report success on a posture that was not applied"
           path server declared)
  | Undetermined message ->
      Error
        (Printf.sprintf
           "could not read back the owner and mode of %s on server %s after \
            setting %s, so whether they were applied is unknown: %s"
           path server declared message)

let confirmation ~path ~server ~found state =
  Result.map
    (fun () -> Setup_phases.acme_permissions_corrected ~found ~applied:declared)
    (confirmed ~path ~server state)
