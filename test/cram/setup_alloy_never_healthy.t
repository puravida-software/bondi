An Alloy that cannot bind its HTTP port exits at start, and `docker run -d` has
already succeeded by then, so a setup that only ran the container would report
a dead Alloy as started. Setup waits, for a bounded time, for Alloy to answer
healthy on the box's loopback at the port it was given, and fails the run when
it never does.

  $ ROOT="$PWD"

The stub reports no alloy container and an orchestrator already running the
declared version, so the run reduces to starting alloy. The health probe is
answered from $ALLOY_HEALTH, so a box whose Alloy never answers and one whose
Alloy does are the same fixture with one variable changed.

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
  >   *BONDI_ALLOY_CURL_PRESENT*) echo BONDI_ALLOY_CURL_PRESENT ;;
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
  >   # No alloy container on the box.
  >   *'ps -a --filter name=^/bondi-alloy$'*'{{.State}}'*) : ;;
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

The probe never reports healthy. Setup started the container, then fails in the
alloy phase, and the failure names the port and says what may be holding it.

  $ ALLOY_HEALTH=BONDI_ALLOY_NEVER_HEALTHY bondi-client setup > out.log 2>&1
  [1]
  $ sed -n '/container started/,/setup stopped/p' out.log
  bondi-alloy container started on server 127.0.0.1: d671990dc2318f4b
  Error: Alloy did not answer healthy at http://127.0.0.1:12345/-/healthy before setup gave up waiting. It may have exited at start: another process on the box may hold port 12345.
  setup stopped part-way through the alloy phase on server 127.0.0.1, which was the last one, so no phase was skipped.

The probe asked the port the run line bound, on the box's loopback, once.

  $ grep -c -F -- 'http://127.0.0.1:12345/-/healthy' ssh-argv.log
  1

The probe reports an Alloy that is up and names a failing component. The
failure quotes Alloy's words and does not send the operator to the port.

  $ ALLOY_HEALTH='BONDI_ALLOY_UNHEALTHY unhealthy components: loki.write.grafana_cloud' bondi-client setup > out.log 2>&1
  [1]
  $ grep -F -- 'Error:' out.log
  Error: Alloy answered at the end of the wait, but reported itself unhealthy: unhealthy components: loki.write.grafana_cloud

The affirmative arm: the same stub and the same bondi.yaml, with a probe that
reports healthy. Setup goes on past alloy and completes.

  $ : > "$SSH_ARGV_LOG"
  $ ALLOY_HEALTH=BONDI_ALLOY_HEALTHY bondi-client setup > out.log 2>&1
  $ grep -c -F -- 'did not answer healthy' out.log
  0
  [1]
  $ grep -F -- 'answered healthy' out.log
  bondi-alloy answered healthy on server 127.0.0.1, port 12345
