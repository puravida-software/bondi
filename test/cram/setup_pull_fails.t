Setup pulls a container's image before it stops or removes the container. Left
to `docker run`, the fetch happened after the old container was already gone,
so a registry that was down or a version never published left the box with no
orchestrator, and every cron line failing until a later setup succeeded.

  $ ROOT="$PWD"
  $ export FIXTURES="$PWD/../client/fixtures/docker_cli"

The stub answers `docker pull` with captures of the docker CLI, read from
test/client/fixtures/docker_cli: on success the lines it writes to stdout, and
for a reference that cannot be pulled, exit status 1 with the daemon's refusal
on stderr and nothing on stdout. $PULL_FAIL_REF names the one reference whose
pull fails, $PULL_FAIL_FIXTURE the capture it prints, and $ORCHESTRATOR_TAG
the version the box's orchestrator is running.

  $ mkdir -p "$ROOT/bin"
  $ cat > "$ROOT/bin/ssh" <<'STUB'
  > #!/bin/sh
  > while [ $# -gt 0 ] && [ "$1" != "--" ]; do shift; done
  > shift
  > printf '%s\n' "$1" >> "$SSH_ARGV_LOG"
  > cat > /dev/null
  > case "$1" in
  >   'docker pull '*)
  >     ref=$(printf '%s\n' "$1" | sed "s/^docker pull '\(.*\)'\$/\1/")
  >     if [ "$ref" = "$PULL_FAIL_REF" ]; then
  >       cat "$PULL_FAIL_FIXTURE" >&2
  >       exit 1
  >     fi
  >     cat "$FIXTURES/pull_up_to_date.out" ;;
  >   *BONDI_ALLOY_CURL_PRESENT*) echo BONDI_ALLOY_CURL_PRESENT ;;
  >   *BONDI_ALLOY_PORT_FREE*) echo "${ALLOY_PORT:-BONDI_ALLOY_PORT_FREE}" ;;
  >   *BONDI_NETWORK_PRESENT*) echo BONDI_NETWORK_PRESENT ;;
  >   *BONDI_ACME_PRESENT*) echo 'BONDI_ACME_PRESENT root:root 600' ;;
  >   'docker --version') echo 'Docker version 27.0.0, build deadbeef' ;;
  >   *'name=^/bondi-orchestrator$'*'{{.State}}'*)
  >     printf 'running\tmlopez1506/bondi-server:%s\t\n' "$ORCHESTRATOR_TAG" ;;
  >   *'ps -a --filter name=^/bondi-alloy$'*'{{.State}}'*)
  >     printf 'running\tgrafana/alloy:v1.8.0\t\n' ;;
  >   *BONDI_JOURNAL_PRESENT*) echo BONDI_JOURNAL_PRESENT ;;
  >   *BONDI_ALLOY_MODE_ABSENT*) echo 0640 ;;
  >   *'sudo stat -c %04a'*) echo 0640 ;;
  >   # The health wait that follows the run, answered as a running Alloy
  >   # answers it. Without this arm the probe falls through to *) and answers
  >   # nothing, which setup reads as no verdict and fails the run on.
  >   *'http://127.0.0.1:12345/-/healthy'*) echo BONDI_ALLOY_HEALTHY ;;
  >   *'--name bondi-alloy'*) echo 'd671990dc2318f4b' ;;
  >   'attempt=0; while'*) : ;;
  >   *'bondi-server check'*) echo '{"ready":true,"probes":[]}' ;;
  >   'docker logs --tail'*) echo 'bondi check: diagnostic sink is writable' ;;
  >   *'/var/spool/cron/crontabs/root'*) echo BONDI_CRONTAB_ABSENT ;;
  >   *BONDI_CRON_PAYLOAD_LISTED*)
  >     echo BONDI_CRON_PAYLOAD_LISTED
  >     echo BONDI_CRON_PAYLOAD_END ;;
  >   *'RestartPolicy'*) echo unless-stopped ;;
  >   *'name=^/bondi-orchestrator$'*"--format '{{.Image}}'")
  >     printf 'mlopez1506/bondi-server:%s\n' "$ORCHESTRATOR_TAG" ;;
  >   *'bondi-server status'*) echo 'this fixture does not answer the report' >&2; exit 1 ;;
  >   *) : ;;
  > esac
  > STUB
  $ chmod +x "$ROOT/bin/ssh"
  $ export PATH="$ROOT/bin:$PATH"
  $ export SSH_ARGV_LOG="$PWD/ssh-argv.log"
  $ : > "$SSH_ARGV_LOG"

