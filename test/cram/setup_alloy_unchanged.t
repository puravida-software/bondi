A second `bondi setup` leaves an unchanged Alloy running. It used to be stopped,
removed and run again on every setup, its River configuration and credentials
rewritten in between, so every run cut the box's log shipping for as long as
the recreate took. What decides "unchanged" is the digest setup stamps on the
container it creates: it is taken over the run command, the River configuration
and the credentials file, so a change to any of them, such as a different
`collect`, is a change to the container, and Alloy is replaced after its image
is pulled.

The fixtures are removed first so the file is re-runnable in a directory a
previous run has already written to.

  $ ROOT="$PWD"
  $ rm -rf box ssh-argv.log first.log second.log third.log mode-config.log mode-env.log missing-config.log missing-env.log retry-changed.log retry-unchanged.log retry-before.alloy retry-after.alloy

The box, as files the stub reads and writes, one set per container setup runs
by name. `<name>.registry` is the image id the registry's tag names.
`<name>.tag` is the image id the box's own copy of the tag names, written by a
pull. `<name>.container` is the container, when there is one: the digest label
it was created with and the id of the image it was created from, both written by
the `docker run` that created it. `config.alloy` and `env` are the River configuration and the credentials file
on the box, written by setup's writes and deleted with Alloy's config directory;
`<file>.mode` is a mode the box's file was given by hand.

So the digest the listing reports is never written by this file. It is the one
setup stamped on the container it created, on the first run below, and the
second run compares it against the one it computes afresh from the same
configuration: equal values, computed twice. The ids are the docker CLI's full
form, as `docker image inspect -f '{{.Id}}'` prints them.

  $ mkdir -p "$ROOT/box"
  $ export BOX="$ROOT/box"
  $ for name in bondi-orchestrator bondi-alloy; do echo 'sha256:66a6306db78bf2dbf3487f293aa8d6990d8e506fdffab9cc43fe422becf886e4' > "$BOX/$name.registry"; : > "$BOX/$name.tag"; done

