type t =
  | Absent
  | Not_running
  | Running of { image : string; spec_hash : string option }
  | Undetermined of string

let command ~name =
  Printf.sprintf
    "ps -a --filter name=^/%s$ --format '{{.State}}\t{{.Image}}\t{{.Label \
     \"%s\"}}'"
    name Builtin_spec.label

let spec_hash_of_column column =
  match String.trim column with
  | "" -> None
  | hash -> Some hash

(* The line is split before anything is trimmed. A container without the label
   prints an empty last column after a tab, and trimming the line first removes
   that tab and leaves two columns. Each column is trimmed on its own instead,
   which also takes off a carriage return a remote shell left on the last one. *)
let of_line line =
  match String.split_on_char '\t' line with
  | [ state; image; label ] -> (
      match String.trim state with
      | "running" ->
          Running
            { image = String.trim image; spec_hash = spec_hash_of_column label }
      (* "created", "restarting", "paused", "exited", "removing" and "dead". *)
      | _ -> Not_running)
  | []
  | [ _ ]
  | [ _; _ ]
  | _ :: _ :: _ :: _ :: _ ->
      Undetermined
        (Printf.sprintf
           "could not decode the container listing line %S: expected three \
            tab-separated columns"
           line)

let of_ps_output output =
  match
    output
    |> String.split_on_char '\n'
    |> List.find_opt (fun line -> String.trim line <> "")
  with
  | None -> Absent
  | Some line -> of_line line

let of_probe = function
  | Ok output -> of_ps_output output
  | Error err -> Undetermined err
