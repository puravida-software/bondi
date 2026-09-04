open Alcotest
module Setup = Bondi_client.Cmd.Setup

let contains ~needle s = Bondi_common.String_utils.contains ~needle s
let index_of ~needle s = Bondi_common.String_utils.index_of ~needle s

(* The River config file's mode used to be whatever umask the remote login shell
   happened to carry. That is not a decision anyone made, and it is why one box
   sat at 0644 while another sat narrowed by hand out of band. These tests pin
   the command Bondi sends and what Bondi does with the answer -- what the
   operating system then does with that command is the operating system. *)

(* The declared value is spelled out here rather than read through the constant.
   Through the constant this arm passes for whatever value the constant takes,
   which is the same nothing the umask gave. *)
let test_write_command_carries_the_declared_mode () =
  check string "the declared mode" "0640" Setup.alloy_config_declared_mode;
  let cmd = Setup.alloy_config_write_command ~mode:"0640" in
  check bool "applies the declared mode" true
    (contains ~needle:"chmod 0640" cmd);
  (* The mode must reach the command. One mode alone passes against a body that
     ignores its argument and spells 0640 inline. *)
  let narrower = Setup.alloy_config_write_command ~mode:"0600" in
  check bool "carries the mode it was given" true
    (contains ~needle:"chmod 0600" narrower);
  check bool "and no other" false (contains ~needle:"0640" narrower)

(* Measured 2026-09-03 on Linux 7.2.1 with GNU bash 5.3.15 and coreutils 9.11: a
   file already at 0644, written by `sh -c 'umask 027; cat > f'`, is left at
   0644. A redirect onto an existing file consults no umask, because it creates
   no file. Removing it first is also what stops the write from following a
   symlink planted at the path, which the trailing chmod would then apply to the
   symlink's target rather than to Bondi's file. *)
let test_write_command_creates_the_file_rather_than_truncating_it () =
  let cmd = Setup.alloy_config_write_command ~mode:"0640" in
  (match (index_of ~needle:"rm -f" cmd, index_of ~needle:"cat >" cmd) with
  | Some removal, Some redirect ->
      check bool "removes the old file before writing the new one" true
        (removal < redirect)
  | None, _ -> fail "the command must remove the file before writing it"
  | Some _, None -> fail "the command must write the file");
  (* The affirmative arm, on the same command: the contents still arrive over
     standard input, the file is still the one named, and the mode still lands.
     Without these the ordering above passes against a command that stopped
     writing anything at all. *)
  check bool "takes the contents from standard input" true
    (contains ~needle:"cat >" cmd);
  check bool "writes the River config file" true
    (contains ~needle:"/etc/bondi/alloy/config.alloy" cmd);
  check bool "creates the directory that holds it" true
    (contains ~needle:"mkdir -p" cmd);
  check bool "applies the declared mode" true
    (contains ~needle:"chmod 0640" cmd)

(* `sh -c "a; b"` exits with b's status, so a write chained with `;` reports
   whatever the trailing chmod reported. chmod succeeds on a file that cat
   created and then failed to fill -- and the runner deliberately swallows its
   own write failure on the recorded grounds that the exit status reports it.
   Measured 2026-09-03 with GNU coreutils 9.11 and dash 0.5.12:

     $ printf 'PART' | sh -c "rm -f f; cat > f; chmod 0640 f"; echo $?
     0
     $ stat -c '%04a %s' f
     0640 4

   A connection dropped mid-transfer therefore leaves a truncated file, exit 0,
   and a mode read-back that passes because the mode really was applied. `&&`
   makes the status the first failure's. What the shell then does with the
   operator is the shell's; what these arms pin is that a later edit cannot put
   `;` back. *)
let test_write_command_reports_a_step_that_failed () =
  let cmd = Setup.alloy_config_write_command ~mode:"0640" in
  check bool "chains the steps so a failure is reported" true
    (contains ~needle:"&&" cmd);
  check bool "and with no separator that discards it" false
    (contains ~needle:";" cmd)

