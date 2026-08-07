`bondi status` read the box entirely through the orchestrator's HTTP endpoint, so
the one failure it was most needed for — an orchestrator that is not running —
produced a stderr line and an empty table. Docker over SSH is the other source,
and it answers on exactly that failure.

  $ ROOT="$PWD"

The stub answers the three reads the report takes off the host, dispatching on
the remote command string the client sends. $SSH_BROKEN makes every read fail, so
the same fixture covers both an SSH source that answered and one that could not
be consulted.

  $ mkdir -p "$ROOT/bin"
  $ cat > "$ROOT/bin/ssh" <<'STUB'
  > #!/bin/sh
  > while [ $# -gt 0 ] && [ "$1" != "--" ]; do shift; done
  > shift
  > if [ -n "$SSH_BROKEN" ]; then echo 'Permission denied (publickey).' >&2; exit 255; fi
  > case "$1" in
  >   'docker ps -a --format'*)
  >     printf 'my-service\tacme/app:1.4.0\trunning\n'
  >     printf 'bondi-orchestrator\tmlopez1506/bondi-server:0.10.3\trunning\n'
  >     printf 'legacy-worker\told/worker:1.2\trunning\n'
  >     printf 'pending-check\tacme/probe:2.0\trunning\n' ;;
  >   'docker ps -aq | while read -r id'*)
  >     printf '/my-service\tdeclared\thealthy\t0\t2026-08-01T10:00:00.111111111Z\n'
  >     printf '/bondi-orchestrator\tundeclared\t\t0\t2026-08-01T09:00:00.222222222Z\n'
  >     printf '/legacy-worker\tundeclared\t\t3\t2026-07-30T22:15:00.333333333Z\n'
  >     printf '/pending-check\tdeclared\t\t0\t2026-07-30T22:20:00.555555555Z\n' ;;
  >   *'/var/spool/cron/crontabs/root'*)
  >     echo BONDI_CRONTAB_CONTENTS
  >     echo '# BEGIN BONDI CRON'
  >     echo "0 6 * * * curl -s -X POST -d '{\"job\":\"daily-close\",\"secret\":\"s3cr3t\"}' http://127.0.0.1:3030/api/v1/run"
  >     echo '# END BONDI CRON' ;;
  >   *) : ;;
  > esac
  > STUB
  $ chmod +x "$ROOT/bin/ssh"
  $ export PATH="$ROOT/bin:$PATH"

Port 9 is the discard port and nothing listens on it, so the HTTP source is
refused immediately rather than waited out. Its message is the operating system's
own and is normalised here: what this case asserts is that the row is produced,
not how the kernel words a refusal.

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
  >   version: "0.10.3"
  > EOF

With the orchestrator unreachable the table is populated from the host alone.
Every declared component has a row, the orchestrator's own row says it could not
be reached rather than going missing, the container nothing declares is present
and flagged, and the crontab section is counted and named without any line of it
being rendered. A container that declares a healthcheck the host has recorded no
verdict for says exactly that: this command reports a health state and never
waits for one, so it is the only one that can still show that reading.

  $ bondi-client status 2>&1 | sed 's/not reachable: .*/not reachable: <detail>/'
  Server: 127.0.0.1
  
  Service
    NAME                   SOURCE  IMAGE                            TAG          STATUS        RESTARTS  HEALTH
    my-service             docker  acme/app                         1.4.0        running       0         healthy
                           orch    not reachable: <detail>
  
  Infrastructure
    NAME                   SOURCE  IMAGE                            TAG          STATUS        RESTARTS  HEALTH
    bondi-orchestrator     docker  mlopez1506/bondi-server          0.10.3       running       0         no healthcheck defined
                           orch    not reachable: <detail>
    legacy-worker          docker  old/worker                       1.2          running       3         no healthcheck defined  [undeclared]
                           orch    not reachable: <detail>
    pending-check          docker  acme/probe                       2.0          running       0         no health recorded  [undeclared]
                           orch    not reachable: <detail>
  
  Crontab
    bondi section          docker  1 jobs (daily-close)


Nothing the report printed carries a line of the crontab, or any part of one. The
fixture's payload holds a secret precisely so this assertion has something to
catch.

  $ bondi-client status 2>&1 | grep -c 's3cr3t'
  0
  [1]

A failed read never empties the table and never changes the exit code: the report
is what an operator loses exactly when it is needed.

  $ bondi-client status > /dev/null 2>&1
  $ echo $?
  0

The affirmative arm on the same fixture. With SSH failing too, both sources say
so on every row and no row disappears — a source that could not be consulted is a
line, never a silence.

  $ SSH_BROKEN=1 bondi-client status 2>&1 | sed -e 's/not reachable: .*/not reachable: <detail>/' -e 's/not read: .*/not read: <detail>/'
  Server: 127.0.0.1
  
  Service
    NAME                   SOURCE  IMAGE                            TAG          STATUS        RESTARTS  HEALTH
    my-service             docker  not read: <detail>
                           orch    not reachable: <detail>
  
  Infrastructure
    NAME                   SOURCE  IMAGE                            TAG          STATUS        RESTARTS  HEALTH
    bondi-orchestrator     docker  not read: <detail>
                           orch    not reachable: <detail>
  
  Crontab
    bondi section          docker  not read: <detail>


A server with no ssh block in its configuration is a source that cannot be
consulted, not an error: the run still exits zero and still prints its table.

  $ cat > bondi.yaml <<'EOF'
  > service:
  >   name: my-service
  >   image: acme/app
  >   port: 8080
  >   env_vars: {}
  >   servers:
  >     - ip_address: 127.0.0.1
  >       port: 9
  > bondi_server:
  >   version: "0.10.3"
  > EOF
  $ bondi-client status 2>&1 | sed 's/not reachable: .*/not reachable: <detail>/' | head -6
  Server: 127.0.0.1
  
  Service
    NAME                   SOURCE  IMAGE                            TAG          STATUS        RESTARTS  HEALTH
    my-service             docker  not read: Missing ssh configuration for server 127.0.0.1
                           orch    not reachable: <detail>
  $ bondi-client status > /dev/null 2>&1
  $ echo $?
  0

The same report as JSON. A consumer of this is no more able to read a single
reconciled value than a reader of the table: each source keeps its own object on
every component, and a source with nothing to say says which of the two failures
it had rather than only that it had one. The table above is what pins the
wording; what this pins is that the machine-readable form carries the same two
sources and does not quietly collapse them.

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
  >   version: "0.10.3"
  > EOF
  $ bondi-client status --output json 2>&1 | grep -E '"(name|source|reason|state|health)"' | sed 's/^ *//' | head -14
  "name": "my-service",
  "source": "reported",
  "state": "running",
  "health": "healthy",
  "source": "unavailable",
  "reason": "not_consulted",
  "name": "bondi-orchestrator",
  "source": "reported",
  "state": "running",
  "health": "no healthcheck defined",
  "source": "unavailable",
  "reason": "not_consulted",
  "name": "legacy-worker",
  "source": "reported",

The crontab is counted in JSON too, and no line of it is rendered there either.

  $ bondi-client status --output json 2>&1 | grep -o '"crontab": {[^}]*}'
  "crontab": { "summary": "1 jobs (daily-close)", "job_count": 1 }
  $ bondi-client status --output json 2>&1 | grep -c 's3cr3t'
  0
  [1]
