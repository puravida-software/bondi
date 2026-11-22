A second `bondi setup` on a box where nothing changed leaves the orchestrator
alone, cron host or not. On a box with cron jobs it used to be recreated on
every run, and a recreate stops the container a running job executes inside:
whatever job was firing at that moment was killed. A job is killed only by a
`docker stop` (or a removal) of its container, so a run that issues neither for
the orchestrator is a run during which no job can be killed, and that absence is
what this file asserts. A real box is not reached from here: setup runs over
SSH, and the stub below stands in for the host.

The fixtures are removed first so the file is re-runnable in a directory a
previous run has already written to.

  $ ROOT="$PWD"
  $ rm -rf box ssh-argv.log first.log second.log third.log

The box, as files the stub reads and writes. `registry` is the image id the
registry's tag names. `tag` is the image id the box's own copy of the tag names,
written by a pull. `container` is the orchestrator, when there is one: the
digest label it was created with and the id of the image it was created from,
both written by the `docker run` that created it.

So the digest the listing reports is never written by this file. It is the one
setup stamped on the container it created, on the first run below, and the
second run compares it against the one it computes afresh from the same
configuration: equal values, computed twice. The ids are the docker CLI's
full form, as `docker image inspect -f '{{.Id}}'` prints them.

  $ export FIXTURES="$PWD/../client/fixtures/docker_cli"
  $ mkdir -p "$ROOT/box"
  $ export BOX="$ROOT/box"
  $ echo 'sha256:66a6306db78bf2dbf3487f293aa8d6990d8e506fdffab9cc43fe422becf886e4' > "$BOX/registry"
  $ : > "$BOX/tag"

The stub answers the box in the shapes the docker CLI prints, two of which are
the platform's own and modelled here rather than simplified away. The listing's
image column is the reference the container was created from only while that
reference still names the container's image; once a pull has moved the tag, the
column is the container's image id cut to twelve hex digits. And a pull that
fetches a new image says `Downloaded newer image`, where one that finds the
image already there says `Image is up to date`.

