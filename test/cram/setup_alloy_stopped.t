A `bondi-alloy` container that exists but is stopped still holds its name, so
`docker run` against it fails with a conflict and the whole setup stops there —
including every phase after alloy. The listing used to omit `-a`, which made a
stopped container invisible and indistinguishable from no container at all, and
the only way out was a manual `docker rm bondi-alloy` on the host.

  $ ROOT="$PWD"

The stub reports a stopped alloy container and an orchestrator already running
the declared version, so the run reduces to the alloy phase.

  $ mkdir -p "$ROOT/bin"
  $ cat > "$ROOT/bin/ssh" <<'STUB'
  > #!/bin/sh
  > while [ $# -gt 0 ] && [ "$1" != "--" ]; do shift; done
  > shift
  > printf '%s\n' "$1" >> "$SSH_ARGV_LOG"
  > cat >> "$SSH_STDIN_LOG"
  > case "$1" in
  >   *BONDI_ACME_PRESENT*) echo BONDI_ACME_PRESENT ;;
  >   'docker --version') echo 'Docker version 27.0.0, build deadbeef' ;;
  >   *'name=^/bondi-orchestrator$'*'{{.State}}'*)
  >     printf 'running\tmlopez1506/bondi-server:0.15.0\n' ;;
  >   *'ps -a --filter name=^/bondi-alloy$'*'{{.State}}'*)
  >     printf 'exited\tgrafana/alloy:v1.8.0\n' ;;
  >   # The mode the host reports for the config file *before* setup writes it,
  >   # answered from $ALLOY_MODE_BEFORE, and separately from the read-back below
  >   # so that a box whose mode this run corrected is one variable away from a
  >   # box that already agreed. One arm answering both readings would have the
  >   # host reporting the same mode before and after the write, which is the
  >   # failure path and not a correction -- a fixture meant to show a mode being
  >   # corrected would then pass while asserting the opposite.
  >   #
  >   # It selects on the absent marker, which only the earlier reading carries:
  >   # the read-back has no use for an answer saying the file is not there, so
  >   # the two cannot be told apart by accident and no ordering of these arms
  >   # decides which one matches.
  >   *BONDI_ALLOY_MODE_ABSENT*) echo "${ALLOY_MODE_BEFORE-0640}" ;;
  >   # The mode the host reports for the config file after it was written,
  >   # answered from $ALLOY_MODE so that a box agreeing with the declaration
  >   # and a box disagreeing with it are the same fixture with one variable
  >   # changed. Without this arm the probe falls through to *) and answers
  >   # nothing, which setup reads as a refusal to report rather than as
  >   # agreement -- so every arm below would pass for the wrong reason.
  >   *'sudo stat -c %04a'*) echo "${ALLOY_MODE-0640}" ;;
  >   # The credentials write. Its output is deliberately not consulted by the
  >   # client -- unlike the mode probe above -- so this arm answers nothing on
  >   # purpose, and says so rather than leaving the command to reach *) where a
  >   # reader cannot tell a considered silence from an unhandled command.
  >   #
  >   # It matches the write and only the write. The run command below names the
  >   # same file through --env-file, so an arm matching the path alone would
  >   # swallow it -- case takes the first match -- and the container id would
  >   # come back empty from an arm that reads as deliberate.
  >   *'cat > '*'/etc/bondi/alloy/env'*) : ;;
  >   *'--name bondi-alloy'*) echo 'd671990dc2318f4b' ;;
  >   *'/var/spool/cron/crontabs/root'*) echo BONDI_CRONTAB_ABSENT ;;
  >   # The payload directory the crontab section is compared against. Without
  >   # this arm the command falls through to *) and answers nothing, which is a
  >   # listing that never happened rather than a directory that is empty -- and
  >   # the report says so, correctly, in a fixture that is about something else.
  >   *BONDI_CRON_PAYLOAD_LISTED*)
  >     echo BONDI_CRON_PAYLOAD_LISTED
  >     echo BONDI_CRON_PAYLOAD_END ;;
  >   # The host's applied restart policy. Without this arm the command falls
  >   # through to *) and answers nothing, which setup reads as a refusal to
  >   # report rather than as agreement.
  >   #
  >   # Answered from a file rather than from a variable because the policy is
  >   # read twice in one run -- once to decide, once to confirm what `docker
  >   # update` applied -- and a host that reported the same policy both times
  >   # is a correction the daemon refused, not a correction. The update arm
  >   # below is what moves the box between the two readings, which is the only
  >   # way a run on this stub reaches a restart-policy correction at all.
  >   *'RestartPolicy'*) cat "$RESTART_POLICY_FILE" ;;
  >   'docker update'*)
  >     printf 'unless-stopped\n' > "$RESTART_POLICY_FILE"
  >     echo bondi-orchestrator ;;
  >   # The orchestrator's image on its own, which is the version the report's
  >   # orchestrator read holds this box to before running a subcommand inside
  >   # its container. Without this arm the command falls through to *) and
  >   # answers nothing, which reads as a box whose version could not be read --
  >   # the same unavailable source for a reason no fixture chose. The pattern
  >   # ends the command rather than merely containing it: the probe's own
  >   # listing asks for {{.State}} and {{.Image}} together, and an arm that
  >   # matched both would answer the probe with a version.
  >   *'name=^/bondi-orchestrator$'*"--format '{{.Image}}'") echo 'mlopez1506/bondi-server:0.15.0' ;;
  >   # The three readings setup takes off the box once it has started the
  >   # container: the wait for a running state, the server's own check inside
  >   # it, and a read of the container's log stream for the line the check
  >   # writes to its diagnostic sink. The check writes a document and the log
  >   # read carries the marker because an answer that says nothing is a
  >   # rejection rather than a pass, so a command falling through to the
  >   # catch-all below would fail this run for a reason no fixture here chose.
  >   'attempt=0; while'*) : ;;
  >   *'bondi-server check'*) echo '{"ready":true,"observations":[]}' ;;
  >   'docker logs --tail'*) echo 'bondi check: diagnostic sink is writable' ;;
  >   # The closing report's own reading, which is a different question from the
  >   # one setup takes and is answered here so that a fall-through to *) cannot
  >   # stand in for it. This box clears the floor, so the report does ask; what
  >   # it is told is a refusal, and every report line this file prints is
  >   # normalised, so the wording is not the subject.
  >   *'bondi-server status'*) echo 'this fixture does not answer the report' >&2; exit 1 ;;
  >   *) : ;;
  > esac
  > STUB
  $ chmod +x "$ROOT/bin/ssh"
  $ export PATH="$ROOT/bin:$PATH"

  $ export SSH_ARGV_LOG="$PWD/ssh-argv.log"
  $ : > "$SSH_ARGV_LOG"

