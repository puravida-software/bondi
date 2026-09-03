Setup reports whether the orchestrator is actually serving, not merely whether
`docker run -d` accepted the container. A server image whose process dies on
startup — a missing shared library aborts the loader before main and exits 127 —
used to present as a clean setup while the host was left with nothing listening.

  $ ROOT="$PWD"

The stub answers the readiness probe according to $ORCHESTRATOR_DIES, so the
same configuration can be run against a healthy image and a broken one. The
container listing the report reads afterwards answers from the same variable: a
run whose image dies leaves an exited container behind, and one that came up
leaves a running one.

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
  >   *'name=^/bondi-orchestrator$'*'{{.State}}'*) cat "$ORCHESTRATOR_PS" ;;
  >   *BONDI_ORCHESTRATOR_SERVING*)
  >     if [ -n "$ORCHESTRATOR_DIES" ]; then echo BONDI_ORCHESTRATOR_UNREACHABLE; else echo BONDI_ORCHESTRATOR_SERVING; fi ;;
  >   # Both of the arms below answer a `docker inspect`. The restart-policy
  >   # query is matched first, on the substring only it carries, so it cannot
  >   # be answered by the container-health arm however either command's flags
  >   # come to be spelled -- today they differ only by `-f` versus `--format`,
  >   # which is a thin thing for the dispatch to rest on.
  >   *'RestartPolicy'*) cat "$RESTART_POLICY" ;;
  >   *'docker inspect --format'*'State.Status'*)
  >     echo 'status=exited exit=127 oom=false error='
  >     echo '--- last 50 log lines ---'
  >     echo 'Error loading shared library libzstd.so.1: No such file or directory (needed by /usr/local/bin/bondi-server)' ;;
  >   'docker ps -a --format'*)
  >     if [ -n "$ORCHESTRATOR_DIES" ]; then
  >       printf 'bondi-orchestrator\tmlopez1506/bondi-server:0.10.1\texited\n'
  >     else
  >       printf 'bondi-orchestrator\tmlopez1506/bondi-server:0.10.1\trunning\n'
  >     fi ;;
  >   'docker ps -aq | while read -r id'*)
  >     printf '/bondi-orchestrator\tundeclared\t\t0\t2026-08-01T09:00:00.222222222Z\n' ;;
  >   *'/var/spool/cron/crontabs/root'*) echo BONDI_CRONTAB_ABSENT ;;
  >   *'PortBindings'*) echo "${PUBLISHED_ON-127.0.0.1}" ;;
  >   'docker update'*)
  >     if [ -n "$RESTART_UPDATE_STICKS" ]; then printf 'unless-stopped\n' > "$RESTART_POLICY"; fi
  >     echo bondi-orchestrator ;;
  >   *) : ;;
  > esac
  > STUB
  $ chmod +x "$ROOT/bin/ssh"
  $ export PATH="$ROOT/bin:$PATH"

Port 9 is the discard port and nothing listens on it, so the orchestrator's own
HTTP source is refused immediately rather than waited out. Its message is the
operating system's own and is normalised where it appears.

  $ export SSH_ARGV_LOG="$PWD/ssh-argv.log"
  $ export ORCHESTRATOR_PS="$PWD/orchestrator-ps.txt"
  $ : > "$ORCHESTRATOR_PS"

The host's own account of the orchestrator's restart policy, which the stub
answers from a file so that `docker update` can change it -- a policy that
sticks and one that does not are the two halves of the assertion below.

  $ export RESTART_POLICY="$PWD/restart-policy.txt"
  $ printf 'unless-stopped\n' > "$RESTART_POLICY"
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
  >   version: "0.10.1"
  > EOF

An orchestrator that answers its health endpoint is reported as serving, naming
the image that is actually up, and the run ends on the report of what the host
holds.

  $ bondi-client setup 2>&1 | sed 's/not reachable: .*/not reachable: <detail>/'
  Setting up the servers...
  Processing server: 127.0.0.1
  Docker is already installed on server 127.0.0.1: Docker version 27.0.0, build deadbeef
  Network bondi-network is present on server 127.0.0.1
  ACME file permissions updated on server 127.0.0.1: /etc/traefik/acme/acme.json
  bondi-orchestrator is serving on server 127.0.0.1: mlopez1506/bondi-server:0.10.1
  
  Server: 127.0.0.1
  
  Service
    NAME                   SOURCE  IMAGE                            TAG          STATUS        RESTARTS  HEALTH
    my-service             docker  -                                -            not found     -         -
                           orch    not reachable: <detail>
  
  Infrastructure
    NAME                   SOURCE  IMAGE                            TAG          STATUS        RESTARTS  HEALTH
    bondi-orchestrator     docker  mlopez1506/bondi-server          0.10.1       running       0         no healthcheck defined
                           orch    not reachable: <detail>
  
  Crontab
    bondi section          docker  no Bondi section on the host


