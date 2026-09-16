The cutover a box makes when the server it was running stopped serving, on one
fixture holding both halves of the hazard at once: an orchestrator from before
the binary had subcommands, and a crontab whose lines are the `curl` shape an
older Bondi wrote. Either half alone is survivable. Together they are the window
this phase exists to close -- a legacy line points at a server that no longer
serves, and every scheduled job on the box no-ops silently until something
replaces the line.

Two commands close it, in this order. `bondi setup` brings the orchestrator
current and rescues the jobs' files out of the container before it is replaced;
`bondi deploy` is what carries the jobs back into the new orchestrator, which is
where the line is rewritten. Setup writes no crontab: its cron work is the two
host requirements and the file rescue, and the only writer of the spool is the
orchestrator's own deploy, running on the box.

What that puts out of reach here is stated rather than approximated. The writer
opens a fixed absolute path under the host's cron spool, so no test may write it
and no test may read it back; the shapes it writes are pinned by that writer's
own unit tests. What this file asserts is the state the two commands leave the
box in, and the dependency between them: the deploy is admitted only because the
setup ran, and the jobs whose files the setup rescued are named to the operator
as fired by nothing any reader could understand -- which is the hazard, in the
output they are already watching.

The fixtures are removed first so the file is re-runnable in a directory a
previous run has already written to.

  $ ROOT="$PWD"
  $ rm -rf ssh-argv.log box refused.log setup.log deployed.log

The box, as three files the stub reads and writes. They are the state the two
commands change, which is what lets the second command depend on what the first
one did rather than on the order of lines in this file.

  $ mkdir -p "$ROOT/box"
  $ export BOX="$ROOT/box"
  $ echo 'mlopez1506/bondi-server:0.10.3' > "$BOX/image"

The crontab as an older Bondi left it: two jobs, both `curl` lines against the
port the orchestrator used to publish. Written once here, and never rewritten by
anything below -- the rewrite belongs to the orchestrator and happens on the
box, out of this file's reach.

  $ cat > "$BOX/crontab" <<'SPOOL'
  > # BEGIN BONDI CRON
  > 0 6 * * * curl -s -X POST -d '{"job":"daily-close","secret":"s3cr3t"}' http://127.0.0.1:3030/api/v1/run
  > 30 2 * * * curl -s -X POST -d '{"job":"nightly-sweep","secret":"s3cr3t"}' http://127.0.0.1:3030/api/v1/run
  > # END BONDI CRON
  > SPOOL

The jobs' run and secret files start inside the orchestrator's writable layer,
which is where a box set up before Bondi bind-mounted that directory keeps them.
Nothing is on the host yet.

  $ : > "$BOX/payloads"

