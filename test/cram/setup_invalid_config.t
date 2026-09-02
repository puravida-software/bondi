A fault in bondi.yaml is not a fault on a host. It fails the same way for every
server, so a message that names one sends the operator to look at a machine
when the thing to fix is on their own disk — and with several servers the same
message is repeated once per host.

  $ ROOT="$PWD"

The stub records every SSH call so the absence of one can be asserted.

  $ mkdir -p "$ROOT/bin"
  $ cat > "$ROOT/bin/ssh" <<'STUB'
  > #!/bin/sh
  > while [ $# -gt 0 ] && [ "$1" != "--" ]; do shift; done
  > shift
  > printf '%s\n' "$1" >> "$SSH_ARGV_LOG"
  > cat > /dev/null
  > case "$1" in
  >   'docker --version') echo 'Docker version 29.2.1, build deadbeef' ;;
  >   *'/var/spool/cron/crontabs/root'*) echo BONDI_CRONTAB_ABSENT ;;
  >   *'PortBindings'*) echo '127.0.0.1' ;;
  >   *) : ;;
  > esac
  > STUB
  $ chmod +x "$ROOT/bin/ssh"
  $ export PATH="$ROOT/bin:$PATH"

  $ export SSH_ARGV_LOG="$PWD/ssh-argv.log"
  $ : > "$SSH_ARGV_LOG"

Two servers, and a managed container whose restart policy is not one Docker
accepts.

  $ cat > bondi.yaml <<'EOF'
  > bondi_server:
  >   version: "0.1.0"
  > cron_jobs:
  >   - name: healthcheck
  >     image: example.com/healthcheck
  >     schedule: "*/5 * * * *"
  >     server:
  >       ip_address: 10.0.0.1
  >       ssh:
  >         user: deploy
  >         private_key_contents: "not-a-real-key"
  >         private_key_pass: ""
  > managed_containers:
  >   - name: gateway
  >     image: example.com/ib-gateway
  >     tag: "10.48.1e"
  >     restart: whenever-it-feels-like-it
  > EOF

The config is rejected once, at read time, before any server is contacted and
before the run announces itself. The message names the setting rather than a
host, and it is not repeated per server.

  $ bondi-client setup
  Error reading configuration: invalid managed container restart policy: "whenever-it-feels-like-it", expected one of "no", "on-failure", "always", "unless-stopped"
  [1]

Nothing was asked of any host: a file that cannot produce a plan is not a
reason to open an SSH connection.

  $ wc -l < ssh-argv.log
  0