(* An unreadable file and a dropped connection must not arrive on the same
   channel. `stat` on a missing file exits non-zero, which is the channel a
   transport failure uses, so the probe answers on standard output and always
   exits zero -- the separation acme_probe_command already draws. The marker is
   spelled out rather than read through the constant so that the probe and the
   verdict are pinned to the same wire word by the test rather than by sharing a
   let-binding. *)
let test_mode_probe_answers_when_the_file_cannot_be_read () =
  let cmd = Setup.alloy_config_mode_command in
  check bool "reads the applied mode at the declared width" true
    (contains ~needle:"stat -c %04a" cmd);
  check bool "names the River config file" true
    (contains ~needle:"/etc/bondi/alloy/config.alloy" cmd);
  check bool "keeps the failure off the exit status" true
    (contains ~needle:"|| echo BONDI_ALLOY_MODE_UNREADABLE" cmd);
  check bool "keeps the failure off standard output" true
    (contains ~needle:"2>/dev/null" cmd)

let test_declared_mode_is_applied () =
  match Setup.alloy_config_mode_of_probe ~expected:"0640" "0640\n" with
  | Setup.Alloy_mode_applied -> ()
  | Setup.Alloy_mode_differs { observed } ->
      failf "the declared mode must satisfy the check, got %s" observed
  | Setup.Alloy_mode_unreadable _ ->
      fail "a host that reported 0640 was read as unreadable"