The stub answers the box in the shapes the docker CLI prints. The listing's
image column is the reference the container was created from only while that
reference still names the container's image; once a pull has moved the tag, the
column is the container's image id cut to twelve hex digits. A pull that fetches
a new image says `Downloaded newer image`, where one that finds the image
already there says `Image is up to date`.

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
  > ORCH_REF='mlopez1506/bondi-server:0.25.0'
  > ALLOY_REF='grafana/alloy:v1.8.0'
  > ref_of() {
  >   case "$1" in
  >     bondi-orchestrator) printf '%s' "$ORCH_REF" ;;
  >     bondi-alloy) printf '%s' "$ALLOY_REF" ;;
  >   esac
  > }
  > image_column() {
  >   id=$(cut -f2 "$BOX/$1.container")
  >   if [ "$id" = "$(cat "$BOX/$1.tag")" ]; then
  >     ref_of "$1"
  >   else
  >     printf '%s' "$id" | sed 's/^sha256:\(.\{12\}\).*/\1/'
  >   fi
  > }
  > listing() {
  >   if [ -f "$BOX/$1.container" ]; then
  >     printf 'running\t%s\t%s\n' "$(image_column "$1")" "$(cut -f1 "$BOX/$1.container")"
  >   fi
  > }
  > mode_of() {
  >   if [ -f "$BOX/$1.mode" ]; then cat "$BOX/$1.mode"
  >   elif [ "$1" = env ]; then echo 0600
  >   else echo 0640
  >   fi
  > }
  > pull() {
  >   ref=$(ref_of "$1")
  >   printf '%s: Pulling from %s\n' "${ref##*:}" "${ref%:*}"
  >   printf 'Digest: %s\n' "$(cat "$BOX/$1.registry")"
  >   if [ "$(cat "$BOX/$1.tag")" = "$(cat "$BOX/$1.registry")" ]; then
  >     printf 'Status: Image is up to date for %s\n%s\n' "$ref" "$ref"
  >   else
  >     printf 'Status: Downloaded newer image for %s\n%s\n' "$ref" "$ref"
  >   fi
  >   cp -f "$BOX/$1.registry" "$BOX/$1.tag"
  > }
  > created() {
  >   hash=$(printf '%s\n' "$2" | tr ' ' '\n' | sed -n 's/^bondi[.]spec-hash=//p')
  >   printf '%s\t%s\n' "$hash" "$(cat "$BOX/$1.tag")" > "$BOX/$1.container"
  > }
  > case "$1" in
  >   "docker pull '$ORCH_REF'") pull bondi-orchestrator ;;
  >   "docker pull '$ALLOY_REF'") pull bondi-alloy ;;
  >   'docker --version') echo 'Docker version 27.0.0, build deadbeef' ;;
  >   *BONDI_ALLOY_CURL_PRESENT*) echo BONDI_ALLOY_CURL_PRESENT ;;
  >   *BONDI_ALLOY_PORT_FREE*) echo "${ALLOY_PORT:-BONDI_ALLOY_PORT_FREE}" ;;
  >   *BONDI_ACME_PRESENT*) echo BONDI_ACME_PRESENT ;;
  >   'sudo chown root:root /etc/traefik/acme/acme.json'*) : ;;
  >   'docker network inspect'*) : ;;
  >   # The probe's listing and the version read are disjoint by construction:
  >   # the probe's format names a state, and the version read's pattern is
  >   # anchored on the whole of `--format '{{.Image}}'`.
  >   *'name=^/bondi-orchestrator$'*'{{.State}}'*) listing bondi-orchestrator ;;
  >   *'name=^/bondi-orchestrator$'*"--format '{{.Image}}'") image_column bondi-orchestrator; echo ;;
  >   *'name=^/bondi-alloy$'*'{{.State}}'*) listing bondi-alloy ;;
  >   # The image check, both ids in one line: the tag's, then the container's.
  >   "docker image inspect -f '{{.Id}}' '$ORCH_REF' && docker container inspect -f '{{.Image}}' 'bondi-orchestrator'")
  >     cat "$BOX/bondi-orchestrator.tag"; cut -f2 "$BOX/bondi-orchestrator.container" ;;
  >   "docker image inspect -f '{{.Id}}' '$ALLOY_REF' && docker container inspect -f '{{.Image}}' 'bondi-alloy'")
  >     cat "$BOX/bondi-alloy.tag"; cut -f2 "$BOX/bondi-alloy.container" ;;
  >   # The closing report's own listings, which this file does not transcribe.
  >   'docker ps -a --format'*)
  >     printf 'bondi-orchestrator\t%s\trunning\n' "$(image_column bondi-orchestrator)"
  >     printf 'bondi-alloy\t%s\trunning\n' "$(image_column bondi-alloy)" ;;
  >   'docker ps -aq | while read -r id'*)
  >     printf '/bondi-orchestrator\tundeclared\t\t0\t2026-09-01T09:00:00.222222222Z\n'
  >     printf '/bondi-alloy\tundeclared\t\t0\t2026-09-01T09:00:00.222222222Z\n' ;;
  >   *'/var/spool/cron/crontabs/root'*) echo BONDI_CRONTAB_ABSENT ;;
  >   *BONDI_CRON_PAYLOAD_LISTED*)
  >     echo BONDI_CRON_PAYLOAD_LISTED
  >     echo BONDI_CRON_PAYLOAD_END ;;
  >   *BONDI_JOURNAL_PRESENT*) echo BONDI_JOURNAL_PRESENT ;;
  >   "sudo mkdir -p '/var/lib/bondi/alloy'") : ;;
  >   # A file's mode before setup would write it: the absent marker while
  >   # there is no file, and its mode once there is one. A mode file stands for
  >   # a mode the box was given by hand; a write clears it, as a write does.
  >   *BONDI_ALLOY_MODE_ABSENT*)
  >     case "$1" in *'alloy/env'*) f=env ;; *) f=config.alloy ;; esac
  >     if [ -f "$BOX/$f" ]; then mode_of "$f"; else echo BONDI_ALLOY_MODE_ABSENT; fi ;;
  >   *'sudo stat -c %04a'*)
  >     case "$1" in *'alloy/env'*) mode_of env ;; *) mode_of config.alloy ;; esac ;;
  >   'sudo chmod '*)
  >     case "$1" in *'alloy/env'*) f=env ;; *) f=config.alloy ;; esac
  >     echo "$1" | cut -d' ' -f3 > "$BOX/$f.mode" ;;
  >   *'cat > '*'/etc/bondi/alloy/config.alloy'*) cat > "$BOX/config.alloy"; rm -f "$BOX/config.alloy.mode" ;;
  >   *'cat > '*'/etc/bondi/alloy/env'*) cat > "$BOX/env"; rm -f "$BOX/env.mode" ;;
  >   "sudo rm -rf '/etc/bondi/alloy'") rm -f "$BOX/config.alloy" "$BOX/env" "$BOX/config.alloy.mode" "$BOX/env.mode" ;;
  >   'docker stop bondi-orchestrator' | 'docker stop bondi-alloy') : ;;
  >   'docker rm --force bondi-orchestrator'*) rm -f "$BOX/bondi-orchestrator.container" ;;
  >   'docker rm bondi-alloy') rm -f "$BOX/bondi-alloy.container" ;;
  >   # The creates. What the box records is what the command carried: the
  >   # digest label setup stamped on it, and the image its tag names now.
  >   'docker run -d --name bondi-orchestrator'*)
  >     created bondi-orchestrator "$1"; echo 'f00dcafef00d' ;;
  >   # The health wait that follows the run, answered as a running Alloy
  >   # answers it. Without this arm the probe falls through to *) and answers
  >   # nothing, which setup reads as no verdict and fails the run on.
  >   *'http://127.0.0.1:12345/-/healthy'*) echo BONDI_ALLOY_HEALTHY ;;
  >   'docker run -d --name bondi-alloy'*)
  >     created bondi-alloy "$1"; echo 'd671990dc2318f4b' ;;
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
  > alloy:
  >   image: grafana/alloy:v1.8.0
  >   collect: all
  >   grafana_cloud:
  >     instance_id: "123456"
  >     api_key: "glc_secret"
  >     endpoint: "https://logs-prod.grafana.net/loki/api/v1/push"
  > EOF

