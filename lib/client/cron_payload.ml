type listing =
  | Payloads of { files : string list }
  | Root_absent
  | Unlisted of string

type shortfall = Env_file_missing | Run_file_missing | Both_files_missing

type divergence =
  | Job_missing_files of { job : string; shortfall : shortfall }
  | Files_without_a_line of { job : string; unnamed_entries : int list }

(* The directory, the two file paths and the container they are copied out of
   are Bondi_common.Cron_exec_line's, so the paths looked for here and the paths
   the orchestrator writes are one spelling, and the container asked for its
   files is the one the crontab line execs into. A client that named these
   itself could report every job on a correct host as having lost its files, and
   would go on doing so until somebody read both libraries side by side. *)
let root = Bondi_common.Cron_exec_line.cron_root
let container = Bondi_common.Builtin_container.orchestrator

(* Only meaningful for a name the writer would accept, which is what the section
   reader hands over: a name is taken from a run file's path and the path is
   rebuilt from it, so a name that reaches here is one some job could have been
   deployed under. *)
let env_file_of = Bondi_common.Cron_exec_line.env_file_of
let run_file_of = Bondi_common.Cron_exec_line.run_file_of
let is_valid_name = Bondi_common.Managed_container.is_valid_name

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

(* The marker that closes what [listed_marker] opened, and the listing's own
   success is what prints it. The guard only asks whether the directory can be
   opened, so a [find] that then fails -- refused by the same sudoers rule that
   permitted the [test], killed part-way through, or stopped on something it
   could not descend -- would print the opening marker and part of the
   directory, and the command ends [exit 0] so that the host's answer survives
   the ssh layer. Printed as a statement of its own the marker would run
   whatever the listing did, and say the paths had ended whether they had or
   not.

   Joined to the listing, it is emitted only when [find] exited 0, and the
   trailing [exit 0] still carries the answer out. What it attests is the
   listing having run to its end and the stream having arrived whole -- a [find]
   that failed and a connection cut mid-transfer both leave it unprinted. What
   it cannot attest is a path whose own bytes spell it, which is
   [paths_complete]'s half.

   This is the crontab reader's protocol and not a second one invented here. The
   two commands are read into one comparison, and a guard on one side only makes
   a reported disagreement real in one direction. *)
let end_of_listing_marker = "BONDI_CRON_PAYLOAD_END"
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
   apart from the directory genuinely being absent.

   The guard therefore asks whether the directory can be opened and not merely
   whether it is there. A directory that stops being listable between the guard
   and the listing is a [find] that exits non-zero, and the closing marker is
   joined to that exit rather than printed after it, so what such a listing
   hands back is paths with nothing closing them and not a directory read as far
   as the listing got. *)
let listing_command =
  let quoted_root = Filename.quote root in
  Printf.sprintf
    "if sudo -n test -d %s 2>/dev/null; then echo %s; sudo -n find %s \
     -mindepth 2 -maxdepth 2 -type f 2>/dev/null && echo %s; elif sudo -n true \
     2>/dev/null; then echo %s; else echo %s; fi; exit 0"
    quoted_root listed_marker quoted_root end_of_listing_marker absent_marker
    unreadable_marker

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

(* Paths the closing marker closes are the whole directory; paths it does not
   are as much of the directory as the listing got to.

   The marker is looked for as its own line at the end, newline and all. A path
   is a name the host wrote and the word is a word like any other, so a bare
   suffix cannot tell the command's marker from the tail of the last path a
   dying listing delivered: a listing cut on a file called
   "run-BONDI_CRON_PAYLOAD_END" would pass as one that finished, and the cut
   that removes the marker would take the end of that path with it. With the
   newline in the match, only a line that is the marker and nothing else can
   close the listing.

   A directory listed and found empty prints the marker with no path ahead of
   it, and that is the one case the newline is not there to require: it is a
   complete listing of a directory holding nothing, which is an answer.

   A truncated listing is not a smaller directory, and the difference is the one
   the caller acts on. Every job below the cut would otherwise be a job whose
   files the host no longer holds, which is reported as a job that fails at its
   next fire -- a disagreement invented out of a listing that never finished. *)
