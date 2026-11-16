A box whose journald still keeps nothing under `/var/log/journal` after setup
has provisioned it -- `Storage=volatile` or `Storage=none` in its configuration
-- would give Alloy a journal source that reads nothing and says nothing. Setup
fails there instead, names the path, and leaves Alloy as it found it.

  $ ROOT="$PWD"

The stub reports a running alloy container and an orchestrator already running
the declared version, so the run reduces to the alloy phase. The journal probe
answers absent every time it is asked, restart or not.

  $ mkdir -p "$ROOT/bin"
  $ cat > "$ROOT/bin/ssh" <<'STUB'
  > #!/bin/sh
  > while [ $# -gt 0 ] && [ "$1" != "--" ]; do shift; done
  > shift
  > printf '%s\n' "$1" >> "$SSH_ARGV_LOG"
  > cat > /dev/null
  > case "$1" in
  >   *BONDI_JOURNAL_PRESENT*) echo BONDI_JOURNAL_ABSENT ;;
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

Setup provisions, reads again, finds the journal still absent, and stops. The
message names the path and the setting that keeps the journal out of it, then
the phase the run stopped in.

  $ bondi-client setup > out.log 2>&1
  [1]
  $ grep -A 1 -F -- 'Error:' out.log
  Error: journald still stores nothing under /var/log/journal for this machine after setup created the directory and restarted it. Alloy reads cron jobs' lines from that journal, so setup will not start an Alloy that reads nothing. Check Storage= in /etc/systemd/journald.conf and its drop-ins: volatile and none keep the journal out of /var/log/journal. Set it to persistent or auto, then run bondi setup again.
  setup stopped part-way through the alloy phase on server 127.0.0.1, which was the last one, so no phase was skipped.

It did provision before giving up, so the failure is the second reading's and
not a run that never tried.

  $ grep -c -x -F -- 'sudo systemctl restart systemd-journald' ssh-argv.log
  1
  $ grep -c -F -- BONDI_JOURNAL_PRESENT ssh-argv.log
  2

No Alloy was started, and the one already running was not touched: the journal
is read before anything in the alloy phase changes the box, so a box that
cannot be given a journal keeps the Alloy it had rather than losing it. The
affirmative arm is the provisioned case, in setup_alloy_journal_provisioned.t, where the stop
and the run both reach the host.

  $ grep -c -F -- 'docker run -d --name bondi-alloy' ssh-argv.log
  0
  [1]
  $ grep -c -x -F -- 'docker stop bondi-alloy' ssh-argv.log
  0
  [1]
  $ grep -c -F -- "cat > " ssh-argv.log
  0
  [1]
