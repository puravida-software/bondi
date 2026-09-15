let is_executable_file path =
  match Unix.stat path with
  | { Unix.st_kind = Unix.S_REG; _ } -> (
      match Unix.access path [ Unix.X_OK ] with
      | () -> true
      | exception Unix.Unix_error _ -> false)
  | {
   Unix.st_kind =
     ( Unix.S_DIR | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO
     | Unix.S_SOCK );
   _;
  } ->
      false
  | exception Unix.Unix_error _ -> false

let found_on_path program =
  if String.contains program '/' then is_executable_file program
  else
    Option.value (Sys.getenv_opt "PATH") ~default:""
    |> String.split_on_char ':'
    |> List.exists (fun directory ->
        is_executable_file
          (Filename.concat
             (if directory = "" then Filename.current_dir_name else directory)
             program))
