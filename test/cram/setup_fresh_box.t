A box that has none of what setup manages is built up from nothing, and the
closing line lists every item the run created, in the order the phases ran:
Docker, the network, the ACME file, then the orchestrator. Every other setup
cram stubs a box with the network and the ACME file already there, so the lines
`network bondi-network created` and `ACME file created` are read from this one.

  $ ROOT="$PWD"

The stub answers the network as absent and creates it, and answers the ACME file
as absent until setup's create has run, after which it answers what
$ACME_AFTER_CREATE says (root:root 600 unless a case sets otherwise). The create
command is what makes the file exist on this box, so the read-back that follows
it is answered by the box and not by the stub's idea of what setup meant.

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
  >   *BONDI_NETWORK_PRESENT*) echo BONDI_NETWORK_CREATED ;;
  >   *BONDI_ACME_PRESENT*)
  >     if [ ! -f "$ACME_CREATED" ]; then
  >       echo BONDI_ACME_ABSENT
  >     elif [ -n "$ACME_UNREADABLE_AFTER_CREATE" ]; then
  >       :
  >     else
  >       echo "BONDI_ACME_PRESENT ${ACME_AFTER_CREATE:-root:root 600}"
  >     fi ;;
  >   'sudo mkdir -p '*) : > "$ACME_CREATED" ;;
  >   'docker --version') echo 'Docker version 27.0.0, build deadbeef' ;;
  >   *'name=^/bondi-orchestrator$'*'{{.State}}'*) : ;;
  >   'attempt=0; while'*) : ;;
  >   *'bondi-server check'*) echo '{"ready":true,"probes":[]}' ;;
  >   'docker logs --tail'*) echo 'bondi check: diagnostic sink is writable' ;;
  >   *'RestartPolicy'*) echo unless-stopped ;;
  >   'docker ps -a --format'*)
  >     printf 'bondi-orchestrator\tmlopez1506/bondi-server:0.15.0\trunning\n' ;;
  >   'docker ps -aq | while read -r id'*)
  >     printf '/bondi-orchestrator\tundeclared\t\t0\t2026-08-01T09:00:00.222222222Z\n' ;;
  >   *'/var/spool/cron/crontabs/root'*) echo BONDI_CRONTAB_ABSENT ;;
  >   *BONDI_CRON_PAYLOAD_LISTED*)
  >     echo BONDI_CRON_PAYLOAD_LISTED
  >     echo BONDI_CRON_PAYLOAD_END ;;
  >   *'name=^/bondi-orchestrator$'*"--format '{{.Image}}'") echo 'mlopez1506/bondi-server:0.15.0' ;;
  >   *'bondi-server status'*) echo 'this fixture does not answer the report' >&2; exit 1 ;;
  >   *) : ;;
  > esac
  > STUB
  $ chmod +x "$ROOT/bin/ssh"
  $ export PATH="$ROOT/bin:$PATH"
  $ export SSH_ARGV_LOG="$PWD/ssh-argv.log"
  $ export ACME_CREATED="$PWD/acme-created"
  $ cat > bondi.yaml <<'YAML'
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
  >   version: "0.15.0"
  > YAML

The first run: the network is absent and created, the ACME file is absent and
created and read back at root:root 600, and the orchestrator is started. The line
is asserted whole, so the order of its items and the absence of any other are
both pinned.

  $ rm -f "$ACME_CREATED"
  $ : > "$SSH_ARGV_LOG"
  $ bondi-client setup > out.log 2>&1
  $ echo $?
  0
  $ grep -F -- 'setup changed' out.log
  setup changed on server 127.0.0.1: network bondi-network created, ACME file created, orchestrator 0.15.0 created
  $ grep -c -F -- 'BONDI_ACME_PRESENT' ssh-argv.log
  2

The probe ran twice: once to find the file absent, and once after the create to
read what the box now holds. That second read is what the line above rests on.

The same box, with the create's read-back finding the file at root:root 644, as a
create that did not apply its chmod would leave it. The create's command exited
zero, so a run that trusted that would say `ACME file created`. It does not: the
run fails, naming what the box has, and the closing line lists what the run did
make (the network) and not the file.

  $ rm -f "$ACME_CREATED"
  $ export ACME_AFTER_CREATE='root:root 644'
  $ : > "$SSH_ARGV_LOG"
  $ bondi-client setup > wide.log 2>&1
  [1]
  $ grep -F -- 'setup changed' wide.log
  setup changed on server 127.0.0.1: network bondi-network created
  $ grep -c -F -- 'ACME file created' wide.log
  0
  [1]
  $ grep -c -F -- 'is still root:root 644 after asking for root:root 600' wide.log
  1

A read-back that says nothing is not a file at the declared mode either: the
reading could not be taken, so the create is not reported.

  $ rm -f "$ACME_CREATED"
  $ unset ACME_AFTER_CREATE
  $ export ACME_UNREADABLE_AFTER_CREATE=1
  $ : > "$SSH_ARGV_LOG"
  $ bondi-client setup > silent.log 2>&1
  [1]
  $ grep -F -- 'setup changed' silent.log
  setup changed on server 127.0.0.1: network bondi-network created
  $ grep -c -F -- 'ACME file created' silent.log
  0
  [1]