The container is started without --rm. Under --rm a container that dies on
startup deletes itself, taking its logs with it, which is what made the outage
undiagnosable.

  $ grep -c -- '--rm' ssh-argv.log
  0
  [1]

Starting it is not the same fact as it serving, so the run is followed by a
request to the health endpoint.

  $ grep -c 'api/v1/health' ssh-argv.log
  1

An orchestrator that never answers fails the setup and reports the server's own
account of why, rather than printing success. It was the last phase of this
plan, so the report says that nothing after it was skipped rather than staying
silent about the question.

The run then reports the host itself, which is the reading this failure used to
need a human for: the container is on the box and not serving, and the source
that would have said otherwise could not be reached. The phase report says which
phases did not run; this one says what is on the box now, and both are printed.

  $ : > ssh-argv.log
  $ ORCHESTRATOR_DIES=1 bondi-client setup > out.log 2>&1
  [1]
  $ sed 's/not reachable: .*/not reachable: <detail>/' out.log
  Setting up the servers...
  Processing server: 127.0.0.1
  Docker is already installed on server 127.0.0.1: Docker version 27.0.0, build deadbeef
  Network bondi-network is present on server 127.0.0.1
  ACME file permissions updated on server 127.0.0.1: /etc/traefik/acme/acme.json
  Error: bondi-orchestrator did not come up on server 127.0.0.1.
  Image: mlopez1506/bondi-server:0.10.1
  the orchestrator container did not answer GET /api/v1/health. The readiness check answered: BONDI_ORCHESTRATOR_UNREACHABLE
  Container state and logs from the server:
  status=exited exit=127 oom=false error=
  --- last 50 log lines ---
  Error loading shared library libzstd.so.1: No such file or directory (needed by /usr/local/bin/bondi-server)
  The container was left in place so it can be inspected: run `docker logs bondi-orchestrator` on 127.0.0.1. To restore service, set bondi_server.version in bondi.yaml back to a version known to run on this host and run `bondi setup` again.
  setup stopped part-way through the orchestrator phase on server 127.0.0.1, which was the last one, so no phase was skipped.
  
  Server: 127.0.0.1
  
  Service
    NAME                   SOURCE  IMAGE                            TAG          STATUS        RESTARTS  HEALTH
    my-service             docker  -                                -            not found     -         -
                           orch    not reachable: <detail>
  
  Infrastructure
    NAME                   SOURCE  IMAGE                            TAG          STATUS        RESTARTS  HEALTH
    bondi-orchestrator     docker  mlopez1506/bondi-server          0.10.1       exited        0         no healthcheck defined
                           orch    not reachable: <detail>
  
  Crontab
    bondi section          docker  no Bondi section on the host



Nothing claimed success on that run.

  $ grep -c 'is serving' ssh-argv.log
  0
  [1]

A container left behind by a failed start is removed before the next attempt,
rather than colliding with the name and making `bondi setup` — the command an
operator reaches for to recover — fail too.

  $ printf 'exited\tmlopez1506/bondi-server:0.10.1\n' > "$ORCHESTRATOR_PS"
  $ : > ssh-argv.log
  $ bondi-client setup 2>&1 | sed 's/not reachable: .*/not reachable: <detail>/' | head -8
  Setting up the servers...
  Processing server: 127.0.0.1
  bondi-orchestrator on server 127.0.0.1 exists but is not running, replacing it...
  Docker is already installed on server 127.0.0.1: Docker version 27.0.0, build deadbeef
  Network bondi-network is present on server 127.0.0.1
  ACME file permissions updated on server 127.0.0.1: /etc/traefik/acme/acme.json
  Removed bondi-orchestrator container on server 127.0.0.1
  bondi-orchestrator is serving on server 127.0.0.1: mlopez1506/bondi-server:0.10.1


The removal asserts the outcome rather than the exit status of `docker rm`: an
orchestrator started by an older Bondi ran with --rm, so `docker stop` has
already deleted it and `docker rm` reports "no such container" on a host that is
in exactly the state wanted.

  $ grep -c 'could not be removed' ssh-argv.log
  1


The publish address is declared in bondi.yaml, and setup checks what the host
actually published rather than trusting that `docker run` applied it.