let paths_complete contents =
  let trimmed = String.trim contents in
  let closing_line = "\n" ^ end_of_listing_marker in
  if String.equal trimmed end_of_listing_marker then Some ""
  else if String.ends_with ~suffix:closing_line trimmed then
    Some
      (String.sub trimmed 0
         (String.length trimmed - String.length closing_line))
  else None

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
      | Some contents -> (
          match paths_complete contents with
          | Some complete -> Payloads { files = files_of_contents complete }
          | None ->
              Unlisted
                "the listing of the directory its cron jobs keep their files \
                 in stopped before the end, so which of them still have theirs \
                 is unknown")
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

(* Every job the section names reads its two files out of this directory, so
   every one of them is answered from the listing and from nothing else. *)
let shortfalls_of ~jobs listing =
  List.filter_map
    (fun job ->
      match listing with
      (* A read that failed is not the host's answer. Naming every job here
         would be a report about files nobody looked at, and it would arrive on
         exactly the runs where the operator has least reason to doubt it. *)
      | Unlisted _ -> None
      | Root_absent -> Some (job, Both_files_missing)
      | Payloads { files } ->
          Option.map
            (fun shortfall -> (job, shortfall))
            (shortfall_of ~files job))
    jobs

(* The job a listed path belongs to, or none. The name is the directory the file
   sits in, and the path is then rebuilt from it and compared whole -- the same
   rebuild-and-compare the line's own reader does, and for the same reason: what
   is reported is a name some job could have been deployed under, and never a
   fragment of whatever the host happened to have in that directory.

   Nothing here opens the file. A path is a job's name and one of two fixed file
   names, and the name is what this module exists to report. A path that is
   neither of a job's two files answers for no job rather than becoming one, so
   a stray file under the payload root cannot invent a cron job to report. *)
let job_of_path path =
  let name = Filename.basename (Filename.dirname path) in
  if
    is_valid_name name
    && (String.equal path (run_file_of name)
       || String.equal path (env_file_of name))
  then Some name
  else None

