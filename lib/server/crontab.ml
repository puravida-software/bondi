(* Crontab management for Bondi cron jobs.
   Writes to root's crontab at /var/spool/cron/crontabs/root.
   Job specs are inlined in the curl -d argument. *)

open Ppx_yojson_conv_lib.Yojson_conv
open Json_helpers

let ( let* ) = Result.bind
let crontab_path = "/var/spool/cron/crontabs/root"
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

let strip_bondi_section lines =
  let rec loop in_bondi acc = function
    | [] -> List.rev acc
    | line :: rest ->
        if line = bondi_begin_marker then loop true acc rest
        else if line = bondi_end_marker then loop false acc rest
        else if in_bondi then loop true acc rest
        else loop false (line :: acc) rest
  in
  loop false [] lines

let string_of_lines lines = String.concat "\n" lines ^ "\n"

let generate_bondi_entries cron_jobs =
  let entry (c : Strategy.Simple.cron_job) =
    let payload = run_payload_of_cron_job c in
    let json_str = yojson_of_run_payload payload |> Yojson.Safe.to_string in
    let escaped = escape_for_shell json_str in
    (* Use full path to curl: cron runs with minimal PATH and may not find curl *)
    Printf.sprintf
      "%s /usr/bin/curl -s -X POST http://localhost:3030/api/v1/run -H \
       \"Content-Type: application/json\" -d '%s'"
      c.schedule escaped
  in
  (bondi_begin_marker :: List.map entry cron_jobs) @ [ bondi_end_marker ]

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

(* Upsert crontab with the given cron jobs. If None or empty, remove Bondi section only. *)
let upsert (cron_jobs : Strategy.Simple.cron_job list option) :
    (unit, string) result =
  let* current = read_crontab () in
  let lines = String.split_on_char '\n' current in
  let stripped = strip_bondi_section lines in
  let trimmed =
    stripped |> List.map String.trim |> List.filter (fun l -> l <> "")
  in
  let new_lines =
    match cron_jobs with
    | Some jobs when jobs <> [] -> trimmed @ generate_bondi_entries jobs
    | _ -> trimmed
  in
  let contents = string_of_lines new_lines in
  let* () = write_crontab contents in
  chmod crontab_path 0o600
