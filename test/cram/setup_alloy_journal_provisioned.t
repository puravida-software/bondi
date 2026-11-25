Alloy reads a cron container's lines from the host journal under
`/var/log/journal`. A box whose journald keeps its journal in memory has nothing
for this machine there, so an Alloy started against it reads nothing and says
nothing. Setup reads the journal's storage before it touches Alloy, provisions
persistent storage where there is none, reads it again, and says what it did.

  $ ROOT="$PWD"

The stub reports a running alloy container and an orchestrator already running
the declared version, so the run reduces to the alloy phase.

The journal probe is answered from a file, and the restart arm is what rewrites
it, to whatever `$JOURNAL_AFTER_RESTART` holds. A box whose journal appears
only once journald has been restarted is then the only way this run reaches a
provisioned journal, which is the claim: an arm answering present to the second
probe on its own would pass against a run that never restarted anything.

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
  >   *BONDI_JOURNAL_PRESENT*) cat "$JOURNAL_FILE" ;;
  >   # The three provisioning commands. They answer nothing, as the host does
  >   # when each succeeds, and they are named rather than left to *) so that a
  >   # considered silence and an unhandled command read differently.
  >   "sudo mkdir -p '/var/log/journal'") : ;;
  >   "sudo systemd-tmpfiles --create --prefix '/var/log/journal'") : ;;
  >   'sudo systemctl restart systemd-journald')
  >     printf '%s\n' "$JOURNAL_AFTER_RESTART" > "$JOURNAL_FILE" ;;
  >   *BONDI_ALLOY_CURL_PRESENT*) echo BONDI_ALLOY_CURL_PRESENT ;;
  >   *BONDI_ALLOY_PORT_FREE*) echo "${ALLOY_PORT:-BONDI_ALLOY_PORT_FREE}" ;;
  >   *BONDI_ACME_PRESENT*) echo BONDI_ACME_PRESENT ;;
  >   'docker --version') echo 'Docker version 27.0.0, build deadbeef' ;;
  >   # The orchestrator this file's box already runs, carrying the digest setup
  >   # stamps on a 0.25.0 orchestrator created without the cron payload mounts:
  >   # what this setup would create, so it is pulled and checked rather than
  >   # replaced. Without the digest it reads as a container no setup recorded,
  >   # which is replaced once.
  >   *'name=^/bondi-orchestrator$'*'{{.State}}'*)
  >     printf 'running\tmlopez1506/bondi-server:0.25.0\t92eba0ed2e6c82a23cd21b6c85e10e71\n' ;;
  >   # The image check that follows the pull on that orchestrator: the pulled
  >   # image's id, then the container's, one per line in the docker CLI's full
  >   # sha256 form, and equal because nothing moved the tag.
  >   'docker image inspect '*)
  >     printf 'sha256:66a6306db78bf2dbf3487f293aa8d6990d8e506fdffab9cc43fe422becf886e4\nsha256:66a6306db78bf2dbf3487f293aa8d6990d8e506fdffab9cc43fe422becf886e4\n' ;;
  >   *'ps -a --filter name=^/bondi-alloy$'*'{{.State}}'*)
  >     printf 'running\tgrafana/alloy:v1.8.0\t\n' ;;
  >   # Both mode readings agree with the declared mode, so the journal is the
  >   # only thing on this box that diverges and the only correction the run
  >   # has to report.
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
  >   *'name=^/bondi-orchestrator$'*"--format '{{.Image}}'") echo 'mlopez1506/bondi-server:0.25.0' ;;
  >   *'bondi-server status'*) echo 'this fixture does not answer the report' >&2; exit 1 ;;
  >   *) : ;;
  > esac
  > STUB
  $ chmod +x "$ROOT/bin/ssh"
  $ export PATH="$ROOT/bin:$PATH"
  $ export SSH_ARGV_LOG="$PWD/ssh-argv.log"
  $ : > "$SSH_ARGV_LOG"
  $ export JOURNAL_FILE="$PWD/journal.txt"
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

