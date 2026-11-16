type reading = Present | Absent | Undetermined of string

let journal_path = Alloy_run_args.journal_path
let present_marker = "BONDI_JOURNAL_PRESENT"
let absent_marker = "BONDI_JOURNAL_ABSENT"
let no_machine_id_marker = "BONDI_JOURNAL_NO_MACHINE_ID"

(* A missing or empty /etc/machine-id would leave the test asking about the bare
   directory, which is exactly the check this probe exists to be stricter than,
   so it has its own marker rather than reading as absent. The test's own
   status is kept apart from sudo's: [test] writes nothing, so anything on
   standard error is [sudo] failing (a password it cannot ask for), and that is
   printed as it came, which is no marker and so reads as undetermined. *)
let probe_command =
  Printf.sprintf
    "id=$(cat /etc/machine-id 2>/dev/null); if [ -z \"$id\" ]; then echo %s; \
     else err=$(sudo test -d %s/\"$id\" 2>&1); rc=$?; if [ $rc -eq 0 ]; then \
     echo %s; elif [ -z \"$err\" ]; then echo %s; else echo \"$err\"; fi; fi"
    no_machine_id_marker
    (Filename.quote journal_path)
    present_marker absent_marker

let reading_of_probe = function
  | Error message -> Undetermined message
  | Ok output ->
      let said = String.trim output in
      if said = present_marker then Present
      else if said = absent_marker then Absent
      else if said = no_machine_id_marker then
        Undetermined "the host has no readable /etc/machine-id"
      else
        Undetermined
          (Printf.sprintf "the host answered without saying which: %s" said)

type plan = Nothing_to_do | Provision_then_recheck of string list

(* [systemd-tmpfiles] applies the ownership and mode journald's own tmpfiles
   rules give the directory, so a directory made by [mkdir] alone is not left
   at root's umask. The restart is what moves the journal: journald decides
   where it stores only when it starts. *)
let provisioning_commands =
  [
    Printf.sprintf "sudo mkdir -p %s" (Filename.quote journal_path);
    Printf.sprintf "sudo systemd-tmpfiles --create --prefix %s"
      (Filename.quote journal_path);
    "sudo systemctl restart systemd-journald";
  ]

let plan = function
  | Present -> Ok Nothing_to_do
  | Absent -> Ok (Provision_then_recheck provisioning_commands)
  | Undetermined message ->
      Error
        (Printf.sprintf
           "could not read whether journald stores its journal under %s, so \
            setup will not change how it stores it: %s"
           journal_path message)

let recheck = function
  | Present -> Ok ()
  | Absent ->
      Error
        (Printf.sprintf
           "journald still stores nothing under %s for this machine after \
            setup created the directory and restarted it. Alloy reads cron \
            jobs' lines from that journal, so setup will not start an Alloy \
            that reads nothing. Check Storage= in /etc/systemd/journald.conf \
            and its drop-ins: volatile and none keep the journal out of %s. \
            Set it to persistent or auto, then run bondi setup again."
           journal_path journal_path)
  | Undetermined message ->
      Error
        (Printf.sprintf
           "could not read whether journald stores its journal under %s after \
            setup provisioned it, so setup will not start Alloy against it: %s"
           journal_path message)