The first setup, on a box with neither container: both are pulled and created,
and Alloy's configuration is written ahead of its run.

  $ : > "$SSH_ARGV_LOG"
  $ bondi-client setup > first.log 2>&1
  $ echo $?
  0
  $ grep -c -F -- 'docker run -d --name bondi-alloy' ssh-argv.log
  1
  $ grep -c -E -- '--name bondi-alloy .*--label bondi[.]spec-hash=[0-9a-f]{32} ' ssh-argv.log
  1
  $ cp -f "$BOX/config.alloy" first-config.alloy

The second setup, with nothing changed: the same configuration, and registries
whose tags still name the images the containers run.

  $ : > "$SSH_ARGV_LOG"
  $ bondi-client setup > second.log 2>&1
  $ echo $?
  0

It still reached Alloy, so the absences below are Alloy being left alone rather
than a run that never got to it. Its image was pulled, both ids were read after
the pull, and the run said it kept the container.

  $ grep -c -x -F -- "docker pull 'grafana/alloy:v1.8.0'" ssh-argv.log
  1
  $ grep -c -F -- "docker image inspect -f '{{.Id}}' 'grafana/alloy:v1.8.0'" ssh-argv.log
  1
  $ grep -F -- 'bondi-alloy container is already running' second.log
  bondi-alloy container is already running on server 127.0.0.1: grafana/alloy:v1.8.0, skipping...

Nothing stopped, removed or ran Alloy, and neither its River configuration nor
its credentials file was written: the configuration on the box is the one the
first run wrote.

  $ grep -c -E -- 'docker (stop|rm) bondi-alloy|docker run -d --name bondi-alloy' ssh-argv.log
  0
  [1]
  $ grep -c -E -- 'cat > [^&]*config[.]alloy|cat > [^&]*alloy/env' ssh-argv.log
  0
  [1]
  $ cmp first-config.alloy "$BOX/config.alloy" && echo 'the config on the box is the first run'"'"'s'
  the config on the box is the first run's