Until 2026-08-29 setup ran `-p 3030:3030` unconditionally, publishing an
unauthenticated API that mounts the host Docker socket on every interface. One
box had been closed by a loopback binding applied by hand and recorded nowhere;
a later setup converged that box against bondi.yaml, which did not mention the
binding, and silently re-exposed a production orchestrator. The run reported
success and the readiness probe agreed, because "is it up" and "who can reach
it" are different questions. These two assertions are that difference.

  $ : > "$ORCHESTRATOR_PS"
  $ : > ssh-argv.log
  $ bondi-client setup > /dev/null 2>&1
  $ grep -o -- '-p 127.0.0.1:3030:3030' ssh-argv.log | head -1
  -p 127.0.0.1:3030:3030

The wide form is never emitted.

  $ grep -c -- '-p 3030:3030' ssh-argv.log || true
  0

When the host reports a binding other than the one asked for, setup fails and
names both. Docker reports "every interface" as an empty HostIp, which must read
as 0.0.0.0 rather than as agreement with the request -- otherwise the check
passes on exactly the configuration it exists to catch.

  $ : > "$ORCHESTRATOR_PS"
  $ PUBLISHED_ON=0.0.0.0 bondi-client setup 2>&1 | grep -o 'orchestrator published on .* asks for [0-9.]*'
  orchestrator published on 0.0.0.0 but bondi.yaml asks for 127.0.0.1

  $ : > "$ORCHESTRATOR_PS"
  $ PUBLISHED_ON= bondi-client setup 2>&1 | grep -o 'orchestrator published on .* asks for [0-9.]*'
  orchestrator published on 0.0.0.0 but bondi.yaml asks for 127.0.0.1


Docker's default restart policy is `no`, so a host reboot, a docker-ce upgrade
or a daemon crash silently removes a container that was never given one. The run
command's flag is not evidence that the flag took: on 2026-09-02 an audit found
an orchestrator at `no` on a box `bondi setup` had converged. So the applied
policy is read from the host on every run, not only when the container happens
to need recreating for some other reason.

An orchestrator already carrying the declared policy is left alone -- no `docker
update` reaches the host at all. The inspect is counted too, so that the absent
update is known to be a decision this run took rather than a phase it never
reached.

  $ printf 'running\tmlopez1506/bondi-server:0.10.1\n' > "$ORCHESTRATOR_PS"
  $ printf 'unless-stopped\n' > "$RESTART_POLICY"
  $ : > ssh-argv.log
  $ bondi-client setup > out.log 2>&1
  $ grep -c 'RestartPolicy' ssh-argv.log
  1
  $ grep -c 'docker update' ssh-argv.log
  0
  [1]
  $ grep -c 'restart policy' out.log
  0
  [1]

The affirmative half of that pair: the same stub and the same bondi.yaml,
differing only in what the host reports, and now the update does reach it. The
correction is applied in place -- the orchestrator is not stopped, removed or
re-run, because recreating it would drop TLS for every site on the box to change
a flag. The policy is read a second time afterwards, since `docker update`
accepting the command is not the same fact as the daemon having applied it.

  $ printf 'running\tmlopez1506/bondi-server:0.10.1\n' > "$ORCHESTRATOR_PS"
  $ printf 'no\n' > "$RESTART_POLICY"
  $ : > ssh-argv.log
  $ RESTART_UPDATE_STICKS=1 bondi-client setup > out.log 2>&1
  $ grep 'restart policy' out.log
  bondi-orchestrator restart policy on server 127.0.0.1 was no, corrected to unless-stopped without restarting it
  $ grep -c 'docker update --restart=unless-stopped bondi-orchestrator' ssh-argv.log
  1
  $ grep -c 'RestartPolicy' ssh-argv.log
  2
  $ grep -c 'docker stop\|docker rm\|docker run' ssh-argv.log
  0
  [1]

A host that still reports the old policy after the update fails the run and
names both what it reported and what was asked for. Accepting the update as
proof of itself is the same assumption the run command's flag already made.

  $ printf 'running\tmlopez1506/bondi-server:0.10.1\n' > "$ORCHESTRATOR_PS"
  $ printf 'no\n' > "$RESTART_POLICY"
  $ : > ssh-argv.log
  $ bondi-client setup > out.log 2>&1
  [1]
  $ grep 'still' out.log
  Error: bondi-orchestrator restart policy on server 127.0.0.1 is still no after asking for unless-stopped -- refusing to report success on a posture that was not applied
