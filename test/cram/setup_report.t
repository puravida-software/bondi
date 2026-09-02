`bondi setup` reported what its plan executed and never what the box ends up in.
The state that matters — what is actually running once the run is over — was left
to a manual check. Setup now ends on the same report `bondi status` prints, built
by the same code from the same two sources, and it reaches it on every exit path.

  $ ROOT="$PWD"

The stub answers the plan's commands and, separately, the reads the report takes
off the host: the container listing, the inspection that carries health, the
crontab spool file, and the bounded wait `setup` runs against each container the
inspection says has a healthcheck to answer for. This host's checks pass.

  $ mkdir -p "$ROOT/bin"
  $ cat > "$ROOT/bin/ssh" <<'STUB'
  > #!/bin/sh
  > while [ $# -gt 0 ] && [ "$1" != "--" ]; do shift; done
  > shift
  > printf '%s\n' "$1" >> "$SSH_ARGV_LOG"
  > cat > /dev/null
  > case "$1" in
  >   *BONDI_ACME_PRESENT*) echo BONDI_ACME_PRESENT ;;
  >   'docker --version') echo 'Docker version 27.0.0, build deadbeef' ;;
  >   'curl --version') echo 'curl 8.5.0 (x86_64-pc-linux-gnu) libcurl/8.5.0' ;;
  >   *BONDI_ORCHESTRATOR_SERVING*) echo BONDI_ORCHESTRATOR_SERVING ;;
  >   *"'--name' 'bondi-gateway'"*) echo 'a1b2c3d4e5f6' ;;
  >   *BONDI_CONTAINER_TIMEOUT*) echo BONDI_CONTAINER_HEALTHY ;;
  >   'docker ps -a --format'*)
  >     printf 'my-service\tacme/app:1.4.0\trunning\n'
  >     printf 'bondi-orchestrator\tmlopez1506/bondi-server:0.10.3\trunning\n'
  >     printf 'bondi-gateway\texample.com/ib-gateway:10.48.1e\trunning\n'
  >     printf 'legacy-worker\told/worker:1.2\trunning\n' ;;
  >   'docker ps -aq | while read -r id'*)
  >     printf '/my-service\tdeclared\thealthy\t0\t2026-08-01T10:00:00.111111111Z\n'
  >     printf '/bondi-orchestrator\tundeclared\t\t0\t2026-08-01T09:00:00.222222222Z\n'
  >     printf '/bondi-gateway\tdeclared\t\t0\t2026-08-01T09:30:00.444444444Z\n'
  >     printf '/legacy-worker\tundeclared\t\t3\t2026-07-30T22:15:00.333333333Z\n' ;;
  >   *'/var/spool/cron/crontabs/root'*)
  >     echo BONDI_CRONTAB_CONTENTS
  >     echo '# BEGIN BONDI CRON'
  >     echo "0 6 * * * curl -s -X POST -d '{\"job\":\"daily-close\",\"secret\":\"s3cr3t\"}' http://127.0.0.1:3030/api/v1/run"
  >     echo '# END BONDI CRON' ;;
  >   *'PortBindings'*) echo '127.0.0.1' ;;
  >   *) : ;;
  > esac
  > STUB
  $ chmod +x "$ROOT/bin/ssh"
  $ export PATH="$ROOT/bin:$PATH"

Port 9 is the discard port and nothing listens on it, so the orchestrator's HTTP
source is refused immediately rather than waited out. Its message is the
operating system's own and is normalised below: what these cases assert is that
the source's row is produced, not how the kernel words a refusal.

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
  >   version: "0.10.3"
  > cron_jobs:
  >   - name: daily-close
  >     image: example.com/daily-close
  >     schedule: "0 6 * * *"
  >     server:
  >       ip_address: 127.0.0.1
  >       port: 9
  >       ssh:
  >         user: deploy
  >         private_key_contents: "not-a-real-key"
  >         private_key_pass: ""
  > managed_containers:
  >   - name: gateway
  >     image: example.com/ib-gateway
  >     tag: "10.48.1e"
  >     restart: unless-stopped
  > EOF

A run that converged every phase ends on the table, with a row for each declared
component and one for the container the host holds that nothing declares. The
lines the run printed on its way there are unchanged.

  $ bondi-client setup > out.log 2>&1
  $ sed 's/not reachable: .*/not reachable: <detail>/' out.log
  Setting up the servers...
  Processing server: 127.0.0.1
  Docker is already installed on server 127.0.0.1: Docker version 27.0.0, build deadbeef
  Network bondi-network is present on server 127.0.0.1
  curl on server 127.0.0.1 supports the crontab command: curl 8.5.0 (x86_64-pc-linux-gnu) libcurl/8.5.0
  ACME file permissions updated on server 127.0.0.1: /etc/traefik/acme/acme.json
  bondi-orchestrator is serving on server 127.0.0.1: mlopez1506/bondi-server:0.10.3
  Wrote secret environment file on server 127.0.0.1: /etc/bondi/gateway/env
  bondi-gateway container started on server 127.0.0.1: a1b2c3d4e5f6
  
  Server: 127.0.0.1
  
  Service
    NAME                   SOURCE  IMAGE                            TAG          STATUS        RESTARTS  HEALTH
    my-service             docker  acme/app                         1.4.0        running       0         healthy
                           orch    not reachable: <detail>
  
  Cron Jobs
    NAME                   SOURCE  IMAGE                            TAG          STATUS        RESTARTS  HEALTH
    daily-close            docker  -                                -            not found     -         -
                           orch    not reachable: <detail>
  
  Infrastructure
    NAME                   SOURCE  IMAGE                            TAG          STATUS        RESTARTS  HEALTH
    bondi-orchestrator     docker  mlopez1506/bondi-server          0.10.3       running       0         no healthcheck defined
                           orch    not reachable: <detail>
    bondi-gateway          docker  example.com/ib-gateway           10.48.1e     running       0         healthy
                           orch    not reachable: <detail>
    legacy-worker          docker  old/worker                       1.2          running       3         no healthcheck defined  [undeclared]
                           orch    not reachable: <detail>
  
  Crontab
    bondi section          docker  1 jobs (daily-close)


A converged run still exits zero. The report is additive: it does not change what
a run that succeeded reports about itself.

  $ : > ssh-argv.log
  $ bondi-client setup > /dev/null 2>&1
  $ echo $?
  0

The report is taken after the plan has run, so it is the final state it describes
rather than the one the plan started from. The three reads are independent and
the order among themselves is not fixed; what is fixed is that they follow the
last thing the plan did.

  $ RAN=$(grep -n -F -- "'--name' 'bondi-gateway'" ssh-argv.log | tail -1 | cut -d: -f1)
  $ READ=$(grep -n -F -- 'docker ps -a --format' ssh-argv.log | head -1 | cut -d: -f1)
  $ test "$READ" -gt "$RAN" && echo "the host is read after it is converged"
  the host is read after it is converged

The orchestrator was genuinely asked — once for the server, over HTTP, with its
one answer then carried onto every row. What the normalisation above hides is the
kernel's wording, not whether the source was consulted. A run that quietly
declined to ask would print a different sentence here, and every row carries the
source's own account of why it has nothing.

  $ grep -c 'not reachable: Error calling status endpoint on server 127.0.0.1' out.log
  5

Nothing the report printed carries a line of the crontab, or any part of one. The
fixture's payload holds a secret precisely so this assertion has something to
catch, and the table above naming the job it belongs to is what proves the
section was read at all.

  $ grep -c 's3cr3t' out.log
  0
  [1]