The stub answers the box. Its catch-all is loud and fails the run: a command
that falls through would come back empty, and empty is read as a host refusing
to answer rather than as a command nobody stubbed -- so an unanticipated command
must say so here instead of failing an assertion below for a reason no fixture
chose.

  $ mkdir -p "$ROOT/bin"
  $ cat > "$ROOT/bin/ssh" <<'STUB'
  > #!/bin/sh
  > while [ $# -gt 0 ] && [ "$1" != "--" ]; do shift; done
  > shift
  > printf '%s\n' "$1" >> "$SSH_ARGV_LOG"
  > case "$1" in
  >   'docker --version') echo 'Docker version 27.0.0, build deadbeef' ;;
  >   'curl --version') echo 'curl 8.5.0 (x86_64-pc-linux-gnu) libcurl/8.5.0' ;;
  >   *BONDI_CRON_DOCKER_PRESENT*) echo 'BONDI_CRON_DOCKER_PRESENT /usr/bin/docker' ;;
  >   *BONDI_ACME_PRESENT*) echo BONDI_ACME_PRESENT ;;
  >   'sudo chown root:root /etc/traefik/acme/acme.json'*) : ;;
  >   'docker network inspect'*) : ;;
  >   # The box's own account of its orchestrator, from the file this fixture
  >   # keeps that image in. The two reads are disjoint by construction: the
  >   # probe's format names a state and the version read's pattern is anchored
  >   # on the whole of `--format '{{.Image}}'`, which the probe's command does
  >   # not contain. An arm matching both would hand the probe a version with no
  >   # state, which reads as a box whose orchestrator is not there.
  >   *'name=^/bondi-orchestrator$'*'{{.State}}'*)
  >     printf 'running\t%s\n' "$(cat "$BOX/image")" ;;
  >   *'name=^/bondi-orchestrator$'*"--format '{{.Image}}'") cat "$BOX/image" ;;
  >   'docker ps -a --format'*)
  >     printf 'bondi-orchestrator\t%s\trunning\n' "$(cat "$BOX/image")" ;;
  >   'docker ps -aq | while read -r id'*)
  >     printf '/bondi-orchestrator\tundeclared\t\t0\t2026-09-01T09:00:00.222222222Z\n' ;;
  >   *'/var/spool/cron/crontabs/root'*)
  >     echo BONDI_CRONTAB_CONTENTS
  >     cat "$BOX/crontab"
  >     echo BONDI_CRONTAB_END ;;
  >   *BONDI_CRON_PAYLOAD_LISTED*)
  >     echo BONDI_CRON_PAYLOAD_LISTED
  >     cat "$BOX/payloads"
  >     echo BONDI_CRON_PAYLOAD_END ;;
  >   # The rescue. On this box the jobs' files are in the container's writable
  >   # layer, so the copy is what puts them on the host -- and the listing arm
  >   # above answers from the file this writes, which is how the ordering below
  >   # is a fact about the box rather than about the order of lines here.
  >   *'docker cp'*'/etc/bondi/cron'*)
  >     printf '%s\n' \
  >       '/etc/bondi/cron/daily-close/run.json' \
  >       '/etc/bondi/cron/daily-close/env' \
  >       '/etc/bondi/cron/nightly-sweep/run.json' \
  >       '/etc/bondi/cron/nightly-sweep/env' > "$BOX/payloads" ;;
  >   'docker stop bondi-orchestrator'*) : ;;
  >   'docker rm --force bondi-orchestrator'*) : ;;
  >   # The recreate. The box's reported image becomes the one the run command
  >   # named, which is the whole of what makes the version the deploy reads
  >   # below a consequence of this run rather than a second fixture.
  >   'docker run -d --name bondi-orchestrator'*)
  >     printf '%s\n' "$1" | tr ' ' '\n' | grep '^mlopez1506/bondi-server:' > "$BOX/image"
  >     echo 'f00dcafef00d' ;;
  >   'attempt=0; while'*) : ;;
  >   *'bondi-server check'*) echo '{"ready":true,"observations":[]}' ;;
  >   'docker logs --tail'*) echo 'bondi check: diagnostic sink is writable' ;;
  >   *'RestartPolicy'*) echo unless-stopped ;;
  >   *'bondi-server status'*) echo 'this fixture does not answer the report' >&2; exit 1 ;;
  >   'docker exec -i bondi-orchestrator bondi-server deploy')
  >     cat > "$BOX/deploy-payload"
  >     echo 'deployed' ;;
  >   *) cat > /dev/null; echo "unstubbed command: $1" >&2; exit 99 ;;
  > esac
  > STUB
  $ chmod +x "$ROOT/bin/ssh"
  $ export PATH="$ROOT/bin:$PATH"
  $ export SSH_ARGV_LOG="$ROOT/ssh-argv.log"

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
  >   version: "0.20.0"
  > cron_jobs:
  >   - name: daily-close
  >     image: example.com/daily-close
  >     schedule: "0 6 * * *"
  >     server:
  >       ip_address: 127.0.0.1
  >       port: 9
  >       ssh:
  >         user: deploy
  >         private_key_contents: "not-a-real-key"
  >         private_key_pass: ""
  >   - name: nightly-sweep
  >     image: example.com/nightly-sweep
  >     schedule: "30 2 * * *"
  >     server:
  >       ip_address: 127.0.0.1
  >       port: 9
  >       ssh:
  >         user: deploy
  >         private_key_contents: "not-a-real-key"
  >         private_key_pass: ""
  > EOF

The box as it stands, before anything is done to it. A deploy is the only thing
that replaces a legacy line, and on this box it is refused -- the orchestrator
predates the subcommand a deploy runs inside it, so the command that would
repair the crontab cannot run until the image is current. That is the order the
two commands have to be in, and it is a property of the box rather than of this
file: nothing here chooses it.

  $ bondi-client deploy my-service:v2 daily-close:1.4.0 nightly-sweep:1.4.0 > refused.log 2>&1
  [1]
  $ cat refused.log
  Deployment process initiated...
  Error on server 127.0.0.1: the server is running bondi-server 0.10.3, but a scheduled job's crontab line runs 'bondi-server run' inside the orchestrator, which requires 0.16.0 or later. An older image ignores the arguments and serves instead, so the job would fail at its next fire rather than now. Set bondi_server.version in bondi.yaml to 0.16.0 or later, run bondi setup, then deploy again.

Nothing reached the box but the read that refused it, so no file the deploy
would have written exists.

  $ cat ssh-argv.log
  docker ps -a --filter name=^/bondi-orchestrator$ --format '{{.Image}}'
  $ test -e "$BOX/deploy-payload" || echo 'the box was not written to'
  the box was not written to

The setup. Its cron work is the two host requirements and the rescue of the
jobs' files out of the container that is about to be replaced; it converges the
orchestrator and it writes no crontab. The report it ends on is another file's
subject and is not transcribed here -- what is asserted is the state it left.

  $ : > ssh-argv.log
  $ bondi-client setup > setup.log 2>&1
  $ echo $?
  0
  $ grep -c 'bondi-orchestrator is ready on server 127.0.0.1: mlopez1506/bondi-server:0.20.0' setup.log
  1

