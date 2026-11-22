let label = Bondi_common.Managed_container.spec_hash_label

(* Each input is written with %S, which escapes quotes and newlines, and ends
   its own line. No byte inside an input can then close it early or open the
   next one. It is the shape the managed containers' digest input has. *)
let canonical ~run_command ~files =
  String.concat ""
    (Printf.sprintf "run_command=%S\n" run_command
    :: List.map (fun file -> Printf.sprintf "file=%S\n" file) files)

let hash ~run_command ~files =
  Digest.to_hex (Digest.string (canonical ~run_command ~files))

(* The hash is a run of hex digits, which no shell reads specially. *)
let label_flag digest = Printf.sprintf " --label %s=%s" label digest

let matches ~expected = function
  | Some recorded -> String.equal recorded expected
  | None -> false