The policy this box is holding, written to a file so that the stub's update arm
can change it mid-run. It starts at the declared value, so every run below is a
box whose restart policy already agrees until one of them says otherwise.

  $ export RESTART_POLICY_FILE="$PWD/restart-policy.txt"
  $ printf 'unless-stopped\n' > "$RESTART_POLICY_FILE"

Everything the client sends a remote command on standard input is captured too,
so a payload that is kept out of `argv` can still be shown to have reached the
host rather than merely to have gone missing.

  $ export SSH_STDIN_LOG="$PWD/ssh-stdin.log"
  $ : > "$SSH_STDIN_LOG"
  $ cat > bondi.yaml <<'EOF'
  > service:
  >   name: my-service
  >   image: acme/app
  >   port: 8080
  >   env_vars: {}
  >   servers:
  >     - ip_address: 127.0.0.1
  >       port: 9
  >       ssh:
  >         user: deploy
  >         private_key_contents: "not-a-real-key"
  >         private_key_pass: ""
  > bondi_server:
  >   version: "0.15.0"
  > alloy:
  >   grafana_cloud:
  >     instance_id: "123456"
  >     api_key: "glc_secret"
  >     endpoint: "https://logs-prod.grafana.net/loki/api/v1/push"
  > EOF

The stopped container is removed before the new one is run, and the setup
completes rather than stopping on a name conflict. The run's own lines are what
this case is about, so they are taken here without the report that follows them.

