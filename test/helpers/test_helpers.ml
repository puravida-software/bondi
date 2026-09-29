let contains ~needle hay = Bondi_common.String_utils.contains ~needle hay

(* Padding both ends turns "at either end of the value" into the same case as
   "between two spaces", so the search itself has one shape rather than three. *)
let contains_word ~word hay =
  let padded = " " ^ Bondi_common.String_utils.single_line hay ^ " " in
  contains ~needle:(" " ^ word ^ " ") padded

(* The line is built from the writer's own marker and the writer's own run-file
   path, never spelled out: a reader that stopped recognising the shape the
   orchestrator writes would otherwise leave a test naming jobs the box could
   not name. Two suites read the same shape, so it is written once -- two copies
   of the writer's line is the hazard both copies cited as their own reason for
   existing. *)
let exec_line job =
  Printf.sprintf "0 3 * * * docker exec -i bondi-orchestrator sh -c '%s%s'"
    Bondi_common.Cron_exec_line.exec_marker
    (Bondi_common.Cron_exec_line.run_file_of job)

let bind_mount ~host ~container ~read_only =
  match Bondi_common.Bind_mount.create ~host ~container ~read_only with
  | Ok mount -> mount
  | Error e -> Alcotest.fail (Bondi_common.Bind_mount.error_to_string e)

let mount_fields mount =
  Bondi_common.Bind_mount.(host mount, container mount, read_only mount)

let rec remove_tree path =
  (* lstat, not is_directory: a symlink to a directory must be unlinked, never
     descended into, or the cleanup escapes its root. *)
  match (Unix.lstat path).st_kind with
  | Unix.S_DIR ->
      Array.iter
        (fun entry -> remove_tree (Filename.concat path entry))
        (Sys.readdir path);
      Sys.rmdir path
  | _ -> Sys.remove path

let with_temp_dir prefix f =
  let dir = Filename.temp_dir prefix "" in
  Fun.protect ~finally:(fun () -> remove_tree dir) (fun () -> f dir)
