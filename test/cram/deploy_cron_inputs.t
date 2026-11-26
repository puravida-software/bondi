A cron job's name, schedule and secret entries go from bondi.yaml to the box:
the name names a container that shares one namespace with every other one on
the box, the schedule is written into root's crontab, and the secrets into an
env file read back one KEY=VALUE per line. Each is checked when bondi.yaml is
read, so a job that would clash, inject or be cut short is refused before any
server is contacted.

The stub ssh records every call it is given and answers none of them, so an
absent log is a run that never reached a server. The log is removed before each
case, so each one is judged on its own and the file can be re-run in a
directory a previous run has written to.

  $ ROOT="$PWD"
  $ mkdir -p "$ROOT/bin"
  $ cat > "$ROOT/bin/ssh" <<'STUB'
  > #!/bin/sh
  > printf '%s\n' "$*" >> "$SSH_CALLS_LOG"
  > exit 255
  > STUB
  $ chmod +x "$ROOT/bin/ssh"
  $ export PATH="$ROOT/bin:$PATH"
  $ export SSH_CALLS_LOG="$ROOT/ssh-calls.log"
  $ ssh_calls() {
  > test -e "$SSH_CALLS_LOG" && echo "ssh was called" || echo "ssh was never called"
  > }

A manifest declaring the service web on one server, followed by the cron_jobs
block given on standard input.

  $ manifest() {
  > cat > bondi.yaml <<EOF
  > service:
  >   name: web
  >   image: ghcr.io/acme/web
  >   port: 8080
  >   env_vars: {}
  >   servers:
  >     - ip_address: 127.0.0.1
  >       ssh:
  >         user: deploy
  > bondi_server:
  >   version: "0.23.0"
  > cron_jobs:
  > EOF
  > cat >> bondi.yaml
  > }

A job named like the service, and another named like Bondi's Traefik container,
are refused together, each naming the job and what already holds its name.

  $ rm -f "$SSH_CALLS_LOG"
  $ manifest <<'EOF'
  >   - name: web
  >     image: ghcr.io/acme/backup-job
  >     schedule: "0 2 * * *"
  >     server:
  >       ip_address: 127.0.0.1
  >       ssh:
  >         user: deploy
  >   - name: bondi-traefik
  >     image: ghcr.io/acme/backup-job
  >     schedule: "0 3 * * *"
  >     server:
  >       ip_address: 127.0.0.1
  >       ssh:
  >         user: deploy
  > EOF
  $ bondi-client deploy web:v2 2>&1
  Deployment process initiated...
  Error reading configuration: cron jobs cannot take names already in use (cron job "web" cannot take that name: the service "web" already runs under it, and a cron job's container is named after the job; cron job "bondi-traefik" cannot take that name: the built-in container "bondi-traefik" already runs under it, and a cron job's container is named after the job): rename these jobs in bondi.yaml
  [1]
  $ ssh_calls
  ssh was never called

A secret value holding a newline would end its line in the env file and turn
its tail into a variable nobody wrote. It is refused naming the job and the key,
and the value, which is a credential, is not printed.

  $ rm -f "$SSH_CALLS_LOG"
  $ manifest <<'EOF'
  >   - name: nightly
  >     image: ghcr.io/acme/backup-job
  >     schedule: "0 2 * * *"
  >     secret_env_vars:
  >       API_TOKEN: "sk-live-4f9a2c\nINJECT=1"
  >     server:
  >       ip_address: 127.0.0.1
  >       ssh:
  >         user: deploy
  > EOF
  $ bondi-client deploy nightly:v1 2>&1
  Deployment process initiated...
  Error reading configuration: cron job secret entries cannot be written to an env file (job "nightly" has a control character in the value of "API_TOKEN"). A key must be non-empty and hold no "=" and no control character, and a value must hold no control character, newline included: fix these entries in bondi.yaml
  [1]
  $ ssh_calls
  ssh was never called

A schedule outside the five-field grammar is refused naming the job and the
schedule. Month names are read by only one of the two cron daemons a box may
run, so they are not in it.

  $ rm -f "$SSH_CALLS_LOG"
  $ manifest <<'EOF'
  >   - name: nightly
  >     image: ghcr.io/acme/backup-job
  >     schedule: "0 2 * jan *"
  >     server:
  >       ip_address: 127.0.0.1
  >       ssh:
  >         user: deploy
  > EOF
  $ bondi-client deploy nightly:v1 2>&1
  Deployment process initiated...
  Error reading configuration: invalid bondi.yaml: cron job "nightly" schedule "0 2 * jan *": the month "jan" is not a number from 1 to 12
  [1]
  $ ssh_calls
  ssh was never called

A block written to attack the box: a schedule carrying a second crontab line
that runs as root, a secret carrying a second variable, two jobs under one name
that climbs out of the job's directory, an empty schedule and an address that
is an ssh option. The first schedule refuses it, before anything else in it is
acted on.

  $ rm -f "$SSH_CALLS_LOG"
  $ manifest <<'EOF'
  >   - name: "../x"
  >     image: i
  >     schedule: "not a schedule\n* * * * * root reboot"
  >     secret_env_vars:
  >       K: "line1\nINJECT=1"
  >     server:
  >       ip_address: ""
  >   - name: "../x"
  >     image: i
  >     schedule: ""
  >     server:
  >       ip_address: "-oProxyCommand=x"
  > EOF
  $ bondi-client deploy ../x:v1 2>&1
  Deployment process initiated...
  Error reading configuration: invalid bondi.yaml: cron job "../x" schedule "not a schedule\n* * * * * root reboot": the schedule holds a control character, which would end the crontab line early: a schedule is five fields separated by spaces or tabs: minute (0-59), hour (0-23), day of month (1-31), month (1-12) and day of week (0-7, 0 and 7 being Sunday), each a comma-separated list of *, a number or an ascending range a-b, where * or a range may be followed by /step
  [1]
  $ ssh_calls
  ssh was never called

A job name that would climb out of the job's directory is refused when
bondi.yaml is read, naming the name, before anything is dialled.

  $ rm -f "$SSH_CALLS_LOG"
  $ manifest <<'EOF'
  >   - name: "../x"
  >     image: ghcr.io/acme/backup-job
  >     schedule: "0 2 * * *"
  >     server:
  >       ip_address: 127.0.0.1
  >       ssh:
  >         user: deploy
  > EOF
  $ bondi-client deploy nightly:v1 2>&1
  Deployment process initiated...
  Error reading configuration: cron job names must be safe to place in a file path ("../x"). A name must begin with a letter or a digit and may hold only letters, digits, '.', '_' and '-': rename these jobs in bondi.yaml
  [1]
  $ ssh_calls
  ssh was never called

The affirmative arm, which is what makes each absent log above mean something:
the same manifest with a job whose name, schedule and secret are all accepted
reaches the stub, so the stub is the ssh this client runs.

  $ rm -f "$SSH_CALLS_LOG"
  $ manifest <<'EOF'
  >   - name: nightly
  >     image: ghcr.io/acme/backup-job
  >     schedule: "*/15 1-5 * * 1-5"
  >     secret_env_vars:
  >       API_TOKEN: "sk-live-4f9a2c"
  >     server:
  >       ip_address: 127.0.0.1
  >       ssh:
  >         user: deploy
  > EOF
  $ bondi-client deploy nightly:v1 > /dev/null 2>&1
  [1]
  $ ssh_calls
  ssh was called