The box answers absent, and the restart makes it present. Setup provisions the
journal, says so as it goes, and goes on to replace Alloy.

  $ printf 'BONDI_JOURNAL_ABSENT\n' > "$JOURNAL_FILE"
  $ JOURNAL_AFTER_RESTART=BONDI_JOURNAL_PRESENT bondi-client setup > out.log 2>&1
  $ head -14 out.log
  Setting up the servers...
  Processing server: 127.0.0.1
  Docker is already installed on server 127.0.0.1: Docker version 27.0.0, build deadbeef
  Network bondi-network is present on server 127.0.0.1
  ACME file permissions updated on server 127.0.0.1: /etc/traefik/acme/acme.json
  Pulled mlopez1506/bondi-server:0.25.0 on server 127.0.0.1
  bondi-orchestrator container is already running on server 127.0.0.1: 0.25.0, skipping...
  Pulled grafana/alloy:v1.8.0 on server 127.0.0.1
  curl on server 127.0.0.1 can ask Alloy on port 12345
  Provisioned persistent journal storage on server 127.0.0.1: /var/log/journal
  port 12345 on server 127.0.0.1 is free for Alloy
  Stopped bondi-alloy container on server 127.0.0.1
  Removed bondi-alloy container and config on server 127.0.0.1
  Alloy config written on server 127.0.0.1: /etc/bondi/alloy/config.alloy

What it changed is a line of the run's account, worded the way every other
correction is: what the box had, then what the run applied. The run that
corrected it does not also say it corrected nothing.

  $ grep -c -F -- '/var/log/journal on server 127.0.0.1 was storage volatile, applied persistent' out.log
  1
  $ grep -c -F -- 'setup corrected nothing on server 127.0.0.1' out.log
  0
  [1]

The commands that reached the host, spelled out rather than derived, in the
order they run: the directory, journald's ownership and mode on it, then the
restart that moves the journal there.

  $ grep -n -x -F -e "sudo mkdir -p '/var/log/journal'" -e "sudo systemd-tmpfiles --create --prefix '/var/log/journal'" -e 'sudo systemctl restart systemd-journald' ssh-argv.log | cut -d: -f2-
  sudo mkdir -p '/var/log/journal'
  sudo systemd-tmpfiles --create --prefix '/var/log/journal'
  sudo systemctl restart systemd-journald

The probe asks for the directory named after this machine's id, not the bare
`/var/log/journal`: with `Storage=volatile` the bare directory can exist and stay
empty. It is taken twice, once before provisioning and once after, and Alloy is
stopped and run only after the second reading. A run that started Alloy before
reading again would pass every line above.

  $ grep -c -F -- "sudo test -d '/var/log/journal'/\"\$id\"" ssh-argv.log
  2
  $ grep -c -F -- 'cat /etc/machine-id' ssh-argv.log
  2
  $ FIRST_PROBE=$(grep -n -F -- BONDI_JOURNAL_PRESENT ssh-argv.log | head -1 | cut -d: -f1)
  $ MKDIR=$(grep -n -x -F -- "sudo mkdir -p '/var/log/journal'" ssh-argv.log | cut -d: -f1)
  $ RESTART=$(grep -n -x -F -- 'sudo systemctl restart systemd-journald' ssh-argv.log | cut -d: -f1)
  $ SECOND_PROBE=$(grep -n -F -- BONDI_JOURNAL_PRESENT ssh-argv.log | tail -1 | cut -d: -f1)
  $ STOP=$(grep -n -x -F -- 'docker stop bondi-alloy' ssh-argv.log | cut -d: -f1)
  $ RUN=$(grep -n -F -- 'docker run -d --name bondi-alloy' ssh-argv.log | cut -d: -f1)
  $ test "$FIRST_PROBE" -lt "$MKDIR" && test "$RESTART" -lt "$SECOND_PROBE" && test "$SECOND_PROBE" -lt "$STOP" && test "$STOP" -lt "$RUN" && echo 'read, provisioned, read again, then Alloy replaced'
  read, provisioned, read again, then Alloy replaced

A box whose journal is already persistent is the same stub with the file
starting at present. It is read once, nothing is provisioned, the run says the
journal is already where Alloy reads it, and there is nothing to account for.

  $ : > "$SSH_ARGV_LOG"
  $ printf 'BONDI_JOURNAL_PRESENT\n' > "$JOURNAL_FILE"
  $ JOURNAL_AFTER_RESTART=BONDI_JOURNAL_PRESENT bondi-client setup > out.log 2>&1
  $ grep -F -- 'journal' out.log
  Journal on server 127.0.0.1 is stored persistently under /var/log/journal
  $ grep -c -F -- 'BONDI_JOURNAL_PRESENT' ssh-argv.log
  1
  $ grep -c -F -- 'systemd-journald' ssh-argv.log
  0
  [1]
  $ grep -c -F -- 'setup corrected nothing on server 127.0.0.1' out.log
  1
  $ grep -c -F -- 'docker run -d --name bondi-alloy' ssh-argv.log
  1
