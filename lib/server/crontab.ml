(* Crontab management for Bondi cron jobs.
   Writes to root's crontab at /var/spool/cron/crontabs/root.
   Job specs are inlined in the curl -d argument. *)

open Ppx_yojson_conv_lib.Yojson_conv
open Json_helpers

let ( let* ) = Result.bind
let crontab_path = "/var/spool/cron/crontabs/root"
let crontab_spool_dir = "/var/spool/cron/crontabs"
let bondi_begin_marker = "# BEGIN BONDI CRON"
let bondi_end_marker = "# END BONDI CRON"

(* Run payload sent to /run endpoint *)
type run_payload = {
  job : string;
  image : string;
  env_vars : string_map option;
}
[@@deriving yojson]

let run_payload_of_cron_job (c : Strategy.Simple.cron_job) : run_payload =
  { job = c.name; image = c.image; env_vars = c.env_vars }

(* Escape single quotes for shell: ' -> '\'' *)
let escape_for_shell s = String.concat "'\\''" (String.split_on_char '\'' s)

let read_crontab () : (string, string) result =
  try
    let ic = open_in crontab_path in
    let contents = really_input_string ic (in_channel_length ic) in
    close_in ic;
    Ok contents
  with
  | Sys_error _ -> Ok ""
  | exn -> Error (Printexc.to_string exn)

(* Extract job name from a Bondi cron line by parsing the JSON in -d '...' *)
let job_name_from_cron_line line =
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
          else Some i (* Escaped quote '\'' *)
        else find_end (i + 1)
      in
      match find_end start with
      | None -> None
      | Some end_idx -> (
          try
            let json_str = String.sub line start (end_idx - start) in
            let json = Yojson.Safe.from_string json_str in
            match json with
            | `Assoc assoc -> (
                match List.assoc_opt "job" assoc with
                | Some (`String name) -> Some name
                | _ -> None)
            | _ -> None
          with
          | _ -> None))

(* Extract Bondi cron lines (between markers) and parse job name from each.
   Returns (lines_outside_bondi, (job_name, full_line) list for bondi entries). *)
let parse_bondi_section lines =
  let rec loop in_bondi outside bondi_entries = function
    | [] -> (List.rev outside, List.rev bondi_entries)
    | line :: rest ->
        if line = bondi_begin_marker then loop true outside bondi_entries rest
        else if line = bondi_end_marker then
          loop false outside bondi_entries rest
        else if in_bondi then
          match job_name_from_cron_line line with
          | Some name -> loop true outside ((name, line) :: bondi_entries) rest
          | None -> loop true outside bondi_entries rest
        else loop false (line :: outside) bondi_entries rest
  in
  loop false [] [] lines

let string_of_lines lines = String.concat "\n" lines ^ "\n"

let entry_of_cron_job (c : Strategy.Simple.cron_job) =
  let payload = run_payload_of_cron_job c in
  let json_str = yojson_of_run_payload payload |> Yojson.Safe.to_string in
  let escaped = escape_for_shell json_str in
  Printf.sprintf
    "%s /usr/bin/curl -s -X POST http://localhost:3030/api/v1/run -H \
     \"Content-Type: application/json\" -d '%s'"
    c.schedule escaped

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

(* Merge deploy jobs into existing Bondi section. Add or replace per job name;
   jobs not in the deploy are left unchanged. If None or empty, remove Bondi section. *)
let upsert (cron_jobs : Strategy.Simple.cron_job list option) :
    (unit, string) result =
  let* current = read_crontab () in
  let lines = String.split_on_char '\n' current in
  let outside, existing_bondi = parse_bondi_section lines in
  let trimmed =
    outside |> List.map String.trim |> List.filter (fun l -> l <> "")
  in
  let new_lines =
    match cron_jobs with
    | None
    | Some [] ->
        trimmed
    | Some jobs ->
        (* Map: job_name -> cron line. Start with existing entries. *)
        let by_name = Hashtbl.create 16 in
        List.iter
          (fun (name, line) -> Hashtbl.replace by_name name line)
          existing_bondi;
        (* Add or replace with deploy jobs. *)
        List.iter
          (fun (c : Strategy.Simple.cron_job) ->
            Hashtbl.replace by_name c.name (entry_of_cron_job c))
          jobs;
        (* Output order: existing order first (updated if deployed), then new jobs. *)
        let existing_names = List.map fst existing_bondi in
        let deployed_names =
          List.map (fun (c : Strategy.Simple.cron_job) -> c.name) jobs
        in
        let new_names =
          List.filter (fun n -> not (List.mem n existing_names)) deployed_names
        in
        let ordered_names = existing_names @ new_names in
        let bondi_lines =
          List.map (fun n -> Hashtbl.find by_name n) ordered_names
        in
        trimmed @ (bondi_begin_marker :: bondi_lines) @ [ bondi_end_marker ]
  in
  let contents = string_of_lines new_lines in
  let* () = write_crontab contents in
  let* () = chmod crontab_path 0o600 in
  touch_spool_dir ()