The output is captured to a file and sliced afterwards rather than piped into
`head`. Through a pipe the status cram checks is `head`'s, so the run could exit
non-zero -- or be killed by the SIGPIPE `head` raises when it has its ten lines
-- and the case would still read as a pass. Slicing a file that a completed run
wrote leaves the status this line asserts belonging to `bondi-client`.

  $ bondi-client setup > out.log 2>&1
  $ head -11 out.log
  Setting up the servers...
  Processing server: 127.0.0.1
  bondi-orchestrator container is already running on server 127.0.0.1: 0.15.0, skipping...
  Docker is already installed on server 127.0.0.1: Docker version 27.0.0, build deadbeef
  Network bondi-network is present on server 127.0.0.1
  ACME file permissions updated on server 127.0.0.1: /etc/traefik/acme/acme.json
  Stopped bondi-alloy container on server 127.0.0.1
  Removed bondi-alloy container and config on server 127.0.0.1
  Alloy config written on server 127.0.0.1: /etc/bondi/alloy/config.alloy
  Wrote Alloy credentials file on server 127.0.0.1: /etc/bondi/alloy/env
  bondi-alloy container started on server 127.0.0.1: d671990dc2318f4b

The removal is what the incident needed a human for.

  $ grep -c -F -- 'docker rm bondi-alloy' ssh-argv.log
  1

The container's name was not the only thing left behind. The credentials file
has no removal action of its own -- it is carried off because it sits inside the
directory this command deletes, so the directory named here has to be the same
one the writes below create their files in. Spelled out rather than derived: a
removal aimed at a directory nothing writes to leaves a withdrawn credential on
the host and fails no assertion of its own.

  $ grep -c -F -- "sudo rm -rf '/etc/bondi/alloy'" ssh-argv.log
  1

Its affirmative arm is the listing itself: without `-a` a stopped container is
not reported, so the state the removal answers to would never be read.

  $ grep -c -F -- 'ps -a --filter name=^/bondi-alloy$' ssh-argv.log
  1

The run command that reaches the host declares a restart policy. Without it the
sidecar is gone after a host reboot or a docker-ce upgrade and logs stop
shipping silently, with nothing on the box saying so. The policy is spelled out
rather than built from the shared constant on purpose: through the constant this
would pass for whatever value the constant takes, including `always`.

  $ grep -c -F -- 'docker run -d --name bondi-alloy --restart unless-stopped' ssh-argv.log
  1

The config file's mode is Bondi's own rather than whatever the remote shell's
umask happened to be. The write reaching the host carries the mode explicitly,
and the value is spelled out rather than read from the constant that produced
it: through the constant this would pass for whatever value the constant takes,
including the `0600` that would undo the narrowing already applied to these
boxes out of band.

  $ grep -c -E -- "chmod 0640 .*config[.]alloy" ssh-argv.log
  1

The Grafana Cloud credentials are written to their own file at mode 0600, and
they get there on standard input. `docker --env-file` has no escaping syntax, so
the file is written fresh rather than truncated: a redirect onto a file that
already exists creates nothing and therefore consults no umask, which is how a
credential file could keep a mode somebody else chose for it.

  $ grep -c -E -- "chmod 0600 .*/etc/bondi/alloy/env" ssh-argv.log
  1

Both writes chain their steps with `&&`. `sh -c` exits with the status of the
last command it ran, so under `;` the status of a write is the trailing chmod's
-- and chmod succeeds on a file `cat` created and then failed to fill. A
connection dropped mid-transfer would report success and pass the mode read-back
below, because the mode really was applied.

  $ grep -c -E -- "cat > [^&]*/etc/bondi/alloy/env[^&]* && chmod 0600 " ssh-argv.log
  1
  $ grep -c -E -- "cat > [^&]*/etc/bondi/alloy/config[.]alloy[^&]* && chmod 0640 " ssh-argv.log
  1

The negative half of that pair, over both writes at once: no step of either is
separated by a `;`, so no step's failure can be discarded by the one after it.

  $ grep -E -- "cat > [^&]*/etc/bondi/alloy/" ssh-argv.log | grep -c -F -- ';'
  0
  [1]