A kept Alloy's files are checked, not rewritten. A config file at 0644 is
brought to the declared 0640 with a chmod, in place, and the mode is read back:
the account says what the box had, and Alloy is neither stopped, removed nor
run.

  $ echo 0644 > "$BOX/config.alloy.mode"
  $ : > "$SSH_ARGV_LOG"
  $ bondi-client setup > mode-config.log 2>&1
  $ echo $?
  0
  $ grep -c -x -F -- "sudo chmod 0640 '/etc/bondi/alloy/config.alloy'" ssh-argv.log
  1
  $ grep -c -F -- "sudo stat -c %04a '/etc/bondi/alloy/config.alloy'" ssh-argv.log
  1
  $ grep -F -- 'config.alloy on server 127.0.0.1 was mode 0644, applied 0640' mode-config.log
  /etc/bondi/alloy/config.alloy on server 127.0.0.1 was mode 0644, applied 0640
  $ grep -c -E -- 'docker (stop|rm) bondi-alloy|docker run -d --name bondi-alloy' ssh-argv.log
  0
  [1]

The credentials file holds the key, so its mode is held to the same standard: at
0644 it is brought to 0600 and read back, and Alloy is left running.

  $ echo 0644 > "$BOX/env.mode"
  $ : > "$SSH_ARGV_LOG"
  $ bondi-client setup > mode-env.log 2>&1
  $ echo $?
  0
  $ grep -c -x -F -- "sudo chmod 0600 '/etc/bondi/alloy/env'" ssh-argv.log
  1
  $ grep -c -F -- "sudo stat -c %04a '/etc/bondi/alloy/env'" ssh-argv.log
  1
  $ grep -F -- 'env on server 127.0.0.1 was mode 0644, applied 0600' mode-env.log
  /etc/bondi/alloy/env on server 127.0.0.1 was mode 0644, applied 0600
  $ grep -c -E -- 'docker (stop|rm) bondi-alloy|docker run -d --name bondi-alloy' ssh-argv.log
  0
  [1]

A file the container mounts that is not on the box is not left alone: Alloy
would run until the daemon next restarted it and then fail to start, with setup
having reported success. Either file missing is a replacement, in full.

  $ rm -f "$BOX/config.alloy"
  $ : > "$SSH_ARGV_LOG"
  $ bondi-client setup > missing-config.log 2>&1
  $ echo $?
  0
  $ grep -F -- 'is missing a file it mounts' missing-config.log
  Alloy on server 127.0.0.1 is missing a file it mounts, replacing it...
  $ grep -c -E -- 'docker (stop|rm) bondi-alloy|docker run -d --name bondi-alloy' ssh-argv.log
  3
  $ test -f "$BOX/config.alloy" && test -f "$BOX/env" && echo 'both files are on the box again'
  both files are on the box again

  $ rm -f "$BOX/env"
  $ : > "$SSH_ARGV_LOG"
  $ bondi-client setup > missing-env.log 2>&1
  $ echo $?
  0
  $ grep -F -- 'is missing a file it mounts' missing-env.log
  Alloy on server 127.0.0.1 is missing a file it mounts, replacing it...
  $ grep -c -E -- 'docker (stop|rm) bondi-alloy|docker run -d --name bondi-alloy' ssh-argv.log
  3
  $ grep -c -E -- 'cat > [^&]*config[.]alloy|cat > [^&]*alloy/env' ssh-argv.log
  2

The affirmative arm, on the same box: the River configuration changes, because
the file now collects only the services' logs. The digest the running Alloy
carries no longer matches what this setup would create, so Alloy is replaced,
and its image is still pulled first.

  $ sed 's/collect: all/collect: services_only/' bondi.yaml > bondi.yaml.next && mv -f bondi.yaml.next bondi.yaml
  $ : > "$SSH_ARGV_LOG"
  $ bondi-client setup > third.log 2>&1
  $ echo $?
  0
  $ grep -c -E -- 'docker (stop|rm) bondi-alloy|docker run -d --name bondi-alloy' ssh-argv.log
  3
  $ cmp -s first-config.alloy "$BOX/config.alloy" || echo 'the config on the box was rewritten'
  the config on the box was rewritten

