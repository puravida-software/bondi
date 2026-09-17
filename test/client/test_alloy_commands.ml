open Alcotest
module Setup = Bondi_client.Cmd.Setup
module Setup_phases = Bondi_client.Setup_phases
module Host_answer = Bondi_client.Host_answer

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
      failf "the declared mode must satisfy the check, got %s"
        (Host_answer.to_string observed)
  | Setup.Alloy_mode_unreadable _ ->
      fail "a host that reported 0640 was read as unreadable"

(* 0644 is the mode the old bare redirect left on the box the feature was
   written from, so this is the arm that reddens against today's behaviour. *)
let test_different_mode_reports_what_was_observed () =
  match Setup.alloy_config_mode_of_probe ~expected:"0640" "0644\n" with
  | Setup.Alloy_mode_differs { observed } ->
      check string "reports what the host applied" "0644"
        (Host_answer.to_string observed)
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
        "sudo: unable to resolve host 0644"
        (Host_answer.to_string observed)
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
          (Host_answer.to_string observed)
  in
  (* A host that answered the marker did answer, and what it answered is carried
     so that the message quotes the host rather than paraphrasing it. *)
  (match
     unreadable "a host that could not read the file"
       "BONDI_ALLOY_MODE_UNREADABLE\n"
   with
  | Setup.Alloy_mode_read_refused { observed } ->
      check string "carries what the host answered"
        "BONDI_ALLOY_MODE_UNREADABLE"
        (Host_answer.to_string observed)
  | Setup.Alloy_mode_not_reported ->
      fail "a host that answered the marker did answer");
  (* Nothing read is a different thing from a read the host refused: there is no
     answer to quote, so the verdict says so by its shape rather than by handing
     the caller a stand-in string the caller might print as the host's words. *)
  let not_reported label output =
    match unreadable label output with
    | Setup.Alloy_mode_not_reported -> ()
    | Setup.Alloy_mode_read_refused { observed } ->
        failf "%s is not an answer the host gave, got %s" label
          (Host_answer.to_string observed)
  in
  not_reported "empty output" "";
  not_reported "whitespace-only output" "  \n";
  (* The affirmative arm, on the same function: it still recognises a real
     answer. Without it the three rejections above pass against a verdict that
     has stopped recognising anything. *)
  match Setup.alloy_config_mode_of_probe ~expected:"0640" "0640\n" with
  | Setup.Alloy_mode_applied -> ()
  | Setup.Alloy_mode_differs { observed } ->
      failf "the declared mode must still be recognised, got %s"
        (Host_answer.to_string observed)
  | Setup.Alloy_mode_unreadable _ ->
      fail "the declared mode must still be recognised"

(* The reading taken before the write is the whole of what lets a run say what it
   found. After the write the file exists at the mode just asked for, so the
   read-back above can only ever agree, and the mode the host had is already
   gone. A reading taken before the write has a fourth answer the read-back has
   no use for -- the file is not there yet -- and that answer must not arrive as
   the value an unreadable file arrives as. A first setup on a box with no
   /etc/bondi/alloy and a setup on a box whose stat was refused are opposite
   facts: one is a creation, the other is a run that cannot say whether it
   converged.

   The command and the verdict are pinned in one case deliberately. The verdict's
   absent arm is reachable only if some command actually emits the marker, so the
   arm asserted on its own stays green against a pre-write command that can never
   produce it.

   The absence is a constructor of this reading's own type and of no other. The
   read-back's type has three arms, so the file-is-not-there answer is not
   something it can be handed and not something a caller can write an arm for:
   an arm for a state its own probe cannot reach is an arm no test reaches and no
   operator ever reads. *)
let test_alloy_config_mode_before_the_write () =
  let cmd = Setup.alloy_config_pre_write_mode_command in
  check bool "reads the mode at the declared width" true
    (contains ~needle:"stat -c %04a" cmd);
  check bool "names the River config file" true
    (contains ~needle:"/etc/bondi/alloy/config.alloy" cmd);
  (* The needles carry the `echo ` in front of the marker, not the marker alone.
     A marker the shell runs as one word with the command that should have
     printed it is a probe whose absent answer never reaches standard output, and
     the marker on its own is present in that command too. *)
  check bool "says so when the file is not there" true
    (contains ~needle:"else echo BONDI_ALLOY_MODE_ABSENT" cmd);
  check bool "says so when the file cannot be read" true
    (contains ~needle:"|| echo BONDI_ALLOY_MODE_UNREADABLE" cmd);
  check bool "keeps the failure off standard output" true
    (contains ~needle:"2>/dev/null" cmd);
  (* Rendered to a label so that every constructor is named by an exhaustive
     match here, on both types: a catch-all would let the next answer either of
     them learns pass as one of these four. The absence is a constructor of the
     pre-write reading alone -- the read-back's type has no such arm, which is
     what stops an arm being written for an answer its own probe cannot
     produce. *)
  let reading output =
    match
      Setup.alloy_config_pre_write_mode_of_probe ~expected:"0640" output
    with
    | Setup.Alloy_pre_write_absent -> "absent"
    | Setup.Alloy_pre_write_read Setup.Alloy_mode_applied -> "applied"
    | Setup.Alloy_pre_write_read (Setup.Alloy_mode_differs { observed }) ->
        "differs: " ^ Host_answer.to_string observed
    | Setup.Alloy_pre_write_read
        (Setup.Alloy_mode_unreadable Setup.Alloy_mode_not_reported) ->
        "unreadable: nothing reported"
    | Setup.Alloy_pre_write_read
        (Setup.Alloy_mode_unreadable
           (Setup.Alloy_mode_read_refused { observed })) ->
        "unreadable: " ^ Host_answer.to_string observed
  in
  (* The affirmative arm the three rejections below need: the same function on
     the same expectation still recognises a host that already agrees, so a
     verdict that had stopped recognising anything would not pass here. *)
  check string "a host already at the declared mode has nothing to correct"
    "applied" (reading "0640\n");
  (* 0644 is the mode the old bare redirect left on the box this was written
     from, and reporting it is the incident the account exists for. *)
  check string "a host at another mode is what a correction names"
    "differs: 0644" (reading "0644\n");
  check string "a file that is not there yet is a creation, not a correction"
    "absent"
    (reading "BONDI_ALLOY_MODE_ABSENT\n");
  check string "a file the host could not stat is neither of those"
    "unreadable: BONDI_ALLOY_MODE_UNREADABLE"
    (reading "BONDI_ALLOY_MODE_UNREADABLE\n");
  check string "a host that said nothing has no answer to quote"
    "unreadable: nothing reported" (reading "")

(* Two commands now ask one host about one file, and a host -- or a cram stub
   standing in for one -- has to be able to answer them differently: the whole
   point of the earlier reading is that it reports a mode the read-back will not
   see. Collapsed into one answer, a fixture written to show a mode being
   corrected has the host reporting the same mode before and after the write,
   which is the failure path and not a correction -- so the fixture would pass
   while asserting the opposite of what it says.

   Differing somewhere is therefore not enough; they have to differ where
   something selects on them. Each command carries a string the other does not,
   and the read-back keeps the one the existing stubs already match. *)
let test_the_two_mode_commands_are_not_the_same_string () =
  let pre_write = Setup.alloy_config_pre_write_mode_command in
  let read_back = Setup.alloy_config_mode_command in
  check bool "the two readings are not one command" true (pre_write <> read_back);
  check bool "only the earlier reading can report an absent file" true
    (contains ~needle:"BONDI_ALLOY_MODE_ABSENT" pre_write
    && not (contains ~needle:"BONDI_ALLOY_MODE_ABSENT" read_back));
  check bool "the read-back is the sudo stat a stub already selects on" true
    (contains ~needle:"sudo stat -c %04a" read_back);
  check bool "and the earlier reading is not that string" true
    (not (contains ~needle:"sudo stat -c %04a" pre_write))

(* Taking the reading is only half of it: a value read and then dropped is the
   same silence as never reading it. This case pins what each of the four answers
   means for the account rather than what the verdict is called, which is the
   question the verdict's own case above answers.

   Three of the four correct nothing, and they correct nothing for three different
   reasons. A host already at the declared mode had no divergence. A host with no
   file at all has a creation ahead of it, which is not a divergence either. A host
   that would not report the mode leaves the run with nothing it can claim -- and
   that one is said out loud, because a run that could not look and did not say so
   reads exactly like a run that looked and found agreement.

   Read through [Setup_phases.corrections_report] and through nothing else,
   because that block is the whole of what an operator sees: both kinds of line
   are worded there, both name the server there, and a correction holding the
   right pair in the wrong sentence is invisible to a length check. It is also
   the only register now -- the line about a reading nobody could take used to be
   printed where it was taken, which is where it went missing on a run that
   stopped two phases later. *)
let test_the_pre_write_reading_feeds_the_account () =
  let rendered output =
    String.concat "\n"
      (Setup_phases.corrections_report ~server:"10.0.0.1"
         (Setup.alloy_config_pre_write_account ~expected:"0640"
            (Setup.alloy_config_pre_write_mode_of_probe ~expected:"0640" output)))
  in
  (* The affirmative arm the three absences below need: this fixture does produce a
     correction, and it carries the mode the host had, the mode the run applied and
     the file both are about. 0644 is the mode the bare redirect left on the box
     this was written from, which is the reading the account exists to print. *)
  let corrected = rendered "0644\n" in
  check bool "names the file the mode belongs to" true
    (contains ~needle:"/etc/bondi/alloy/config.alloy" corrected);
  check bool "names the mode the host had" true
    (contains ~needle:"was mode 0644" corrected);
  check bool "names the mode this run applied" true
    (contains ~needle:"applied 0640" corrected);
  check bool "and does not also say the run corrected nothing" false
    (contains ~needle:"corrected nothing" corrected);
  check bool "and has nothing it could not read" false
    (contains ~needle:"could not read" corrected);
  let agreed = rendered "0640\n" in
  check bool "a host already at the declared mode corrects nothing" true
    (contains ~needle:"setup corrected nothing on server 10.0.0.1" agreed);
  check bool "and says nothing about a reading it took" false
    (contains ~needle:"mode" agreed);
  let absent = rendered "BONDI_ALLOY_MODE_ABSENT\n" in
  check bool "a file that is not there is a creation, not a correction" true
    (contains ~needle:"setup corrected nothing on server 10.0.0.1" absent);
  check bool "and a creation is not something the host refused" false
    (contains ~needle:"could not read" absent);
  check bool "and it is not reported as a mode either" false
    (contains ~needle:"mode" absent);
  (* Unreadable is the one absence that is not silence. No correction, because a
     mode nobody read is not a mode this run replaced -- and a line saying so,
     carrying the host's own answer, because the alternative is a transcript in
     which a run that could not look is indistinguishable from one that found
     agreement. *)
  let refused = rendered "BONDI_ALLOY_MODE_UNREADABLE\n" in
  check bool "the run says it could not read it" true
    (contains ~needle:"could not read the mode of /etc/bondi/alloy/config.alloy"
       refused);
  check bool "names the server it could not read it on" true
    (contains ~needle:"on server 10.0.0.1" refused);
  check bool "and carries the host's own answer" true
    (contains ~needle:"answered BONDI_ALLOY_MODE_UNREADABLE" refused);
  check bool "a mode the host would not report corrects nothing" true
    (contains ~needle:"setup corrected nothing on server 10.0.0.1" refused);
  check bool "and claims no mode the host never reported" false
    (contains ~needle:"was mode" refused);
  let silent = rendered "" in
  check bool "a host that said nothing is the same kind of answer" true
    (contains ~needle:"setup corrected nothing on server 10.0.0.1" silent);
  check bool "worded without a value to quote" true
    (contains ~needle:"the host reported nothing" silent);
  (* The account says what the box "was", never what it "is": a fixture elsewhere
     counts the present tense at zero to prove a converged run said nothing about
     the mode, and a line here wording it that way would turn that count into an
     assertion about nothing. *)
  check bool "nothing in the account reads as a present-tense mode" false
    (contains ~needle:"is mode" (corrected ^ refused))

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
          test_case "the reading taken before the write" `Quick
            test_alloy_config_mode_before_the_write;
          test_case "the two readings are distinguishable" `Quick
            test_the_two_mode_commands_are_not_the_same_string;
          test_case "the earlier reading feeds the account" `Quick
            test_the_pre_write_reading_feeds_the_account;
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
