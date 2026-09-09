type listing =
  | Payloads of { files : string list }
  | Root_absent
  | Unlisted of string

type shortfall =
  | Env_file_missing
  | Run_file_missing
  | Both_files_missing
  | Payload_on_the_line

(* The directory and the two file paths are Bondi_common.Cron_exec_line's, so
   the paths looked for here and the paths the orchestrator writes are one
   spelling. A client that named these itself could report every job on a
   correct host as having lost its files, and would go on doing so until
   somebody read both libraries side by side. *)
let root = Bondi_common.Cron_exec_line.cron_root
let container = "bondi-orchestrator"

(* Only meaningful for a name the writer would accept, which is what the section
   reader hands over: a name is taken from a run file's path and the path is
   rebuilt from it, so a name that reaches here is one some job could have been
   deployed under. *)
let env_file_of = Bondi_common.Cron_exec_line.env_file_of
let run_file_of = Bondi_common.Cron_exec_line.run_file_of

(* The mode the writer of the files creates the directory at, taken from the
   writer's own module rather than spelled here: the .mli says the host
   directory is created at the mode the writer uses, and through a second
   spelling that sentence would be true only for as long as nobody changed
   either one. *)
let root_mode = Printf.sprintf "%o" Bondi_common.Cron_exec_line.cron_root_mode

(* A directory that is not there and a directory the host would not let this
   read are separated on standard output rather than by an exit status, which is
   the channel a dropped connection arrives on as well. Reading a refusal as an
   absence would name every job on the host as having lost both files, on the
   strength of a read that never happened. *)
let listed_marker = "BONDI_CRON_PAYLOAD_LISTED"
let absent_marker = "BONDI_CRON_PAYLOAD_ABSENT"
let unreadable_marker = "BONDI_CRON_PAYLOAD_UNREADABLE"

(* The whole directory, in one copy, named once. A loop over the jobs would put
   each job's name into a command line on both machines for no gain: the files
   are the same files and they move together.

   [-a] keeps the ownership the writer gave them, and the destination is created
   at the mode the writer creates it at, because a copy landing in a directory
   the world can traverse would undo the point of files that are mode 600.

   The copy is skipped on a host that already bind-mounts the directory into the
   container, and that guard is not an optimisation. There the container reads
   and this writes the same files at the same time, and [docker cp] streams: the
   extraction truncates a file the archiver has not finished reading, so a run
   file that was never in danger comes back short. That host is also the one
   with nothing to rescue -- the mount is what makes its files outlive the
   container -- so the case where the copy could corrupt something is exactly
   the case where it has nothing to do.

   The container is asked whether it holds that mount, rather than the host
   directory being asked whether it holds anything. They are not the same
   question and the cheap one answers wrong in the direction that never
   recovers: an extraction cut part-way -- a dropped connection, a reboot --
   leaves the directory non-empty and incomplete, and a guard reading "non-empty
   means the copy already happened" then skips it on every later run, for good,
   until somebody deletes a directory on the box by hand. What the guard needs
   to know is whether this directory is the container's own view of itself, and
   [docker inspect] is the one thing that knows.

   Every failure is swallowed, including the whole command's: it exits 0
   whatever happened. A container that never held the directory is a job whose
   files were lost before this run began, which the listing reports rather than
   this refusing. More to the point, the copy is planned for a crontab that
   could not be read, and a crontab that could not be read is a host whose
   [sudo -n] is refused -- so a non-zero exit here would abort setup precisely on
   the hosts this was written to protect, on every run, for good. What still
   reaches the caller's error channel is the call never reaching the host at
   all. *)
let preserve_command =
  let quoted_root = Filename.quote root in
  Printf.sprintf
    "sudo -n mkdir -p %s && sudo -n chmod %s %s && { sudo -n docker inspect -f \
     '{{range .Mounts}}{{println .Destination}}{{end}}' %s | grep -Fxq %s || \
     sudo -n docker cp -a %s %s || true; }; exit 0"
    quoted_root root_mode quoted_root container quoted_root
    (Filename.quote (container ^ ":" ^ root ^ "/."))
    quoted_root

(* Two levels down and files only: a job's directory holds its files and nothing
   below them, so anything deeper is not a file any job's line reads.

   The read is privileged because the write is: mode 600 in a 0700 directory
   owned by root, so an unprivileged guard answers "not there" for a directory
   that is plainly there. The [sudo -n true] arm is what tells that refusal
   apart from the directory genuinely being absent. *)
let listing_command =
  let quoted_root = Filename.quote root in
  Printf.sprintf
    "if sudo -n test -d %s 2>/dev/null; then echo %s; sudo -n find %s \
     -mindepth 2 -maxdepth 2 -type f 2>/dev/null; elif sudo -n true \
     2>/dev/null; then echo %s; else echo %s; fi; exit 0"
    quoted_root listed_marker quoted_root absent_marker unreadable_marker

