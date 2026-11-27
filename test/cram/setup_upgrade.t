A `bondi setup` that upgrades the orchestrator and replaces an Alloy whose
configuration changed ends its account with one line naming both changes, each
with its reason. The run used to end on a sentence about corrections alone, so a
box whose two containers had just been replaced read the same as one where
nothing happened.

The fixtures are removed first so the file is re-runnable in a directory a
previous run has already written to.

  $ ROOT="$PWD"
  $ rm -rf box ssh-argv.log out.log failed.log

The box, as files the stub reads and writes. `<name>.container` is a running
container: the digest label it was created with, then the reference it was
created from. The orchestrator was created at 0.25.0, and Alloy carries a digest
no configuration of this manifest produces, so both differ from what this setup
would create.

  $ mkdir -p "$ROOT/box"
  $ export BOX="$ROOT/box"
  $ printf 'a-digest-0.25.0-stamped\tmlopez1506/bondi-server:0.25.0\n' > "$BOX/bondi-orchestrator.container"
  $ printf 'a-digest-of-another-config\tgrafana/alloy:v1.8.0\n' > "$BOX/bondi-alloy.container"

The stub answers in the shapes the docker CLI prints. Its catch-all is loud and
fails the run, so an unanticipated command says so here rather than failing an
assertion below for a reason no fixture chose.

  $ mkdir -p "$ROOT/bin"
  $ cat > "$ROOT/bin/ssh" <<'STUB'
  > #!/bin/sh
  > while [ $# -gt 0 ] && [ "$1" != "--" ]; do shift; done
  > shift
  > printf '%s\n' "$1" >> "$SSH_ARGV_LOG"
  > ORCH_REF='mlopez1506/bondi-server:0.30.0'
  > ALLOY_REF='grafana/alloy:v1.8.0'
  > listing() {
  >   if [ -f "$BOX/$1.container" ]; then
  >     printf 'running\t%s\t%s\n' "$(cut -f2 "$BOX/$1.container")" "$(cut -f1 "$BOX/$1.container")"
  >   fi
  > }
  > pull() {
  >   printf '%s: Pulling from %s\n' "${1##*:}" "${1%:*}"
  >   printf 'Status: Downloaded newer image for %s\n%s\n' "$1" "$1"
  > }
  > created() {
  >   hash=$(printf '%s\n' "$2" | tr ' ' '\n' | sed -n 's/^bondi[.]spec-hash=//p')
  >   printf '%s\t%s\n' "$hash" "$3" > "$BOX/$1.container"
  > }
  > case "$1" in
  >   "docker pull '$ORCH_REF'") pull "$ORCH_REF" ;;
  >   "docker pull '$ALLOY_REF'") pull "$ALLOY_REF" ;;
  >   'docker --version') echo 'Docker version 27.0.0, build deadbeef' ;;
  >   *BONDI_ALLOY_CURL_PRESENT*) echo BONDI_ALLOY_CURL_PRESENT ;;
  >   *BONDI_ALLOY_PORT_FREE*) echo BONDI_ALLOY_PORT_FREE ;;
  >   *BONDI_ACME_PRESENT*) echo 'BONDI_ACME_PRESENT root:root 600' ;;
  >   "sudo chown root:root '/etc/traefik/acme/acme.json'"*) : ;;
  >   *BONDI_NETWORK_PRESENT*) echo BONDI_NETWORK_PRESENT ;;
  >   *'name=^/bondi-orchestrator$'*'{{.State}}'*) listing bondi-orchestrator ;;
  >   *'name=^/bondi-orchestrator$'*"--format '{{.Image}}'") cut -f2 "$BOX/bondi-orchestrator.container" ;;
  >   *'name=^/bondi-alloy$'*'{{.State}}'*) listing bondi-alloy ;;
  >   # The closing report's own listings, which this file does not transcribe.
  >   'docker ps -a --format'*)
  >     printf 'bondi-orchestrator\t%s\trunning\n' "$(cut -f2 "$BOX/bondi-orchestrator.container")"
  >     printf 'bondi-alloy\t%s\trunning\n' "$(cut -f2 "$BOX/bondi-alloy.container")" ;;
  >   'docker ps -aq | while read -r id'*)
  >     printf '/bondi-orchestrator\tundeclared\t\t0\t2026-09-01T09:00:00.222222222Z\n'
  >     printf '/bondi-alloy\tundeclared\t\t0\t2026-09-01T09:00:00.222222222Z\n' ;;
  >   *'/var/spool/cron/crontabs/root'*) echo BONDI_CRONTAB_ABSENT ;;
  >   *BONDI_JOURNAL_PRESENT*) echo BONDI_JOURNAL_PRESENT ;;
  >   "sudo mkdir -p '/var/lib/bondi/alloy'") : ;;
  >   # Neither of Alloy's files is on the box ahead of its write, so the run has
  >   # no mode of its own to report; after the write each is at its declared mode.
  >   *BONDI_ALLOY_MODE_ABSENT*) echo BONDI_ALLOY_MODE_ABSENT ;;
  >   *'sudo stat -c %04a'*)
  >     case "$1" in *'alloy/env'*) echo 0600 ;; *) echo 0640 ;; esac ;;
  >   *'cat > '*'/etc/bondi/alloy/config.alloy'*) cat > /dev/null ;;
  >   *'cat > '*'/etc/bondi/alloy/env'*) cat > /dev/null ;;
  >   "sudo rm -rf '/etc/bondi/alloy'") : ;;
  >   'docker stop bondi-orchestrator' | 'docker stop bondi-alloy') : ;;
  >   'docker rm --force bondi-orchestrator'*) rm -f "$BOX/bondi-orchestrator.container" ;;
  >   'docker rm bondi-alloy') rm -f "$BOX/bondi-alloy.container" ;;
  >   'docker run -d --name bondi-orchestrator'*)
  >     if [ -n "$ORCH_RUN_FAILS" ]; then cat > /dev/null; echo 'docker: Error response from daemon: no space left on device.' >&2; exit 125; fi
  >     created bondi-orchestrator "$1" "$ORCH_REF"; echo 'f00dcafef00d' ;;
  >   *'http://127.0.0.1:12345/-/healthy'*) echo BONDI_ALLOY_HEALTHY ;;
  >   'docker run -d --name bondi-alloy'*)
  >     created bondi-alloy "$1" "$ALLOY_REF"; echo 'd671990dc2318f4b' ;;
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