Its catch-all is loud and fails the run: an answer nobody stubbed would come
back empty, and empty is read as a host refusing to answer, so an unanticipated
command must say so here rather than fail an assertion below for a reason no
fixture chose.

  $ mkdir -p "$ROOT/bin"
  $ cat > "$ROOT/bin/ssh" <<'STUB'
  > #!/bin/sh
  > while [ $# -gt 0 ] && [ "$1" != "--" ]; do shift; done
  > shift
  > printf '%s\n' "$1" >> "$SSH_ARGV_LOG"
  > REF='mlopez1506/bondi-server:0.25.0'
  > image_column() {
  >   id=$(cut -f2 "$BOX/container")
  >   if [ "$id" = "$(cat "$BOX/tag")" ]; then
  >     printf '%s' "$REF"
  >   else
  >     printf '%s' "$id" | sed 's/^sha256:\(.\{12\}\).*/\1/'
  >   fi
  > }
  > case "$1" in
  >   "docker pull '$REF'")
  >     if [ "$(cat "$BOX/tag")" = "$(cat "$BOX/registry")" ]; then
  >       cat "$FIXTURES/pull_up_to_date.out"
  >     else
  >       cat "$FIXTURES/pull_newer_image.out"
  >     fi
  >     cp -f "$BOX/registry" "$BOX/tag" ;;
  >   'docker --version') echo 'Docker version 27.0.0, build deadbeef' ;;
  >   'curl --version') echo 'curl 8.5.0 (x86_64-pc-linux-gnu) libcurl/8.5.0' ;;
  >   *BONDI_CRON_DOCKER_PRESENT*) echo 'BONDI_CRON_DOCKER_PRESENT /usr/bin/docker' ;;
  >   *BONDI_ACME_PRESENT*) echo BONDI_ACME_PRESENT ;;
  >   'sudo chown root:root /etc/traefik/acme/acme.json'*) : ;;
  >   'docker network inspect'*) : ;;
  >   # The probe's listing and the version read are disjoint by construction:
  >   # the probe's format names a state, and the version read's pattern is
  >   # anchored on the whole of `--format '{{.Image}}'`.
  >   *'name=^/bondi-orchestrator$'*'{{.State}}'*)
  >     if [ -f "$BOX/container" ]; then
  >       printf 'running\t%s\t%s\n' "$(image_column)" "$(cut -f1 "$BOX/container")"
  >     fi ;;
  >   *'name=^/bondi-orchestrator$'*"--format '{{.Image}}'")
  >     image_column; echo ;;
  >   # The image check, both ids in one line: the tag's, then the container's.
  >   "docker image inspect -f '{{.Id}}' '$REF' && docker container inspect -f '{{.Image}}' 'bondi-orchestrator'")
  >     cat "$BOX/tag"
  >     cut -f2 "$BOX/container" ;;
  >   'docker ps -a --format'*)
  >     printf 'bondi-orchestrator\t%s\trunning\n' "$(image_column)" ;;
  >   'docker ps -aq | while read -r id'*)
  >     printf '/bondi-orchestrator\tundeclared\t\t0\t2026-09-01T09:00:00.222222222Z\n' ;;
  >   # The job's line, in the shape the orchestrator's own deploy writes.
  >   *'/var/spool/cron/crontabs/root'*)
  >     echo BONDI_CRONTAB_CONTENTS
  >     echo '# BEGIN BONDI CRON'
  >     echo "0 3 * * * docker exec bondi-orchestrator sh -c 'bondi-server run < /etc/bondi/cron/nightly-report/run.json'"
  >     echo '# END BONDI CRON'
  >     echo BONDI_CRONTAB_END ;;
  >   *BONDI_CRON_PAYLOAD_LISTED*)
  >     echo BONDI_CRON_PAYLOAD_LISTED
  >     echo /etc/bondi/cron/nightly-report/run.json
  >     echo /etc/bondi/cron/nightly-report/env
  >     echo BONDI_CRON_PAYLOAD_END ;;
  >   *'docker cp -a'*'/etc/bondi/cron'*) : ;;
  >   'docker stop bondi-orchestrator') : ;;
  >   'docker rm --force bondi-orchestrator'*) rm -f "$BOX/container" ;;
  >   # The create. What the box records is what the command carried: the
  >   # digest label setup stamped on it, and the image its tag names now.
  >   'docker run -d --name bondi-orchestrator'*)
  >     hash=$(printf '%s\n' "$1" | tr ' ' '\n' | sed -n 's/^bondi[.]spec-hash=//p')
  >     printf '%s\t%s\n' "$hash" "$(cat "$BOX/tag")" > "$BOX/container"
  >     echo 'f00dcafef00d' ;;
  >   'attempt=0; while'*) : ;;
  >   *'bondi-server check'*) echo '{"ready":true,"probes":[]}' ;;
  >   'docker logs --tail'*) echo 'bondi check: diagnostic sink is writable' ;;
  >   *'RestartPolicy'*) echo unless-stopped ;;
  >   *'bondi-server status'*) echo 'this fixture does not answer the report' >&2; exit 1 ;;
  >   *) cat > /dev/null; echo "unstubbed command: $1" >&2; exit 99 ;;
  > esac
  > STUB
  $ chmod +x "$ROOT/bin/ssh"
  $ export PATH="$ROOT/bin:$PATH"
  $ export SSH_ARGV_LOG="$ROOT/ssh-argv.log"

A box with one cron job, which is what makes it a cron host: the orchestrator
is created with the jobs' payload directory mounted, and a replacement copies
that directory out first.

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
  >   version: "0.25.0"
  > cron_jobs:
  >   - name: nightly-report
  >     image: example.com/nightly-report
  >     schedule: "0 3 * * *"
  >     server:
  >       ip_address: 127.0.0.1
  >       port: 9
  >       ssh:
  >         user: deploy
  >         private_key_contents: "not-a-real-key"
  >         private_key_pass: ""
  > EOF

The first setup, on a box with no orchestrator: it is pulled and created.

  $ : > "$SSH_ARGV_LOG"
  $ bondi-client setup > first.log 2>&1
  $ echo $?
  0
  $ grep -c -F -- 'docker run -d --name bondi-orchestrator' ssh-argv.log
  1