The command that writes it carries no credential of its own -- the values arrive
on the pipe. The affirmative pair for that absence is the arm above, which proves
the write really did reach `argv` for this run, and the arm below, which proves
the values really did reach the host by the intended route. Without both, the
absence would pass just as well against a run that stopped writing the file.

  $ grep -E -- "cat > .*/etc/bondi/alloy/env" ssh-argv.log | grep -c -F -- glc_secret
  0
  [1]
The match is whole-line rather than a substring. `env_file_contents` emits one
undelimited `KEY=VALUE` per line, so an unanchored `...INSTANCE_ID=123456` also
matches `...INSTANCE_ID=1234567` and an unanchored `...API_KEY=glc_secret` also
matches `...API_KEY=glc_secret_and_then_some` -- which is exactly the trailing
corruption a truncated or extended write produces, and the thing these two arms
exist to see.

  $ grep -c -x -F -- 'GRAFANA_CLOUD_API_KEY=glc_secret' ssh-stdin.log
  1
  $ grep -c -x -F -- 'GRAFANA_CLOUD_INSTANCE_ID=123456' ssh-stdin.log
  1

The generated River config travels on the same pipe and names both variables,
but it carries neither value: the config reads them through `sys.env`, so the
only thing on the host that holds the key is the file written above.

  $ grep -c -F -- 'sys.env("GRAFANA_CLOUD_API_KEY")' ssh-stdin.log
  1

The run command that starts the sidecar carries no credential either. The key
appears nowhere in any command line this run sent — not in the write, not in the
run — and the same run proves it reached the host anyway, by the file above.
Without that pair the absence would pass against a run that never got as far as
starting Alloy, and against an empty log.

  $ grep -c -F -- glc_secret ssh-argv.log
  0
  [1]
  $ grep -c -F -- GRAFANA_CLOUD_INSTANCE_ID ssh-argv.log
  0
  [1]

The affirmative arm for both absences: the run command names the file the
credentials were written to, so the container still gets them. The path is
spelled out rather than derived, because a run command pointing at a path nothing
wrote starts a sidecar that ships nothing and fails no assertion of its own.

  $ grep -c -F -- '--env-file /etc/bondi/alloy/env' ssh-argv.log
  1

Asking is not applying, so the mode is read back off the host. The run above had
the host report the declared mode: it completed, and it said nothing about the
mode, because there was nothing to correct.

  $ grep -c -F -- 'Alloy config written on server 127.0.0.1: /etc/bondi/alloy/config.alloy' out.log
  1
  $ grep -c 'is mode' out.log
  0
  [1]

It said nothing about the mode in the account either, and the account was still
taken: a host that already had the declared mode before the write corrected
nothing, which is a different fact from a run whose account nobody printed. The
affirmative arm for both absences is the run at the end of this file, on this
same stub with one variable changed.

  $ grep -c 'was mode' out.log
  0
  [1]
  $ grep -c -F -- 'setup corrected nothing on server 127.0.0.1' out.log
  1

The affirmative half of that pair: the same stub and the same bondi.yaml,
differing only in what the host reports the mode to be. Now the read-back
disagrees, the run fails on it, and the message names both what was asked for
and what the host said -- and quotes none of the file it is talking about.

  $ ALLOY_MODE=0644 bondi-client setup > out.log 2>&1
  [1]
  $ grep 'is mode' out.log
  Error: /etc/bondi/alloy/config.alloy on server 127.0.0.1 is mode 0644 after being written at 0640 -- refusing to report success on a posture that was not applied

The other half of the read-back's negative space: a host that answers nothing.
A `stat` the host refused, an output that never arrived and a stub with no arm
for the command all look like this, and none of them is a mode. The run fails
rather than reporting one it never read, and the file it is talking about is
named once -- the verdict carries what happened and the message does the wording,
so there is one place the path can come from.

  $ ALLOY_MODE= bondi-client setup > out.log 2>&1
  [1]
  $ grep 'could not read back' out.log
  Error: could not read back the mode of /etc/bondi/alloy/config.alloy on server 127.0.0.1 after writing it at 0640, so whether the mode was applied is unknown: the host reported nothing
  $ grep -o -F -- '/etc/bondi/alloy/config.alloy' out.log | wc -l
  1