(* The other direction: a job whose files are on the box and whose line the
   section does not hold. It never fires, and no deploy repairs it -- the
   configuration stopped declaring it, so nothing writes its line back.

   Sorted rather than left in the order the host printed them, because that
   order is the filesystem's and is not stable between hosts or between runs,
   and these lines are read by an operator and pinned by the command tests.
   [sort_uniq] is also what folds a job's two files into one name. *)
let jobs_without_a_line ~named files =
  files
  |> List.filter_map job_of_path
  |> List.sort_uniq String.compare
  |> List.filter (fun job -> not (List.exists (String.equal job) named))

(* The positions of the entries the section holds that no reader could name.

   Empty is a section read whole, and it is the only state that supports a claim
   that nothing on the host fires a job: every line was read and none of them
   named it. A section nobody read is not this state and never reaches here --
   it yields no divergence in either direction -- so the two are never
   conflated, which is the distinction the whole comparison rests on. *)
let unnamed_positions crontab =
  match crontab with
  | Crontab_listing.Section { entries } ->
      List.filter_map
        (fun entry ->
          match entry with
          | Crontab_listing.Named _ -> None
          | Crontab_listing.Unnamed { position } -> Some position)
        entries
  | Crontab_listing.No_section
  | Crontab_listing.Malformed _
  | Crontab_listing.Unreadable _ ->
      []

(* Both directions, in one answer, from the two sources and from nothing else.

   [jobs] absent is the section nobody read, and it yields nothing at all. The
   first direction has no name to ask about, and the second would report every
   job on the box as having no line firing it on the strength of a section that
   was never delivered -- the same claim about a source nobody looked at that
   [Unlisted] is refused above.

   The two listings that report nothing in the second direction report nothing
   for different reasons, and only one of them is a refusal. [Unlisted] is the
   read that never happened. [Root_absent] is the host answering, and it holds
   no file whose line could be missing -- every job it covers is named by the
   first direction instead. *)
let divergences ~crontab listing =
  match Crontab_listing.jobs_read crontab with
  | None -> []
  | Some named ->
      (* One list, read off the section once and shared by every job it hedges.
         The positions are a fact about the section and not about any job, so a
         host with three orphans asks the same question of the same section
         three times for three copies of one answer. *)
      let unnamed_entries = unnamed_positions crontab in
      List.map
        (fun (job, shortfall) -> Job_missing_files { job; shortfall })
        (shortfalls_of ~jobs:named listing)
      @ List.map
          (fun job -> Files_without_a_line { job; unnamed_entries })
          (match listing with
          | Unlisted _
          | Root_absent ->
              []
          | Payloads { files } -> jobs_without_a_line ~named files)

(* One sentence per outcome, each saying what the operator is left with rather
   than what the file did. They live here and not in the interpreter that prints
   them because they are the whole of what the operator receives, and an arm
   building its own has nowhere to assert them. *)
let sentence_of_shortfall ~server ~job shortfall =
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

(* The positions, as an operator reads them. Written from a first and a rest so
   there is no empty case to word: the caller reaches this only where there is
   at least one position to name. *)
let rec numbers_phrase first rest =
  match rest with
  | [] -> string_of_int first
  | [ last ] -> Printf.sprintf "%d and %d" first last
  | next :: more -> Printf.sprintf "%d, %s" first (numbers_phrase next more)

(* Files on the box that no line the reader could name fires -- and what may be
   said about that depends entirely on whether the section was read whole.

   Read whole, the claim is total and stays unhedged: every line was read, none
   of them fires this job, so the job never runs and the operator's move is to
   declare it again. Holding an entry nobody could name, the same claim is not
   available at all. That entry fires on its schedule like any other line, and
   it may be the very one that fires this job -- a host part-way through the
   migration off the shape an older bondi wrote is exactly that host, with its
   legacy line still firing and its files still there. So the sentence says what
   is actually known, and carries the position the operator opens the file at.

   Which is the same discipline the rest of this module keeps for a source that
   was never read: a claim is made about what a read said, and never about what
   a read that did not happen would have said. *)
let sentence_of_orphan ~server ~job unnamed_entries =
  match unnamed_entries with
  | [] ->
      Printf.sprintf
        "cron job %s on server %s keeps its files on the box and no crontab \
         line fires them, so it never runs until it is declared again"
        job server
  | first :: rest ->
      Printf.sprintf
        "cron job %s on server %s keeps its files on the box and no crontab \
         line that could be read fires them: %s %s of the section could not be \
         read, and an entry nobody could read may be the line that fires it"
        job server
        (match rest with
        | [] -> "entry"
        | _ :: _ -> "entries")
        (numbers_phrase first rest)

let sentence_of ~server divergence =
  match divergence with
  | Job_missing_files { job; shortfall } ->
      sentence_of_shortfall ~server ~job shortfall
  | Files_without_a_line { job; unnamed_entries } ->
      sentence_of_orphan ~server ~job unnamed_entries

(* Said out loud, because silence on either source would read as the two
   agreeing -- every job holding its files, under a section that names them. A
   directory the host says is not there gets no such line: that is the host
   answering rather than failing to, and every job it covers is named below on
   its own.

   Both reads failing is one sentence and not two. A host that refuses a
   privileged read refuses both of them for the one reason, and the operator has
   already been given that reason by the crontab cell these lines sit under;
   three sentences for one cause is the same fact three times over, with its
   account carried twice. Either source failing on its own keeps a sentence of
   its own, because a section read against a directory that was not -- and the
   reverse -- are different facts about the host and send an operator to
   different places.

   The section's half carries no account of why. That read is not this module's:
   the caller's own crontab reporting says what went wrong, and this line says
   what is consequently not known here. So the account the one sentence carries
   is the listing's, and it is attached to the clause that names the listing. *)
let unread_sentences ~server ~jobs listing =
  match (jobs, listing) with
  | None, Unlisted message ->
      [
        Printf.sprintf
          "which cron jobs on server %s are scheduled to run could not be \
           read, and neither could which of them still hold their files: %s"
          server message;
      ]
  | None, (Root_absent | Payloads _) ->
      [
        Printf.sprintf
          "which cron jobs on server %s are scheduled to run could not be \
           read, so whether the files on the box still have a line firing them \
           is unknown"
          server;
      ]
  | Some _, Unlisted message ->
      [
        Printf.sprintf
          "which cron jobs on server %s still hold their files could not be \
           read: %s"
          server message;
      ]
  | Some _, (Root_absent | Payloads _) -> []

let report ~server ~crontab listing =
  unread_sentences ~server ~jobs:(Crontab_listing.jobs_read crontab) listing
  @ List.map (sentence_of ~server) (divergences ~crontab listing)