The box now holds the digest setup stamped, read back off the command it
issued, and the image id that command created the container from.

  $ grep -c -E -- '--label bondi[.]spec-hash=[0-9a-f]{32} ' ssh-argv.log
  1
  $ cut -f1 "$BOX/container" | grep -c -E -- '^[0-9a-f]{32}$'
  1
  $ cut -f2 "$BOX/container"
  sha256:66a6306db78bf2dbf3487f293aa8d6990d8e506fdffab9cc43fe422becf886e4

The second setup, with nothing changed: the same configuration, and a registry
whose tag still names the image the container runs.

  $ : > "$SSH_ARGV_LOG"
  $ bondi-client setup > second.log 2>&1
  $ echo $?
  0

It still reached the orchestrator, so the absences below are the orchestrator
being left alone rather than a run that never got to it. The image was pulled,
both ids were read after the pull, and the run said it kept the container.

  $ grep -c -x -F -- "docker pull 'mlopez1506/bondi-server:0.25.0'" ssh-argv.log
  1
  $ grep -c -F -- "docker image inspect -f '{{.Id}}' 'mlopez1506/bondi-server:0.25.0'" ssh-argv.log
  1
  $ grep -F -- 'skipping' second.log
  bondi-orchestrator container is already running on server 127.0.0.1: 0.25.0, skipping...

Nothing stopped, removed or created the orchestrator, and the cron payload
directory was not copied out, because no recreate was coming. With no `docker
stop`, the job that might be running inside the container goes on running.

  $ grep -c -E -- 'docker (stop|rm --force) bondi-orchestrator|docker run -d --name bondi-orchestrator' ssh-argv.log
  0
  [1]
  $ grep -c -F -- 'docker cp -a' ssh-argv.log
  0
  [1]
  $ grep -c -F -- 'Preserved the cron payload' second.log
  0
  [1]

The affirmative arm, on the same box and the same configuration: the registry's
tag now names a new image, as an updated `latest` would. The digest still
matches, so only the ids read after the pull can tell, and they differ.

  $ echo 'sha256:f97baa533a26513c453a362be331a43eb60214302f449c16571b23cea141dce4' > "$BOX/registry"
  $ : > "$SSH_ARGV_LOG"
  $ bondi-client setup > third.log 2>&1
  $ echo $?
  0
  $ grep -F -- 'names a new image' third.log
  bondi-orchestrator on server 127.0.0.1: mlopez1506/bondi-server:0.25.0 names a new image, stopping to restart...
  $ grep -c -E -- 'docker (stop|rm --force) bondi-orchestrator|docker run -d --name bondi-orchestrator' ssh-argv.log
  3

The replacement comes after the pull and after the check that read the ids,
and in its own order: the payload directory copied out, then the stop, the
removal and the create.

  $ PULL_AT=$(grep -n -x -F -- "docker pull 'mlopez1506/bondi-server:0.25.0'" ssh-argv.log | cut -d: -f1)
  $ CHECK_AT=$(grep -n -F -- "docker image inspect -f '{{.Id}}'" ssh-argv.log | cut -d: -f1)
  $ COPY_AT=$(grep -n -F -- 'docker cp -a' ssh-argv.log | cut -d: -f1)
  $ STOP_AT=$(grep -n -x -F -- 'docker stop bondi-orchestrator' ssh-argv.log | cut -d: -f1)
  $ RM_AT=$(grep -n -F -- 'docker rm --force bondi-orchestrator' ssh-argv.log | cut -d: -f1)
  $ RUN_AT=$(grep -n -F -- 'docker run -d --name bondi-orchestrator' ssh-argv.log | cut -d: -f1)
  $ test "$PULL_AT" -lt "$CHECK_AT" && test "$CHECK_AT" -lt "$COPY_AT" && test "$COPY_AT" -lt "$STOP_AT" && test "$STOP_AT" -lt "$RM_AT" && test "$RM_AT" -lt "$RUN_AT" && echo 'pulled, checked, then copied, stopped, removed and run'
  pulled, checked, then copied, stopped, removed and run

The replacement was created from the image the tag names now.

  $ cut -f2 "$BOX/container"
  sha256:f97baa533a26513c453a362be331a43eb60214302f449c16571b23cea141dce4
