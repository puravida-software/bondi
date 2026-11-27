Alloy is replaced by stopping and removing the one the box has and running a
new one. Two facts about the box decide whether the new one can come up: curl
is there to ask it whether it is healthy, and the port its HTTP server binds,
12345, is free or already Alloy's own. Both are read before anything is stopped,
so a box that fails either keeps the Alloy it had.

  $ ROOT="$PWD"

The stub reports a stopped alloy container and an orchestrator already running
the declared version, so the run reduces to replacing alloy. The two probes are
answered from $ALLOY_CURL and $ALLOY_PORT, so a box that fails a check and one
that passes are the same fixture with one variable changed.

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
  >     printf '%s: Pulling from %s\n' "${ref##*:}" "${ref%:*}"
  >     printf 'Digest: sha256:66a6306db78bf2dbf3487f293aa8d6990d8e506fdffab9cc43fe422becf886e4\n'
  >     printf 'Status: Image is up to date for %s\n%s\n' "$ref" "$ref" ;;
  >   *BONDI_ALLOY_CURL_PRESENT*) echo "${ALLOY_CURL:-BONDI_ALLOY_CURL_PRESENT}" ;;
  >   *BONDI_ALLOY_PORT_FREE*) echo "${ALLOY_PORT:-BONDI_ALLOY_PORT_FREE}" ;;
  >   *BONDI_NETWORK_PRESENT*) echo BONDI_NETWORK_PRESENT ;;
  >   *BONDI_ACME_PRESENT*) echo 'BONDI_ACME_PRESENT root:root 600' ;;
  >   *BONDI_JOURNAL_PRESENT*) echo BONDI_JOURNAL_PRESENT ;;
  >   'docker --version') echo 'Docker version 27.0.0, build deadbeef' ;;
  >   # The orchestrator as a 0.25.0 setup created it, so it is checked and kept.
  >   *'name=^/bondi-orchestrator$'*'{{.State}}'*)
  >     printf 'running\tmlopez1506/bondi-server:0.25.0\t92eba0ed2e6c82a23cd21b6c85e10e71\n' ;;
  >   'docker image inspect '*)
  >     printf 'sha256:66a6306db78bf2dbf3487f293aa8d6990d8e506fdffab9cc43fe422becf886e4\nsha256:66a6306db78bf2dbf3487f293aa8d6990d8e506fdffab9cc43fe422becf886e4\n' ;;
  >   # A stopped alloy container, so that a setup which got past its checks
  >   # would stop and remove it before running the new one.
  >   *'ps -a --filter name=^/bondi-alloy$'*'{{.State}}'*)
  >     printf 'exited\tgrafana/alloy:v1.8.0\t\n' ;;
  >   *BONDI_ALLOY_MODE_ABSENT*) echo BONDI_ALLOY_MODE_ABSENT ;;
  >   *'sudo stat -c %04a'*) echo 0640 ;;
  >   *'cat > '*'/etc/bondi/alloy/env'*) : ;;
  >   *'--name bondi-alloy'*) echo 'd671990dc2318f4b' ;;
  >   # The health probe, matched on the address it asks so that a probe of any
  >   # other port falls through to *) and answers nothing.
  >   *'http://127.0.0.1:12345/-/healthy'*) echo "$ALLOY_HEALTH" ;;
  >   *'/var/spool/cron/crontabs/root'*) echo BONDI_CRONTAB_ABSENT ;;
  >   *BONDI_CRON_PAYLOAD_LISTED*)
  >     echo BONDI_CRON_PAYLOAD_LISTED
  >     echo BONDI_CRON_PAYLOAD_END ;;
  >   *'RestartPolicy'*) echo unless-stopped ;;
  >   *'name=^/bondi-orchestrator$'*"--format '{{.Image}}'") echo 'mlopez1506/bondi-server:0.25.0' ;;
  >   'attempt=0; while'*) : ;;
  >   *'bondi-server check'*) echo '{"ready":true,"probes":[]}' ;;
  >   'docker logs --tail'*) echo 'bondi check: diagnostic sink is writable' ;;
  >   *'bondi-server status'*) echo 'this fixture does not answer the report' >&2; exit 1 ;;
  >   *) : ;;
  > esac
  > STUB
  $ chmod +x "$ROOT/bin/ssh"
  $ export PATH="$ROOT/bin:$PATH"
  $ export SSH_ARGV_LOG="$PWD/ssh-argv.log"
  $ : > "$SSH_ARGV_LOG"
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
  > alloy:
  >   grafana_cloud:
  >     instance_id: "123456"
  >     api_key: "glc_secret"
  >     endpoint: "https://logs-prod.grafana.net/loki/api/v1/push"
  > EOF

The box has no curl. Setup refuses, names the port the wait would have asked
on, and stops nothing: the log of every command it sent holds no stop, no
removal and no run of alloy.

  $ ALLOY_CURL=BONDI_ALLOY_CURL_MISSING bondi-client setup > out.log 2>&1
  [1]
  $ grep -F -- 'no curl on its PATH' out.log
  Error: the box has no curl on its PATH, so setup could not ask Alloy whether it is healthy on port 12345 once started. Nothing was stopped. Install curl on the box and run setup again.
  $ grep -c -E -- "docker stop 'bondi-alloy'|docker stop bondi-alloy|docker rm|--name bondi-alloy" ssh-argv.log
  0
  [1]

Something that is not Alloy holds port 12345. The same refusal, this time naming
the port as held, and again nothing is stopped, removed or run.

  $ : > "$SSH_ARGV_LOG"
  $ ALLOY_PORT=BONDI_ALLOY_PORT_HELD bondi-client setup > out.log 2>&1
  [1]
  $ grep -F -- 'port 12345 on the box is held' out.log
  Error: port 12345 on the box is held by a process that is not the bondi-alloy container, and Alloy's HTTP server binds that port, so a replacement would exit at start. Nothing was stopped. Free the port, or stop what holds it, and run setup again.
  $ grep -c -E -- "docker stop|docker rm|--name bondi-alloy" ssh-argv.log
  0
  [1]

A host that answers neither question is no pass. The probe printing nothing is
what a stub gives for a command it does not know, and what a host gives when
its shell printed nothing.

  $ : > "$SSH_ARGV_LOG"
  $ ALLOY_PORT=BONDI_ALLOY_PORT_UNREADABLE bondi-client setup > out.log 2>&1
  [1]
  $ grep -c -F -- 'could not read whether port 12345 on the box is free' out.log
  1
  $ grep -c -E -- "docker stop|docker rm|--name bondi-alloy" ssh-argv.log
  0
  [1]

The affirmative arm: the same box with curl and a free port. Setup goes on to
stop, remove and run alloy, so the absences above are the checks' doing and not
a fixture that never reached the stop.

  $ : > "$SSH_ARGV_LOG"
  $ ALLOY_HEALTH=BONDI_ALLOY_HEALTHY bondi-client setup > out.log 2>&1
  $ grep -c -E -- "docker stop|docker rm|--name bondi-alloy" ssh-argv.log
  3