The manifest pins 0.30.0.

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
  > traefik:
  >   domain_name: app.example.com
  >   image: traefik:v3.6.8
  >   acme_email: ops@example.com
  > bondi_server:
  >   version: "0.30.0"
  > alloy:
  >   image: grafana/alloy:v1.8.0
  >   collect: all
  >   grafana_cloud:
  >     instance_id: "123456"
  >     api_key: "glc_secret"
  >     endpoint: "https://logs-prod.grafana.net/loki/api/v1/push"
  > EOF

  $ : > "$SSH_ARGV_LOG"
  $ bondi-client setup > out.log 2>&1
  $ echo $?
  0

Both containers were replaced: each was stopped, removed and run again.

  $ grep -c -E -- 'docker (stop|rm --force) bondi-orchestrator|docker run -d --name bondi-orchestrator' ssh-argv.log
  3
  $ grep -c -E -- 'docker (stop|rm) bondi-alloy|docker run -d --name bondi-alloy' ssh-argv.log
  3

The line said ahead of the orchestrator's restart and the closing line give the
same reason, and the closing line names Alloy's beside it, in the order the run
made the two changes.

  $ grep -F -- 'stopping to restart' out.log
  bondi-orchestrator on server 127.0.0.1: version mismatch: running 0.25.0, want 0.30.0, stopping to restart...
  $ grep -F -- 'setup changed' out.log
  setup changed on server 127.0.0.1: orchestrator 0.25.0 → 0.30.0, Alloy recreated (config changed)

It is printed once, before the table.

  $ grep -c -- '^setup changed' out.log
  1
  $ CLOSING_AT=$(grep -n -- '^setup changed' out.log | cut -d: -f1)
  $ TABLE_AT=$(grep -n -F -- 'Server: 127.0.0.1' out.log | head -1 | cut -d: -f1)
  $ test "$CLOSING_AT" -lt "$TABLE_AT" && echo 'the closing line precedes the table'
  the closing line precedes the table

A replacement that stops after the old orchestrator was removed and before its
successor ran has still changed the box: the line says what the run took away,
and names no version, because none is running. The box is set back to the same
two containers, and the orchestrator's `docker run` is refused.

  $ printf 'a-digest-0.25.0-stamped\tmlopez1506/bondi-server:0.25.0\n' > "$BOX/bondi-orchestrator.container"
  $ printf 'a-digest-of-another-config\tgrafana/alloy:v1.8.0\n' > "$BOX/bondi-alloy.container"
  $ : > "$SSH_ARGV_LOG"
  $ ORCH_RUN_FAILS=1 bondi-client setup > failed.log 2>&1
  [1]
  $ grep -c -F -- 'docker rm --force bondi-orchestrator' ssh-argv.log
  1
  $ grep -F -- 'setup changed' failed.log
  setup changed on server 127.0.0.1: orchestrator removed
