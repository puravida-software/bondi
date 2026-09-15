open Alcotest
module Program = Bondi_client.Program

(* --- Real entries, not a stub ---

   Every case here builds on the filesystem the thing it asks about. What the
   module answers is a question only the kernel can answer -- a name that is a
   directory, a symlink whose target is gone, a file whose execute bit is clear
   -- and there is no seam between it and [Unix.stat] where a substitute could
   go. Each case builds what it needs under a directory of its own and removes
   it on every path out, so nothing one case leaves behind is visible to the
   next. *)

let name = "bondi-program-fixture"

let rec remove_entry path =
  match Unix.lstat path with
  | { Unix.st_kind = Unix.S_DIR; _ } ->
      Array.iter
        (fun entry -> remove_entry (Filename.concat path entry))
        (Sys.readdir path);
      Unix.rmdir path
  | {
   Unix.st_kind =
     ( Unix.S_REG | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO
     | Unix.S_SOCK );
   _;
  } ->
      Unix.unlink path
  | exception Unix.Unix_error _ -> ()

let with_temp_dir f =
  let dir = Filename.temp_dir "bondi-program-" "" in
  Fun.protect ~finally:(fun () -> remove_entry dir) (fun () -> f dir)

(* The current directory is process-wide, so it is restored on every path out.
   A case that left it moved would be asking about its own directory in every
   later case in this executable, and the two cases that move it are the two
   whose answer depends on where it points. *)
let with_current_directory dir f =
  let previous = Sys.getcwd () in
  Unix.chdir dir;
  Fun.protect ~finally:(fun () -> Unix.chdir previous) f

let write_file ~mode directory entry =
  let path = Filename.concat directory entry in
  let channel = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr channel)
    (fun () -> output_string channel "#!/bin/sh\nexit 0\n");
  Unix.chmod path mode;
  path

let an_executable_on_path_is_found () =
  with_temp_dir (fun dir ->
      let (_ : string) = write_file ~mode:0o755 dir name in
      Client_fixtures.with_path dir (fun () ->
          check bool "an executable file in the one entry of PATH" true
            (Program.found_on_path name)))

(* The other arm of the same collapse. Without it the case above passes against
   a lookup that answers [true] to everything. *)
let a_name_that_is_nowhere_on_path_is_not_found () =
  with_temp_dir (fun dir ->
      Client_fixtures.with_path dir (fun () ->
          check bool "nothing of that name in the one entry of PATH" false
            (Program.found_on_path name)))

let each_entry_of_path_is_searched_in_turn () =
  with_temp_dir (fun dir ->
      let first = Filename.concat dir "first" in
      let second = Filename.concat dir "second" in
      Unix.mkdir first 0o755;
      Unix.mkdir second 0o755;
      let (_ : string) = write_file ~mode:0o755 second name in
      Client_fixtures.with_path
        (first ^ ":" ^ second)
        (fun () ->
          check bool "found in the second entry, the first holding nothing" true
            (Program.found_on_path name)))

let an_empty_path_entry_means_the_current_directory () =
  with_temp_dir (fun dir ->
      let (_ : string) = write_file ~mode:0o755 dir name in
      let absent = Filename.concat dir "absent" in
      with_current_directory dir (fun () ->
          Client_fixtures.with_path (absent ^ ":") (fun () ->
              check bool "the trailing empty entry is the current directory"
                true
                (Program.found_on_path name));
          Client_fixtures.with_path absent (fun () ->
              check bool
                "and the same PATH without it does not reach the current \
                 directory"
                false
                (Program.found_on_path name))))

let a_name_containing_a_slash_is_asked_about_directly () =
  with_temp_dir (fun dir ->
      let path = write_file ~mode:0o755 dir name in
      let elsewhere = Filename.concat dir "elsewhere" in
      Unix.mkdir elsewhere 0o755;
      Client_fixtures.with_path elsewhere (fun () ->
          check bool
            "a path is asked about where it points, not where PATH does" true
            (Program.found_on_path path));
      (* The directory holding the executable is on PATH throughout, so a
         lookup that searched PATH for a name with a slash in it would find
         [dir/./name] and answer [true]. *)
      with_current_directory elsewhere (fun () ->
          Client_fixtures.with_path dir (fun () ->
              check bool "and a path naming nothing is not then sought on PATH"
                false
                (Program.found_on_path
                   (Filename.concat Filename.current_dir_name name)))))

let a_directory_of_the_right_name_is_not_a_program () =
  with_temp_dir (fun dir ->
      Unix.mkdir (Filename.concat dir name) 0o755;
      Client_fixtures.with_path dir (fun () ->
          check bool "a directory bearing the name, execute bits and all" false
            (Program.found_on_path name)))

let a_file_without_the_execute_bit_is_not_a_program () =
  with_temp_dir (fun dir ->
      let (_ : string) = write_file ~mode:0o644 dir name in
      Client_fixtures.with_path dir (fun () ->
          check bool "a readable regular file this process may not execute"
            false
            (Program.found_on_path name)))

let a_dangling_symlink_is_not_a_program () =
  with_temp_dir (fun dir ->
      Unix.symlink (Filename.concat dir "gone") (Filename.concat dir name);
      Client_fixtures.with_path dir (fun () ->
          check bool "a symlink whose target is not there" false
            (Program.found_on_path name)))

(* What the word "dangling" in the contract is there to distinguish: the
   question is asked of what a link points at, so a link that points at an
   executable is one. *)
let a_symlink_to_an_executable_is_a_program () =
  with_temp_dir (fun dir ->
      let target = write_file ~mode:0o755 dir "bondi-program-target" in
      Unix.symlink target (Filename.concat dir name);
      Client_fixtures.with_path dir (fun () ->
          check bool "a symlink resolving to an executable regular file" true
            (Program.found_on_path name)))

let () =
  run "Program"
    [
      ( "searching PATH",
        [
          test_case "an executable on PATH is found" `Quick
            an_executable_on_path_is_found;
          test_case "a name that is nowhere on PATH is not found" `Quick
            a_name_that_is_nowhere_on_path_is_not_found;
          test_case "each entry of PATH is searched in turn" `Quick
            each_entry_of_path_is_searched_in_turn;
          test_case "an empty entry means the current directory" `Quick
            an_empty_path_entry_means_the_current_directory;
          test_case "a name containing a slash is asked about directly" `Quick
            a_name_containing_a_slash_is_asked_about_directly;
        ] );
      ( "what counts as a program",
        [
          test_case "a directory of the right name is not a program" `Quick
            a_directory_of_the_right_name_is_not_a_program;
          test_case "a file without the execute bit is not a program" `Quick
            a_file_without_the_execute_bit_is_not_a_program;
          test_case "a dangling symlink is not a program" `Quick
            a_dangling_symlink_is_not_a_program;
          test_case "a symlink to an executable is a program" `Quick
            a_symlink_to_an_executable_is_a_program;
        ] );
    ]