The replacement comes after the pull, in its own order: the stop, the removal
of the container and its config directory, the River configuration and the
credentials written again, then the run that reads them.

  $ PULL_AT=$(grep -n -x -F -- "docker pull 'grafana/alloy:v1.8.0'" ssh-argv.log | cut -d: -f1)
  $ STOP_AT=$(grep -n -x -F -- 'docker stop bondi-alloy' ssh-argv.log | cut -d: -f1)
  $ RM_AT=$(grep -n -x -F -- 'docker rm bondi-alloy' ssh-argv.log | cut -d: -f1)
  $ CONFIG_AT=$(grep -n -E -- 'cat > [^&]*config[.]alloy' ssh-argv.log | cut -d: -f1)
  $ ENV_AT=$(grep -n -E -- 'cat > [^&]*alloy/env' ssh-argv.log | cut -d: -f1)
  $ RUN_AT=$(grep -n -F -- 'docker run -d --name bondi-alloy' ssh-argv.log | cut -d: -f1)
  $ test "$PULL_AT" -lt "$STOP_AT" && test "$STOP_AT" -lt "$RM_AT" && test "$RM_AT" -lt "$CONFIG_AT" && test "$CONFIG_AT" -lt "$ENV_AT" && test "$ENV_AT" -lt "$RUN_AT" && echo 'pulled, then stopped, removed, configured and run'
  pulled, then stopped, removed, configured and run

The orchestrator was left alone throughout: its configuration did not change,
so the River configuration's change touched only the container that reads it.

  $ grep -c -E -- 'docker (stop|rm --force) bondi-orchestrator|docker run -d --name bondi-orchestrator' ssh-argv.log
  0
  [1]

The retry limit is part of the River configuration, so changing it is a change
to the container: Alloy is replaced, after its image is pulled, and the
configuration on the box carries the new limit.

  $ cp -f "$BOX/config.alloy" retry-before.alloy
  $ awk '{ print } /^    endpoint: / { print "    max_backoff_retries: 5" }' bondi.yaml > bondi.yaml.next && mv -f bondi.yaml.next bondi.yaml
  $ grep -c -x -F -- '    max_backoff_retries: 5' bondi.yaml
  1
  $ : > "$SSH_ARGV_LOG"
  $ bondi-client setup > retry-changed.log 2>&1
  $ echo $?
  0
  $ grep -c -E -- 'docker (stop|rm) bondi-alloy|docker run -d --name bondi-alloy' ssh-argv.log
  3
  $ PULL_AT=$(grep -n -x -F -- "docker pull 'grafana/alloy:v1.8.0'" ssh-argv.log | cut -d: -f1)
  $ STOP_AT=$(grep -n -x -F -- 'docker stop bondi-alloy' ssh-argv.log | cut -d: -f1)
  $ test "$PULL_AT" -lt "$STOP_AT" && echo 'pulled before it was stopped'
  pulled before it was stopped
  $ grep -c -F -- 'max_backoff_retries = 5' "$BOX/config.alloy"
  1
  $ grep -c -F -- 'max_backoff_retries' retry-before.alloy
  0
  [1]

The same limit on the next setup is no change: the digest this run computes
from the manifest, afresh, equals the one the run above stamped on the
container, so Alloy is pulled and left running, and nothing is written.

  $ cp -f "$BOX/config.alloy" retry-after.alloy
  $ : > "$SSH_ARGV_LOG"
  $ bondi-client setup > retry-unchanged.log 2>&1
  $ echo $?
  0
  $ grep -c -x -F -- "docker pull 'grafana/alloy:v1.8.0'" ssh-argv.log
  1
  $ grep -F -- 'bondi-alloy container is already running' retry-unchanged.log
  bondi-alloy container is already running on server 127.0.0.1: grafana/alloy:v1.8.0, skipping...
  $ grep -c -E -- 'docker (stop|rm) bondi-alloy|docker run -d --name bondi-alloy' ssh-argv.log
  0
  [1]
  $ grep -c -E -- 'cat > [^&]*config[.]alloy|cat > [^&]*alloy/env' ssh-argv.log
  0
  [1]
  $ cmp retry-after.alloy "$BOX/config.alloy" && echo 'the config on the box is the one the limit change wrote'
  the config on the box is the one the limit change wrote