The other kind of unreadable, on the same fixture: the host answered, and what
it answered was the probe's own marker rather than a mode. That is a file `stat`
refused, not a host that said nothing, and the message says which -- the verdict
carries the two apart as data and the wording is built here, in one place, from
one path.

  $ ALLOY_MODE=BONDI_ALLOY_MODE_UNREADABLE bondi-client setup > out.log 2>&1
  [1]
  $ grep 'could not read back' out.log
  Error: could not read back the mode of /etc/bondi/alloy/config.alloy on server 127.0.0.1 after writing it at 0640, so whether the mode was applied is unknown: the host could not read it and answered BONDI_ALLOY_MODE_UNREADABLE
  $ grep -o -F -- '/etc/bondi/alloy/config.alloy' out.log | wc -l
  1

The whole point of taking a reading before the write, on the same stub and the
same manifest as every run above: the host had 0644 -- the mode a bare redirect
left on the boxes this was written from -- the write narrowed it, and the run says
so. It names what the host had and what it applied, because a line saying only
what a run changed something to is the reassurance this account replaces. And it
exits 0: a correction is a write that succeeded, so refusing on one would block
the command that repairs the host.

  $ : > "$SSH_ARGV_LOG"
  $ ALLOY_MODE_BEFORE=0644 bondi-client setup > out.log 2>&1
  $ grep -c -F -- '/etc/bondi/alloy/config.alloy on server 127.0.0.1 was mode 0644, applied 0640' out.log
  1
  $ grep -c -F -- 'setup corrected nothing on server 127.0.0.1' out.log
  0
  [1]

The reading really was taken before the write, which is the one thing about it
that cannot be inferred from the line it produces: after the write the file sits
at the mode just asked for, so a reading taken afterwards agrees with whatever it
was told and reports nothing. Pinned by position in the command log rather than by
the value, because both readings ask about the same file and only their order
distinguishes what they can see.

  $ BEFORE=$(grep -n -F -- 'BONDI_ALLOY_MODE_ABSENT' ssh-argv.log | head -1 | cut -d: -f1)
  $ WRITE=$(grep -n -E -- "cat > [^&]*config[.]alloy" ssh-argv.log | head -1 | cut -d: -f1)
  $ test "$BEFORE" -lt "$WRITE" && echo "the mode is read before it is written"
  the mode is read before it is written

None of the three credentials this manifest declares reaches the account block on
this run. What that is worth is uneven, and the uneven part is the point of
saying it here rather than leaving the greps to speak for themselves.

The selecting expression is every shape of line the block can print -- a
correction, a reading nobody could take, and the sentence saying nothing
diverged -- so no line of the account is outside the scan. What is scanned for is
three specific values, and that is where the claim stops. The subject of a
correction is derived from its site, so no path and no container name can be
handed to one at all; the host's own answer has to be declared a host's answer at
a constructor named for that boundary, which a caller can still do with a value
read out of a manifest, because a string carries nothing that says where it came
from. So this is not an assertion that no declared value can reach a line. A
fourth declared value -- the alloy endpoint, an image reference, a service name
-- would pass these three greps untouched.

Its affirmative arm is the line counted above: the account is non-empty on this
run, so these counts are zero because nothing declared reached it and not because
there was nothing to search.

  $ grep -E -- 'was mode |was restart policy |could not read the |setup corrected' out.log | grep -c -F -- glc_secret
  0
  [1]
  $ grep -E -- 'was mode |was restart policy |could not read the |setup corrected' out.log | grep -c -F -- not-a-real-key
  0
  [1]
  $ grep -E -- 'was mode |was restart policy |could not read the |setup corrected' out.log | grep -c -F -- 123456
  0
  [1]

A box with no config file at all is the ordinary first setup, and a creation is
not a correction: there was no mode to diverge from, so the account says the run
corrected nothing and the run says nothing about a reading it could not take. The
distinction matters because collapsing it onto the unreadable answer would report
every first setup as a box whose posture could not be established.

  $ ALLOY_MODE_BEFORE=BONDI_ALLOY_MODE_ABSENT bondi-client setup > out.log 2>&1
  $ grep -c 'was mode' out.log
  0
  [1]
  $ grep -c 'could not read the mode' out.log
  0
  [1]
  $ grep -c -F -- 'setup corrected nothing on server 127.0.0.1' out.log
  1