(* 0644 is the mode the old bare redirect left on the box the feature was
   written from, so this is the arm that reddens against today's behaviour. *)
let test_different_mode_reports_what_was_observed () =
  match Setup.alloy_config_mode_of_probe ~expected:"0640" "0644\n" with
  | Setup.Alloy_mode_differs { observed } ->
      check string "reports what the host applied" "0644" observed
  | Setup.Alloy_mode_applied -> fail "0644 must not satisfy a 0640 expectation"
  | Setup.Alloy_mode_unreadable _ ->
      fail "a host that reported 0644 was read as unreadable"

(* A host's answer is free text and arrives on however many lines the host
   chose -- a sudo warning ahead of the reading, a shell that says something of
   its own. Interpolated raw, the tail of it lands in the middle of whatever
   sentence the caller builds around it. The verdict hands out one line so that
   no caller has to remember to. *)
let test_observed_mode_arrives_on_one_line () =
  match
    Setup.alloy_config_mode_of_probe ~expected:"0640"
      "sudo: unable to resolve host\n0644\n"
  with
  | Setup.Alloy_mode_differs { observed } ->
      check string "collapses the host's answer onto one line"
        "sudo: unable to resolve host 0644" observed
  | Setup.Alloy_mode_applied ->
      fail "a host that did not report 0640 must not read as agreement"
  | Setup.Alloy_mode_unreadable _ -> fail "a host that reported a mode was read"

(* Nothing read is not a mode. A file the host could not stat, an ssh stub with
   no arm for the command and a command whose output never arrived all produce
   one of these, and none of them is agreement -- nor is any of them a
   difference, because there is nothing to compare against. Reporting one as a
   wrong mode is a lie about the host; reading one as a match is the
   silent-success this estate keeps finding. *)
let test_unreadable_probe_is_not_a_difference_and_not_a_match () =
  let unreadable label output =
    match Setup.alloy_config_mode_of_probe ~expected:"0640" output with
    | Setup.Alloy_mode_unreadable reason -> reason
    | Setup.Alloy_mode_applied -> failf "%s must never read as agreement" label
    | Setup.Alloy_mode_differs { observed } ->
        failf "%s must not be reported as a mode the host applied (%s)" label
          observed
  in
  (* A host that answered the marker did answer, and what it answered is carried
     so that the message quotes the host rather than paraphrasing it. *)
  (match
     unreadable "a host that could not read the file"
       "BONDI_ALLOY_MODE_UNREADABLE\n"
   with
  | Setup.Alloy_mode_read_refused { observed } ->
      check string "carries what the host answered"
        "BONDI_ALLOY_MODE_UNREADABLE" observed
  | Setup.Alloy_mode_not_reported ->
      fail "a host that answered the marker did answer");
  (* Nothing read is a different thing from a read the host refused: there is no
     answer to quote, so the verdict says so by its shape rather than by handing
     the caller a stand-in string the caller might print as the host's words. *)
  let not_reported label output =
    match unreadable label output with
    | Setup.Alloy_mode_not_reported -> ()
    | Setup.Alloy_mode_read_refused { observed } ->
        failf "%s is not an answer the host gave, got %s" label observed
  in
  not_reported "empty output" "";
  not_reported "whitespace-only output" "  \n";
  (* The affirmative arm, on the same function: it still recognises a real
     answer. Without it the three rejections above pass against a verdict that
     has stopped recognising anything. *)
  match Setup.alloy_config_mode_of_probe ~expected:"0640" "0640\n" with
  | Setup.Alloy_mode_applied -> ()
  | Setup.Alloy_mode_differs { observed } ->
      failf "the declared mode must still be recognised, got %s" observed
  | Setup.Alloy_mode_unreadable _ ->
      fail "the declared mode must still be recognised"

(* The credentials file gets the same treatment as the config file, from a
   builder of its own rather than a Printf inside the interpreter: the mode it
   declares and the mode a read-back would compare against have to be one value,
   and a command built where nothing can call it is a command nothing can pin.
   The declared value is spelled out here rather than read through the constant
   for the reason the config arm gives -- through the constant this passes for
   whatever value the constant takes, including the `600` it used to be, which
   no `stat -c %04a` read-back could ever equal. *)
let test_env_write_command_carries_the_declared_mode () =
  check string "the declared mode" "0600" Setup.alloy_env_declared_mode;
  let cmd = Setup.alloy_env_write_command ~mode:"0600" in
  check bool "applies the declared mode" true
    (contains ~needle:"chmod 0600" cmd);
  (* The mode must reach the command. One mode alone passes against a body that
     ignores its argument and spells 0600 inline. *)
  let wider = Setup.alloy_env_write_command ~mode:"0640" in
  check bool "carries the mode it was given" true
    (contains ~needle:"chmod 0640" wider);
  check bool "and no other" false (contains ~needle:"0600" wider)

(* The same property the config write is pinned on, on the file where the diff's
   own comment says it is load-bearing twice over: a redirect onto an existing
   file creates nothing and so consults no umask, which on a credentials file is
   the difference between 0600 and whatever a previous hand left; and removing
   first is what stops the write from following a symlink planted at the path,
   which the trailing chmod would otherwise apply to the symlink's target. *)
let test_env_write_command_creates_the_file_rather_than_truncating_it () =
  let cmd = Setup.alloy_env_write_command ~mode:"0600" in
  (match (index_of ~needle:"rm -f" cmd, index_of ~needle:"cat >" cmd) with
  | Some removal, Some redirect ->
      check bool "removes the old file before writing the new one" true
        (removal < redirect)
  | None, _ -> fail "the command must remove the file before writing it"
  | Some _, None -> fail "the command must write the file");
  (* The affirmative arms, on the same command. Without them the ordering above
     passes against a command that stopped writing anything at all. *)
  check bool "takes the contents from standard input" true
    (contains ~needle:"cat >" cmd);
  check bool "narrows the window between creation and the chmod" true
    (contains ~needle:"umask 077" cmd);
  check bool "writes the credentials file" true
    (contains ~needle:"/etc/bondi/alloy/env" cmd);
  check bool "creates the directory that holds it" true
    (contains ~needle:"mkdir -p" cmd);
  (* The file the credentials are written to must be the file everything else
     names. A builder pointing at a path the run command does not read is a
     sidecar that starts and ships nothing, and neither half fails on its own. *)
  check bool "at the path the run command reads them from" true
    (contains ~needle:Setup.alloy_env_path cmd)

(* The credentials write is the one a discarded failure reaches: a truncated
   GRAFANA_CLOUD_API_KEY makes Alloy start, report itself healthy and ship
   nothing, which is the silent success this feature exists to remove. *)
let test_env_write_command_reports_a_step_that_failed () =
  let cmd = Setup.alloy_env_write_command ~mode:"0600" in
  check bool "chains the steps so a failure is reported" true
    (contains ~needle:"&&" cmd);
  check bool "and with no separator that discards it" false
    (contains ~needle:";" cmd)

(* Withdrawing alloy takes its files off the host, and the credentials file has
   no removal action of its own: it is carried off because it sits inside the
   directory this command deletes. The directory is read through the constant
   here, which is the opposite of what the mode arms above do -- what has to
   hold is not that the path is spelled /etc/bondi/alloy but that it is the same
   path the writes create their files under. *)
let test_remove_config_command_deletes_the_directory_the_writes_use () =
  let cmd = Setup.alloy_remove_config_command in
  check bool "removes the config directory recursively" true
    (contains ~needle:("rm -rf " ^ Filename.quote Setup.alloy_config_dir) cmd);
  (* The affirmative arm, on the other side of the tie: the credentials write
     really does put its file under that directory. Either half on its own
     passes against a pair that has stopped agreeing, which is a withdrawn
     credential left on the host. *)
  check bool "the directory the credentials are written under" true
    (contains
       ~needle:(Setup.alloy_config_dir ^ "/")
       (Setup.alloy_env_write_command ~mode:"0600"))

(* The Grafana Cloud credentials used to be interpolated into the `docker run`
   that starts the sidecar. That put them in the ssh command line on the client
   and in the process listing on the host, and those are the two copies these
   arms are about: they travel to their own file on standard input now, and the
   run command names the file instead.

   `docker inspect` is not one of the two, and this test does not claim it. The
   Docker CLI expands --env-file on the client into the container's environment
   before the create call, so the Engine holds the key either way -- as does the
   file itself, to anything with root on the box. What these arms pin is the
   command line, which is the whole of what a run command can decide.

   Both variables move, not only the key. The generated River config reads both
   through sys.env, so leaving the instance id behind would split one contract
   across two mechanisms for no gain -- and would leave a reader of the run
   command believing the credentials are still supplied there. *)
let test_run_command_carries_no_credential () =
  let cmd = Setup.alloy_run_command ~image:"grafana/alloy:v1.8.0" in
  check bool "does not carry the api key variable" false
    (contains ~needle:"GRAFANA_CLOUD_API_KEY" cmd);
  check bool "does not carry the instance id variable" false
    (contains ~needle:"GRAFANA_CLOUD_INSTANCE_ID" cmd);
  check bool "passes no environment variable at all" false
    (contains ~needle:" -e " cmd);
  (* The affirmative arms, on the same command. Without them the three absences
     above pass against a builder that returned the empty string, or one that
     stopped producing a run command. *)
  check bool "still runs the alloy container" true
    (contains ~needle:"docker run -d --name bondi-alloy" cmd);
  check bool "still declares a restart policy" true
    (contains ~needle:"--restart unless-stopped" cmd);
  check bool "still mounts the River config it was given" true
    (contains ~needle:"/etc/bondi/alloy/config.alloy:ro" cmd);
  check bool "still runs the image it was handed" true
    (contains ~needle:"grafana/alloy:v1.8.0" cmd);
  (* The image must reach the command. One image alone passes against a body
     that ignores its argument and spells a default inline. *)
  let other = Setup.alloy_run_command ~image:"grafana/alloy:v1.9.2" in
  check bool "runs the image it was handed and no other" true
    (contains ~needle:"grafana/alloy:v1.9.2" other);
  check bool "and no other" false (contains ~needle:"v1.8.0" other)

(* The affirmative half of the absence above, on the same command: the container
   still gets its credentials, by the intended route. An absence with no arm
   like this passes just as well against a sidecar that starts with no
   credentials at all and ships nothing.

   The path is spelled out rather than read through [alloy_env_path]: through the
   constant this arm passes for whatever value the constant takes, including one
   that no longer matches the file the write command creates. The check against
   the constant below is the separate claim that the two agree today. *)
let test_run_command_references_the_env_file () =
  let cmd = Setup.alloy_run_command ~image:"grafana/alloy:v1.8.0" in
  check bool "reads the credentials out of a file" true
    (contains ~needle:"--env-file /etc/bondi/alloy/env" cmd);
  (* The file it names must be the file the credentials were written to. A run
     command pointing at a path nothing wrote is a container that starts and
     ships nothing, and neither half fails on its own. *)
  check string "and that file is the one the credentials are written to"
    "/etc/bondi/alloy/env" Setup.alloy_env_path

(* The image is the only value in this command that comes out of bondi.yaml, so
   it is the only one that can end the `docker run` and start something else.
   orchestrator_run_command quotes its own token for this reason; this command
   was carried over from an inline Printf that quoted nothing. *)
let test_run_command_quotes_the_image () =
  let cmd = Setup.alloy_run_command ~image:"grafana/alloy:v1.8.0" in
  check bool "quotes the image it was handed" true
    (contains ~needle:"'grafana/alloy:v1.8.0'" cmd);
  (* Why it matters, spelled out rather than built from Filename.quote so the
     arm pins a shape instead of restating the implementation: a quote inside
     the image is escaped rather than closing the argument early. *)
  let awkward = Setup.alloy_run_command ~image:"alloy'v1" in
  check bool "and escapes a quote inside one" true
    (contains ~needle:"'alloy'\\''v1'" awkward)

let () =
  run "alloy commands"
    [
      ( "config write command",
        [
          test_case "carries the declared mode" `Quick
            test_write_command_carries_the_declared_mode;
          test_case "creates rather than truncates" `Quick
            test_write_command_creates_the_file_rather_than_truncating_it;
          test_case "reports a step that failed" `Quick
            test_write_command_reports_a_step_that_failed;
        ] );
      ( "credentials write command",
        [
          test_case "carries the declared mode" `Quick
            test_env_write_command_carries_the_declared_mode;
          test_case "creates rather than truncates" `Quick
            test_env_write_command_creates_the_file_rather_than_truncating_it;
          test_case "reports a step that failed" `Quick
            test_env_write_command_reports_a_step_that_failed;
        ] );
      ( "config removal command",
        [
          test_case "deletes the directory the writes use" `Quick
            test_remove_config_command_deletes_the_directory_the_writes_use;
        ] );
      ( "config mode",
        [
          test_case "probe answers on an unreadable file" `Quick
            test_mode_probe_answers_when_the_file_cannot_be_read;
          test_case "declared mode is applied" `Quick
            test_declared_mode_is_applied;
          test_case "different mode reports what was observed" `Quick
            test_different_mode_reports_what_was_observed;
          test_case "observed mode arrives on one line" `Quick
            test_observed_mode_arrives_on_one_line;
          test_case "unreadable is neither a difference nor a match" `Quick
            test_unreadable_probe_is_not_a_difference_and_not_a_match;
        ] );
      ( "run command",
        [
          test_case "carries no credential" `Quick
            test_run_command_carries_no_credential;
          test_case "references the env file" `Quick
            test_run_command_references_the_env_file;
          test_case "quotes the image" `Quick test_run_command_quotes_the_image;
        ] );
    ]
