let cron_root = "/etc/bondi/cron"

let run_file_of name =
  Filename.concat (Filename.concat cron_root name) "run.json"

let exec_marker = "bondi-server run < "

(* The path in a generated line, recovered and then re-derived. The name is the
   directory the run file sits in, and the line is accepted only when
   run_file_of rebuilds the very string the line carried: the path the reader
   opens is then the path the line named, by construction, and a hand-edited
   line naming ../../somewhere cannot be followed.

   The name rule is Managed_container's, which is also the rule the writer
   checks a name against before it creates the job's directory -- so a name this
   accepts is a name some job could have been deployed under. *)
let job_name_of line =
  match String_utils.index_of ~needle:exec_marker line with
  | None -> None
  | Some at -> (
      let from = at + String.length exec_marker in
      match String.index_from_opt line from '\'' with
      | None -> None
      | Some until ->
          let path = String.sub line from (until - from) in
          let name = Filename.basename (Filename.dirname path) in
          if
            Managed_container.is_valid_name name
            && String.equal path (run_file_of name)
          then Some name
          else None)