The affirmative arm for that second absence, and the other half of the earlier
reading's negative space: a host that would not report the mode at all. Nothing
was corrected, because nothing was read -- but the run says it could not read it,
rather than being silent, because a transcript in which a run that could not look
reads like a run that looked and agreed is the whole defect. It still exits 0: the
reading was taken for the account's sake and the write is what the run is judged
on.

  $ ALLOY_MODE_BEFORE=BONDI_ALLOY_MODE_UNREADABLE bondi-client setup > out.log 2>&1
  $ grep 'could not read the mode' out.log
  could not read the mode of /etc/bondi/alloy/config.alloy on server 127.0.0.1, so this run cannot say what it found: the host could not read it and answered BONDI_ALLOY_MODE_UNREADABLE
  $ grep -c 'was mode' out.log
  0
  [1]
  $ grep -c -F -- 'setup corrected nothing on server 127.0.0.1' out.log
  1

Two corrections in one run, and the order the account puts them in. The Alloy
config mode is read back inside the plan the interpreter applies; the restart
policy is converged only once that plan has finished, so a run that corrects
both reaches them in that order and the account is accumulated in the order the
run reached them. Asserted by line position and not by presence: an accumulator
turned over the wrong way, or joined the other way round, prints both of these
lines and prints them backwards, and two presence counts would pass for it.

  $ printf 'no\n' > "$RESTART_POLICY_FILE"
  $ ALLOY_MODE_BEFORE=0644 bondi-client setup > out.log 2>&1
  $ grep -c -F -- '/etc/bondi/alloy/config.alloy on server 127.0.0.1 was mode 0644, applied 0640' out.log
  1
  $ grep -c -F -- 'bondi-orchestrator on server 127.0.0.1 was restart policy no, applied unless-stopped' out.log
  1
  $ grep -c -F -- 'setup corrected nothing on server 127.0.0.1' out.log
  0
  [1]
  $ MODE=$(grep -n -F -- 'was mode 0644, applied 0640' out.log | head -1 | cut -d: -f1)
  $ POLICY=$(grep -n -F -- 'was restart policy no, applied unless-stopped' out.log | head -1 | cut -d: -f1)
  $ test "$MODE" -lt "$POLICY" && echo "the mode correction is accounted before the restart policy"
  the mode correction is accounted before the restart policy

The same order over the other thing the pre-write reading can produce. The
reading is taken before the write so that whatever it has to say enters the
account where the run took it; a notice about a reading nobody could take is
accumulated at that same point, ahead of a convergence that happens after the
plan. Its position is the claim -- the line itself says nothing about when it
was taken -- so it is pinned the way the pair above is.

  $ printf 'no\n' > "$RESTART_POLICY_FILE"
  $ ALLOY_MODE_BEFORE=BONDI_ALLOY_MODE_UNREADABLE bondi-client setup > out.log 2>&1
  $ grep -c -F -- 'could not read the mode of /etc/bondi/alloy/config.alloy on server 127.0.0.1' out.log
  1
  $ grep -c -F -- 'bondi-orchestrator on server 127.0.0.1 was restart policy no, applied unless-stopped' out.log
  1
  $ UNREADABLE=$(grep -n -F -- 'could not read the mode of' out.log | head -1 | cut -d: -f1)
  $ POLICY=$(grep -n -F -- 'was restart policy no, applied unless-stopped' out.log | head -1 | cut -d: -f1)
  $ test "$UNREADABLE" -lt "$POLICY" && echo "the unreadable reading is accounted before the restart policy"
  the unreadable reading is accounted before the restart policy

The same three greps over the two shapes of line the run above could not produce.
This account holds a reading nobody could take and a restart-policy correction,
which is where the widened selecting expression earns its keep: a credential
carried into either of them is caught here and would have been outside the scan
entirely while the expression named only the mode correction. Combined into one
count because the question is the same one three times and the affirmative arm is
the pair of lines counted above, not any one of the values.

  $ grep -E -- 'was mode |was restart policy |could not read the |setup corrected' out.log | grep -c -E -- 'glc_secret|not-a-real-key|123456'
  0
  [1]
