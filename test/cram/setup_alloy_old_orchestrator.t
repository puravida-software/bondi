An orchestrator older than the release that sends cron output to the journal
loses every cron line under the Alloy configuration this client writes, and
nothing fails when it does. Setup refuses while alloy is declared, names the
version to pin, and touches nothing on the box.

  $ ROOT="$PWD"

  $ mkdir -p "$ROOT/bin"
  $ cat > "$ROOT/bin/ssh" <<'STUB'
  > #!/bin/sh
  > while [ $# -gt 0 ] && [ "$1" != "--" ]; do shift; done
  > shift
  > printf '%s\n' "$1" >> "$SSH_ARGV_LOG"
  > cat > /dev/null
  > case "$1" in
  >   # The pull setup takes ahead of any stop or run, answered as the docker
  >   # CLI answers one for an image already on the box: four lines on stdout,
  >   # exit 0.
  >   'docker pull '*)
  >     ref=$(printf '%s\n' "$1" | sed "s/^docker pull '\(.*\)'\$/\1/")
  >     printf '%s: Pulling from %s\n' "${ref##*:}" "${ref%:*}"
  >     printf 'Digest: sha256:66a6306db78bf2dbf3487f293aa8d6990d8e506fdffab9cc43fe422becf886e4\n'
  >     printf 'Status: Image is up to date for %s\n%s\n' "$ref" "$ref" ;;
  >   *BONDI_JOURNAL_PRESENT*) echo BONDI_JOURNAL_ABSENT ;;
  >   # The three provisioning commands, each succeeding: the box accepts them
  >   # and its journald still writes nowhere persistent. Named rather than left
  >   # to *) so that a considered silence and an unhandled command read
  >   # differently.
  >   "sudo mkdir -p '/var/log/journal'") : ;;
  >   "sudo systemd-tmpfiles --create --prefix '/var/log/journal'") : ;;
  >   'sudo systemctl restart systemd-journald') : ;;
  >   *BONDI_ALLOY_CURL_PRESENT*) echo BONDI_ALLOY_CURL_PRESENT ;;
  >   *BONDI_ALLOY_PORT_FREE*) echo "${ALLOY_PORT:-BONDI_ALLOY_PORT_FREE}" ;;
  >   *BONDI_ACME_PRESENT*) echo 'BONDI_ACME_PRESENT root:root 600' ;;
  >   'docker --version') echo 'Docker version 27.0.0, build deadbeef' ;;
  >   *'name=^/bondi-orchestrator$'*'{{.State}}'*)
  >     printf 'running\tmlopez1506/bondi-server:0.24.2\t\n' ;;
  >   *'ps -a --filter name=^/bondi-alloy$'*'{{.State}}'*)
  >     printf 'running\tgrafana/alloy:v1.8.0\t\n' ;;
  >   *BONDI_ALLOY_MODE_ABSENT*) echo 0640 ;;
  >   *'sudo stat -c %04a'*) echo 0640 ;;
  >   *'cat > '*'/etc/bondi/alloy/env'*) : ;;
  >   # The health wait that follows the run, answered as a running Alloy
  >   # answers it. Without this arm the probe falls through to *) and answers
  >   # nothing, which setup reads as no verdict and fails the run on.
  >   *'http://127.0.0.1:12345/-/healthy'*) echo BONDI_ALLOY_HEALTHY ;;
  >   *'--name bondi-alloy'*) echo 'd671990dc2318f4b' ;;
  >   *'/var/spool/cron/crontabs/root'*) echo BONDI_CRONTAB_ABSENT ;;
  >   *BONDI_CRON_PAYLOAD_LISTED*)
  >     echo BONDI_CRON_PAYLOAD_LISTED
  >     echo BONDI_CRON_PAYLOAD_END ;;
  >   *'RestartPolicy'*) echo unless-stopped ;;
  >   *'name=^/bondi-orchestrator$'*"--format '{{.Image}}'") echo 'mlopez1506/bondi-server:0.24.2' ;;
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
  >   version: "0.24.2"
  > alloy:
  >   grafana_cloud:
  >     instance_id: "123456"
  >     api_key: "glc_secret"
  >     endpoint: "https://logs-prod.grafana.net/loki/api/v1/push"
  > EOF

  $ bondi-client setup > out.log 2>&1
  [1]
  $ grep -F -- 'Error:' out.log
  Error: server 127.0.0.1: the server is running bondi-server 0.24.2, but alloy is declared, and the configuration setup writes reads cron jobs' lines from the host journal, which requires 0.25.0 or later. An older server logs cron jobs to the Docker path the configuration no longer reads, so every cron line would be lost without an error. Set bondi_server.version in bondi.yaml to 0.25.0 or later, run bondi setup, then check it with bondi status.

Nothing was provisioned, stopped, removed or run.

  $ grep -c -E -- 'mkdir|systemctl restart|docker (stop|rm|run) |BONDI_JOURNAL_PRESENT' ssh-argv.log
  0
  [1]