The box's own account of its orchestrator, which is the end state rather than
the transcript: it now reports the image the configuration declares, because the
run command this setup issued named it. A run that recreated the container and
stopped would satisfy a weaker assertion; this one is read back off the box.

  $ cat "$BOX/image"
  mlopez1506/bondi-server:0.20.0

The rescue, and its order. The jobs' files were in the container's writable
layer, so a recreate would have taken them with it while the lines that read
them went on firing. The copy is asserted to have been issued before the
removal, off the log of what the box was actually asked, because a copy made
after it would be a copy of nothing.

  $ COPIED=$(grep -n -F -- 'docker cp' ssh-argv.log | head -1 | cut -d: -f1)
  $ REMOVED=$(grep -n -F -- 'docker rm --force bondi-orchestrator' ssh-argv.log | head -1 | cut -d: -f1)
  $ test "$COPIED" -lt "$REMOVED" && echo 'the files were copied out before the container went'
  the files were copied out before the container went

Setup did not touch the crontab, and the client's own reader says so in the
words an operator reads: two entries in the section, neither of which any reader
can name, which is what a `curl` line is to a reader that understands only the
exec shape. The affirmative arm for that sentence is the same reader against the
same box after the deploy, further down.

  $ grep -c '2 jobs (entry 1 could not be read, entry 2 could not be read)' setup.log
  1

The deploy, against the box the setup left. The gate that refused above admits
it now, and for the same reason it refused: it reads the version off the box,
and the box's version changed because the setup ran.

  $ : > ssh-argv.log
  $ bondi-client deploy my-service:v2 daily-close:1.4.0 nightly-sweep:1.4.0 > deployed.log 2>&1
  $ cat deployed.log
  Deployment process initiated...
  cron job daily-close on server 127.0.0.1 keeps its files on the box and no crontab line that could be read fires them: entries 1 and 2 of the section could not be read, and an entry nobody could read may be the line that fires it
  cron job nightly-sweep on server 127.0.0.1 keeps its files on the box and no crontab line that could be read fires them: entries 1 and 2 of the section could not be read, and an entry nobody could read may be the line that fires it
  Deploying to server: 127.0.0.1
  Deployment initiated on server 127.0.0.1

Those two sentences are the hazard itself, said out loud to the operator on the
run that closes it: both jobs' files are on the box, and no line the reader can
understand fires either of them. A box whose section had already been migrated
produces neither sentence, because each job's name would be on a line.

The box was read and then written to, in that order, and the write is the
orchestrator's own deploy subcommand -- the command inside which the crontab
writer runs.

  $ cat ssh-argv.log
  docker ps -a --filter name=^/bondi-orchestrator$ --format '{{.Image}}'
  if sudo -n test -r '/var/spool/cron/crontabs/root' 2>/dev/null; then echo BONDI_CRONTAB_CONTENTS; sudo -n cat '/var/spool/cron/crontabs/root' 2>/dev/null && echo BONDI_CRONTAB_END; elif sudo -n test -e '/var/spool/cron/crontabs/root' 2>/dev/null; then echo BONDI_CRONTAB_UNREADABLE; elif sudo -n true 2>/dev/null; then echo BONDI_CRONTAB_ABSENT; else echo BONDI_CRONTAB_UNREADABLE; fi; exit 0
  if sudo -n test -d '/etc/bondi/cron' 2>/dev/null; then echo BONDI_CRON_PAYLOAD_LISTED; sudo -n find '/etc/bondi/cron' -mindepth 2 -maxdepth 2 -type f 2>/dev/null && echo BONDI_CRON_PAYLOAD_END; elif sudo -n true 2>/dev/null; then echo BONDI_CRON_PAYLOAD_ABSENT; else echo BONDI_CRON_PAYLOAD_UNREADABLE; fi; exit 0
  docker exec -i bondi-orchestrator bondi-server deploy

Every declared job reached the box, on the deploy's standard input rather than
in its argument list. This is the last thing about the migration a client-side
test may witness: what the orchestrator does with these names -- replacing each
legacy line with an exec line, by name -- happens inside the container, against
a fixed absolute path under the host's cron spool that no test may write or read
back. The shapes it writes are pinned by that writer's own unit tests, and the
refusal it answers a malformed section with is pinned by a fixture of its own.

  $ sed 's/.*"cron_jobs"://' "$BOX/deploy-payload" \
  >   | grep -o '"name":"[^"]*"' | cut -d'"' -f4 | sort
  daily-close
  nightly-sweep

The crontab is still the file this fixture wrote, byte for byte. Neither command
touched it from here, which is the other half of saying that the rewrite is the
orchestrator's: a client that had edited the spool would have left a different
file.

  $ cat "$BOX/crontab"
  # BEGIN BONDI CRON
  0 6 * * * curl -s -X POST -d '{"job":"daily-close","secret":"s3cr3t"}' http://127.0.0.1:3030/api/v1/run
  30 2 * * * curl -s -X POST -d '{"job":"nightly-sweep","secret":"s3cr3t"}' http://127.0.0.1:3030/api/v1/run
  # END BONDI CRON