let said marker output =
  Bondi_common.String_utils.contains ~needle:marker output

(* Everything after the marker is the listing. It is answered before the other
   two markers for the same reason the crontab reader answers its contents
   marker first: a path is free to hold any word, and a job directory named
   after one of these would otherwise decide the outcome. *)
let paths_after_marker output =
  match Bondi_common.String_utils.index_of ~needle:listed_marker output with
  | None -> None
  | Some index ->
      let start = index + String.length listed_marker in
      Some (String.sub output start (String.length output - start))

let files_of_contents contents =
  contents
  |> String.split_on_char '\n'
  |> List.map String.trim
  |> List.filter (fun path -> not (String.equal path ""))

let of_listing_output reading =
  match reading with
  | Error failure ->
      Unlisted (Remote_exec.explain ~subject:"the listing" failure)
  | Ok output -> (
      match paths_after_marker output with
      | Some contents -> Payloads { files = files_of_contents contents }
      | None -> (
          match (said unreadable_marker output, said absent_marker output) with
          | true, _ ->
              Unlisted
                "the host could not read the directory its cron jobs keep \
                 their files in, so which of them still have theirs is unknown"
          | false, true -> Root_absent
          | false, false ->
              Unlisted
                "the host answered without saying whether it could list the \
                 directory its cron jobs keep their files in"))

(* The paths are compared whole rather than by their last segment: a file the
   host reported from anywhere else under the directory answers for no job, so a
   stray [env] two directories over cannot stand in for a job's own. *)
let shortfall_of ~files job =
  let holds path = List.exists (String.equal path) files in
  match (holds (env_file_of job), holds (run_file_of job)) with
  | true, true -> None
  | false, true -> Some Env_file_missing
  | true, false -> Some Run_file_missing
  | false, false -> Some Both_files_missing

(* The shape a job's name was read from decides whether the directory is asked
   about it at all. A legacy line carries the whole payload, so the job it names
   holds neither file on every host and on none of them has it lost one --
   answering it from the listing would report every unmigrated job on the box as
   failing at its next fire, which on the boxes this phase exists for is most of
   them and is the sentence an operator pages on. It is still answered, because
   a legacy line still on the box is worth saying, and it is answered whatever
   the listing did: what makes it legacy came from the crontab, not from here. *)
let shortfalls ~jobs listing =
  List.filter_map
    (fun (named : Crontab_listing.named_job) ->
      match named.shape with
      | Crontab_listing.Legacy_line -> Some (named.job, Payload_on_the_line)
      | Crontab_listing.Exec_line -> (
          match listing with
          (* A read that failed is not the host's answer. Naming every job here
             would be a report about files nobody looked at, and it would arrive
             on exactly the runs where the operator has least reason to doubt
             it. *)
          | Unlisted _ -> None
          | Root_absent -> Some (named.job, Both_files_missing)
          | Payloads { files } ->
              Option.map
                (fun shortfall -> (named.job, shortfall))
                (shortfall_of ~files named.job)))
    jobs

(* One sentence per outcome, each saying what the operator is left with rather
   than what the file did. They live here and not in the interpreter that prints
   them because they are the whole of what the operator receives, and an arm
   building its own has nowhere to assert them. *)
let sentence_of ~server ~job shortfall =
  match shortfall with
  | Env_file_missing ->
      Printf.sprintf
        "cron job %s on server %s has no secret environment file on the box, \
         so it runs with an empty one until it is deployed again"
        job server
  | Run_file_missing ->
      Printf.sprintf
        "cron job %s on server %s has no run file on the box, so it fails at \
         its next fire until it is deployed again"
        job server
  | Both_files_missing ->
      Printf.sprintf
        "cron job %s on server %s has neither its run file nor its secret \
         environment file on the box, so it fails at its next fire until it is \
         deployed again"
        job server
  | Payload_on_the_line ->
      Printf.sprintf
        "cron job %s on server %s still runs from its legacy crontab line, \
         which carries its payload rather than reading files, so it has lost \
         nothing: deploy it again to move it onto a run file"
        job server

(* Said out loud, because silence here would otherwise read as every job holding
   its files. A directory the host says is not there gets no such line: that is
   the host answering rather than failing to, and every job it covers is named
   below on its own. *)
let unread_sentence ~server listing =
  match listing with
  | Unlisted message ->
      Some
        (Printf.sprintf
           "which cron jobs on server %s still hold their files could not be \
            read: %s"
           server message)
  | Root_absent
  | Payloads _ ->
      None

let report ~server ~jobs listing =
  Option.to_list (unread_sentence ~server listing)
  @ List.map
      (fun (job, shortfall) -> sentence_of ~server ~job shortfall)
      (shortfalls ~jobs listing)