The box runs 0.24.2 and the file declares 0.25.0, so the plan replaces the
orchestrator, and the version it asks for is one the registry does not hold.

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
  >   version: "0.25.0"
  > EOF

  $ PULL_FAIL_FIXTURE="$FIXTURES/pull_unknown_tag.err" ORCHESTRATOR_TAG=0.24.2 PULL_FAIL_REF=mlopez1506/bondi-server:0.25.0 bondi-client setup > out.log 2> err.log
  [1]

The run fails, and what it prints on stderr names the image it could not pull,
followed by the host's own words and the phases the run never reached.

  $ cat err.log
  Error: could not pull mlopez1506/bondi-server:0.25.0: command failed (1): Error response from daemon: failed to resolve reference "localhost:45123/obsimg:nope": localhost:45123/obsimg:nope: not found
  setup stopped part-way through the orchestrator phase on server 127.0.0.1, so these phases did not run: alloy.

The pull was issued, and the orchestrator that was running is still the one
running: nothing stopped it, removed it, or ran a replacement under its name.

  $ grep -c -F -- "docker pull 'mlopez1506/bondi-server:0.25.0'" ssh-argv.log
  1
  $ grep -c -E -- 'docker (stop|rm --force) bondi-orchestrator|docker run -d --name bondi-orchestrator' ssh-argv.log
  0
  [1]

The affirmative half: the same box, with the pull succeeding, is stopped,
removed and run, and the pull comes ahead of all three. Without it, the count
above would hold for a run that never reached the orchestrator at all.

  $ : > "$SSH_ARGV_LOG"
  $ ORCHESTRATOR_TAG=0.24.2 bondi-client setup > out.log 2> err.log
  $ grep -E -- '^Pulled' out.log
  Pulled mlopez1506/bondi-server:0.25.0 on server 127.0.0.1
  $ grep -c -E -- 'docker (stop|rm --force) bondi-orchestrator|docker run -d --name bondi-orchestrator' ssh-argv.log
  3
  $ awk '/^docker pull / && !pull { pull = NR } /^docker stop bondi-orchestrator/ && !stop { stop = NR } END { print (pull && stop && pull < stop) ? "the pull is first" : "out of order" }' ssh-argv.log
  the pull is first

The same rule holds for alloy. Here the orchestrator is current, and the alloy
image the file declares is one the registry does not hold: the run fails naming
it, and the alloy that was running is neither stopped nor removed.

  $ cat >> bondi.yaml <<'EOF'
  > alloy:
  >   image: grafana/alloy:v9.9.9
  >   grafana_cloud:
  >     instance_id: "123456"
  >     api_key: "glc_secret"
  >     endpoint: "https://logs-prod.grafana.net/loki/api/v1/push"
  > EOF
  $ : > "$SSH_ARGV_LOG"
  $ PULL_FAIL_FIXTURE="$FIXTURES/pull_registry_unreachable.err" ORCHESTRATOR_TAG=0.25.0 PULL_FAIL_REF=grafana/alloy:v9.9.9 bondi-client setup > out.log 2> err.log
  [1]
  $ grep -F -- 'could not pull' err.log
  Error: could not pull grafana/alloy:v9.9.9: command failed (1): Error response from daemon: failed to resolve reference "localhost:45124/obsimg:t": failed to do request: Head "https://localhost:45124/v2/obsimg/manifests/t": dial tcp 127.0.0.1:45124: connect: connection refused
  $ grep -c -F -- "docker pull 'grafana/alloy:v9.9.9'" ssh-argv.log
  1
  $ grep -c -E -- 'docker (stop|rm) .*bondi-alloy|--name bondi-alloy' ssh-argv.log
  0
  [1]
