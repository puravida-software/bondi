A converged component is not a working one. A process can be up with its
application parked on a dialog nothing will dismiss, and a listener can stay open
on a port for the seconds it takes to destroy and rebuild what is behind it. So
where a container declares a healthcheck, `bondi setup` waits for it on the host,
bounded, and a component that never passes it is named in the report and takes
the run's exit code with it.

  $ ROOT="$PWD"

The stub answers the plan's commands, the reads the report takes off the host,
and the bounded wait. $HEALTH_MARKER is what the one container declaring a
healthcheck is made to say; it is the only thing that differs between the two
runs below, so the exit code can only have followed from it.

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
  >   *BONDI_ORCHESTRATOR_SERVING*) echo BONDI_ORCHESTRATOR_SERVING ;;
  >   *"'--name' 'bondi-gateway'"*) echo 'a1b2c3d4e5f6' ;;
  >   deadline=*)
  >     case "$1" in
  >       *"'my-service'"*) printf '%s\n' "$HEALTH_MARKER" ;;
  >       *) echo BONDI_CONTAINER_NO_HEALTHCHECK ;;
  >     esac ;;
  >   'docker ps -a --format'*)
  >     printf 'my-service\tacme/app:1.4.0\trunning\n'
  >     printf 'bondi-orchestrator\tmlopez1506/bondi-server:0.10.3\trunning\n'
  >     printf 'bondi-gateway\texample.com/ib-gateway:10.48.1e\trunning\n' ;;
  >   'docker ps -aq | while read -r id'*)
  >     printf '/my-service\tdeclared\tstarting\t0\t2026-08-01T10:00:00.111111111Z\n'
  >     printf '/bondi-orchestrator\tundeclared\t\t0\t2026-08-01T09:00:00.222222222Z\n'
  >     printf '/bondi-gateway\tundeclared\t\t0\t2026-08-01T09:30:00.444444444Z\n' ;;
  >   *'/var/spool/cron/crontabs/root'*) echo BONDI_CRONTAB_ABSENT ;;
  >   *'PortBindings'*) echo '127.0.0.1' ;;
  >   # The host's applied restart policy. Without this arm the command falls
  >   # through to *) and answers nothing, which setup reads as a refusal to
  >   # report rather than as agreement.
  >   *'RestartPolicy'*) echo unless-stopped ;;
  >   *) : ;;
  > esac
  > STUB
  $ chmod +x "$ROOT/bin/ssh"
  $ export PATH="$ROOT/bin:$PATH"

Port 9 is the discard port and nothing listens on it, so the orchestrator's HTTP
source is refused immediately rather than waited out. Its message is the
operating system's own and is normalised below.

  $ export SSH_ARGV_LOG="$PWD/ssh-argv.log"
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
  > managed_containers:
  >   - name: gateway
  >     image: example.com/ib-gateway
  >     tag: "10.48.1e"
  >     restart: unless-stopped
  > EOF

The failing arm. Every phase converges — the plan's own lines are unchanged, and
the run would have exited zero before this — and the one component that declares
a healthcheck never passes it inside the bound.

  $ : > "$SSH_ARGV_LOG"
  $ export HEALTH_MARKER='BONDI_CONTAINER_TIMEOUT 120'
  $ bondi-client setup > out.log 2>&1
  [1]
  $ sed -n '/^Service$/,/^$/p' out.log | sed 's/not reachable: .*/not reachable: <detail>/'
  Service
    NAME                   SOURCE  IMAGE                            TAG          STATUS        RESTARTS  HEALTH
    my-service             docker  acme/app                         1.4.0        running       0         did not pass its healthcheck within 120s
                           orch    not reachable: <detail>
  


The bound came back from the host rather than from this client's idea of what it
asked for, and the plan's own account of the run is unchanged by the failure: it
converged, and it is the box that did not.

  $ grep -c 'bondi-orchestrator is serving on server 127.0.0.1' out.log
  1

Only the container that declares a healthcheck is waited on. A container the host
says has none has nothing to pass, and spending a bound on it is how a run with
nothing to wait for waits anyway.

  $ grep -c -F 'BONDI_CONTAINER_TIMEOUT' ssh-argv.log
  1
  $ grep -F 'BONDI_CONTAINER_TIMEOUT' ssh-argv.log | grep -c -F "'my-service'"
  1
  $ grep -F 'BONDI_CONTAINER_TIMEOUT' ssh-argv.log | grep -c -F 'bondi-gateway'
  0
  [1]

The wait follows the inspection that scoped it, which is what makes it a wait on
the box as the run left it rather than as it was found.

  $ WAITED=$(grep -n -F 'BONDI_CONTAINER_TIMEOUT' ssh-argv.log | tail -1 | cut -d: -f1)
  $ INSPECTED=$(grep -n -F 'docker ps -aq | while read' ssh-argv.log | head -1 | cut -d: -f1)
  $ test "$WAITED" -gt "$INSPECTED" && echo "the wait follows the reading that scoped it"
  the wait follows the reading that scoped it

The affirmative arm, on the same fixture and the same wait: the check passes, and
the run exits zero. Without it the assertion above would be satisfied by a setup
that failed every run carrying a healthcheck, or by one that never waited at all.

  $ : > "$SSH_ARGV_LOG"
  $ export HEALTH_MARKER='BONDI_CONTAINER_HEALTHY'
  $ bondi-client setup > out.log 2>&1
  $ sed -n '/^Service$/,/^$/p' out.log | sed 's/not reachable: .*/not reachable: <detail>/'
  Service
    NAME                   SOURCE  IMAGE                            TAG          STATUS        RESTARTS  HEALTH
    my-service             docker  acme/app                         1.4.0        running       0         healthy
                           orch    not reachable: <detail>
  

  $ grep -c -F 'BONDI_CONTAINER_TIMEOUT' ssh-argv.log
  1
