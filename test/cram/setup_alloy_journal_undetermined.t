A journal probe that answers neither marker says nothing about the box, so
setup stops rather than acting on a reading it did not get. It is not read as
absent: that would provision a box nobody has looked at.

  $ ROOT="$PWD"

  $ mkdir -p "$ROOT/bin"
  $ cat > "$ROOT/bin/ssh" <<'STUB'
  > #!/bin/sh
  > while [ $# -gt 0 ] && [ "$1" != "--" ]; do shift; done
  > shift
  > printf '%s\n' "$1" >> "$SSH_ARGV_LOG"
  > cat > /dev/null
  > case "$1" in
  >   *BONDI_JOURNAL_PRESENT*) echo 'something else entirely' ;;
  >   # The three provisioning commands, each succeeding: the box accepts them
  >   # and its journald still writes nowhere persistent. Named rather than left
  >   # to *) so that a considered silence and an unhandled command read
  >   # differently.
  >   "sudo mkdir -p '/var/log/journal'") : ;;
  >   "sudo systemd-tmpfiles --create --prefix '/var/log/journal'") : ;;
  >   'sudo systemctl restart systemd-journald') : ;;
  >   *BONDI_ACME_PRESENT*) echo BONDI_ACME_PRESENT ;;
  >   'docker --version') echo 'Docker version 27.0.0, build deadbeef' ;;
  >   *'name=^/bondi-orchestrator$'*'{{.State}}'*)
  >     printf 'running\tmlopez1506/bondi-server:0.25.0\n' ;;
  >   *'ps -a --filter name=^/bondi-alloy$'*'{{.State}}'*)
  >     printf 'running\tgrafana/alloy:v1.8.0\n' ;;
  >   *BONDI_ALLOY_MODE_ABSENT*) echo 0640 ;;
  >   *'sudo stat -c %04a'*) echo 0640 ;;
  >   *'cat > '*'/etc/bondi/alloy/env'*) : ;;
  >   *'--name bondi-alloy'*) echo 'd671990dc2318f4b' ;;
  >   *'/var/spool/cron/crontabs/root'*) echo BONDI_CRONTAB_ABSENT ;;
  >   *BONDI_CRON_PAYLOAD_LISTED*)
  >     echo BONDI_CRON_PAYLOAD_LISTED
  >     echo BONDI_CRON_PAYLOAD_END ;;
  >   *'RestartPolicy'*) echo unless-stopped ;;
  >   *'name=^/bondi-orchestrator$'*"--format '{{.Image}}'") echo 'mlopez1506/bondi-server:0.25.0' ;;
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
  > bondi_server:
  >   version: "0.25.0"
  > alloy:
  >   grafana_cloud:
  >     instance_id: "123456"
  >     api_key: "glc_secret"
  >     endpoint: "https://logs-prod.grafana.net/loki/api/v1/push"
  > EOF

  $ bondi-client setup > out.log 2>&1
  [1]
  $ grep -F -- 'Error:' out.log
  Error: could not read whether journald stores its journal under /var/log/journal, so setup will not change how it stores it: the host answered without saying which: something else entirely

Nothing was provisioned, and Alloy was not stopped, removed or run.

  $ grep -c -E -- 'systemctl restart|systemd-tmpfiles|docker (stop|rm) bondi-alloy|docker run -d --name bondi-alloy' ssh-argv.log
  0
  [1]
