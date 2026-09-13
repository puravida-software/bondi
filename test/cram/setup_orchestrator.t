Setup reports whether the orchestrator is actually serving, not merely whether
`docker run -d` accepted the container. A server image whose process dies on
startup — a missing shared library aborts the loader before main and exits 127 —
used to present as a clean setup while the host was left with nothing listening.

  $ ROOT="$PWD"

The stub answers the readings setup takes according to $ORCHESTRATOR_DIES,
$ORCHESTRATOR_NOT_READY and $ORCHESTRATOR_LOG_SILENT, so the same configuration
can be run against a healthy image, one that never starts, one that starts and
cannot serve, and one that serves while nothing it writes reaches its log
stream. The
container listing the report reads afterwards answers from the first of those: a
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
  >   # The wait for the container to reach a running state. Matched on the
  >   # loop's own opening rather than on `docker inspect`, because the
  >   # diagnostics read further down is also a `docker inspect --format`
  >   # carrying {{.State.Status}}, and an arm written for one would answer the
  >   # other. $ORCHESTRATOR_DIES is a container that never got there.
  >   'attempt=0; while'*)
  >     if [ -n "$ORCHESTRATOR_DIES" ]; then
  >       echo 'container bondi-orchestrator did not reach a running state after 30 attempts; its last state was exited' >&2
  >       exit 1
  >     fi ;;
  >   # The one reading setup takes off the box, and the two ways it can be
  >   # refused. $ORCHESTRATOR_NOT_READY is a container that is up and cannot
  >   # serve, which exits with the readiness code and names the fault. The
  >   # healthy arm has to write a document: a command that exits zero saying
  >   # nothing is a rejection, not a pass.
  >   *'bondi-server check'*)
  >     if [ -n "$ORCHESTRATOR_NOT_READY" ]; then
  >       echo 'the Docker socket at /var/run/docker.sock is not readable' >&2
  >       exit 3
  >     fi
  >     echo '{"ready":true,"observations":[]}' ;;
  >   # The log-stream read setup takes after the reading. It establishes what
  >   # no probe inside the container can: that a line the server wrote to its
  >   # diagnostic sink reaches the stream an operator and a log shipper read.
  >   # The pattern is anchored at the start of the command, because the
  >   # diagnostics read further down ends in a `docker logs --tail` of its own
  >   # and a pattern with a leading wildcard would answer that one too.
  >   # $ORCHESTRATOR_LOG_SILENT is a container whose diagnostics never arrive:
  >   # it answers the read and carries nothing.
  >   'docker logs --tail'*)
  >     if [ -z "$ORCHESTRATOR_LOG_SILENT" ]; then
  >       echo 'bondi check: diagnostic sink is writable'
  >     fi ;;
  >   # Both of the arms below answer a `docker inspect`. The restart-policy
  >   # query is matched first, on the substring only it carries, so it cannot
  >   # be answered by the container-health arm however either command's flags
  >   # come to be spelled -- today they differ only by `-f` versus `--format`,
  >   # which is a thin thing for the dispatch to rest on.
  >   *'RestartPolicy'*) cat "$RESTART_POLICY" ;;
  >   # The container's own account, quoted by a run that refused. It is keyed on
  >   # the same variables the readings are, so the account cannot contradict the
  >   # refusal it is quoted beside: a container that answered the check is
  >   # running here, and one whose log stream carries nothing shows a log stream
  >   # carrying nothing.
  >   *'docker inspect --format'*'State.Status'*)
  >     if [ -n "$ORCHESTRATOR_DIES" ]; then
  >       echo 'status=exited exit=127 oom=false error='
  >       echo '--- last 50 log lines ---'
  >       echo 'Error loading shared library libzstd.so.1: No such file or directory (needed by /usr/local/bin/bondi-server)'
  >     else
  >       echo 'status=running exit=0 oom=false error='
  >       echo '--- last 50 log lines ---'
  >       if [ -n "$ORCHESTRATOR_NOT_READY" ]; then
  >         echo 'bondi check: the Docker socket at /var/run/docker.sock is not readable'
  >       else
  >         echo 'listening on 0.0.0.0:3030'
  >       fi
  >     fi ;;
  >   'docker ps -a --format'*)
  >     if [ -n "$ORCHESTRATOR_DIES" ]; then
  >       printf 'bondi-orchestrator\tmlopez1506/bondi-server:0.15.0\texited\n'
  >     else
  >       printf 'bondi-orchestrator\tmlopez1506/bondi-server:0.15.0\trunning\n'
  >     fi ;;
  >   'docker ps -aq | while read -r id'*)
  >     printf '/bondi-orchestrator\tundeclared\t\t0\t2026-08-01T09:00:00.222222222Z\n' ;;
  >   *'/var/spool/cron/crontabs/root'*)
  >     if [ -n "$CRONTAB_SPOOL" ]; then cat "$CRONTAB_SPOOL"; else echo BONDI_CRONTAB_ABSENT; fi ;;
  >   *'docker cp'*) : ;;
  >   *BONDI_CRON_PAYLOAD_LISTED*)
  >     echo BONDI_CRON_PAYLOAD_LISTED
  >     echo BONDI_CRON_PAYLOAD_END ;;
  >   *'PortBindings'*) echo "${PUBLISHED_ON-127.0.0.1}" ;;
  >   'docker update'*)
  >     if [ -n "$RESTART_UPDATE_STICKS" ]; then printf 'unless-stopped\n' > "$RESTART_POLICY"; fi
  >     echo bondi-orchestrator ;;
  >   # The orchestrator's image on its own, which is the version the report's
  >   # orchestrator read holds this box to before running a subcommand inside
  >   # its container. Without this arm the command falls through to *) and
  >   # answers nothing, which reads as a box whose version could not be read --
  >   # the same unavailable source for a reason no fixture chose. The pattern
  >   # ends the command rather than merely containing it: the probe's own
  >   # listing asks for {{.State}} and {{.Image}} together, and an arm that
  >   # matched both would answer the probe with a version.
  >   *'name=^/bondi-orchestrator$'*"--format '{{.Image}}'") echo 'mlopez1506/bondi-server:0.15.0' ;;
  >   # The closing report's own reading, which is a different question from the
  >   # one setup takes and is answered here so that a fall-through to *) cannot
  >   # stand in for it. This fixture declares nothing about what the report
  >   # says, so the arm refuses and every report line below is normalised.
  >   *'bondi-server status'*) echo 'this fixture does not answer the report' >&2; exit 1 ;;
  >   *) : ;;
  > esac
  > STUB
  $ chmod +x "$ROOT/bin/ssh"
  $ export PATH="$ROOT/bin:$PATH"

Port 9 is the discard port and nothing listens on it, so nothing this file runs
waits on a real connection. The report's own reading of the orchestrator is
refused by the stub instead, and its message is normalised wherever it appears.

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
  >   version: "0.15.0"
  > EOF

An orchestrator whose own check says the box can serve is reported as serving,
naming the image that is actually up, and the run ends on the report of what the
host holds.

  $ bondi-client setup > out.log 2>&1
  $ sed 's/not reachable: .*/not reachable: <detail>/' out.log
  Setting up the servers...
  Processing server: 127.0.0.1
  Docker is already installed on server 127.0.0.1: Docker version 27.0.0, build deadbeef
  Network bondi-network is present on server 127.0.0.1
  ACME file permissions updated on server 127.0.0.1: /etc/traefik/acme/acme.json
  bondi-orchestrator is serving on server 127.0.0.1: mlopez1506/bondi-server:0.15.0
  No alloy is configured for server 127.0.0.1: /etc/bondi/alloy is not on the host
  
  Server: 127.0.0.1
  
  Service
    NAME                   SOURCE  IMAGE                            TAG          STATUS        RESTARTS  HEALTH
    my-service             docker  -                                -            not found     -         -
                           orch    not reachable: <detail>
  
  Infrastructure
    NAME                   SOURCE  IMAGE                            TAG          STATUS        RESTARTS  HEALTH
    bondi-orchestrator     docker  mlopez1506/bondi-server          0.15.0       running       0         no healthcheck defined
                           orch    not reachable: <detail>
  
  Crontab
    bondi section          docker  no Bondi section on the host


The container is started without --rm. Under --rm a container that dies on
startup deletes itself, taking its logs with it, which is what made the outage
undiagnosable.

  $ grep -c -- '--rm' ssh-argv.log
  0
  [1]

Starting it is not the same fact as it serving, so the run is followed by the
server's own check, taken inside the container it just started. Exactly one
reading: the check acts on the box every time it is invoked, and the wait ahead
of it is what makes one enough.

  $ grep -c 'bondi-server check' ssh-argv.log
  1

The wait comes first. Read the other way round, the reading would answer for a
container that had not started yet, which is the whole of what the wait is for.

  $ awk '/attempt=0; while/ { wait = NR } /bondi-server check/ { reading = NR } END { print (wait && reading && wait < reading) ? "the wait is first" : "out of order" }' ssh-argv.log
  the wait is first

Nothing fetches a health endpoint over a published port any more. The count
above is this line's affirmative half: the reading did reach the host, and it
reached it by running a command inside the container.

  $ grep -c 'api/v1/health\|wget' ssh-argv.log
  0
  [1]

This configuration declares no cron job and this host answered that it holds no
Bondi section, so nothing here is cron-converged and the reading does not ask the
box about its crontab spool. The answer is the client's -- what bondi.yaml
declares together with the crontab this run has already listed -- and not the
container's: a container cannot soundly tell whether the deployment it belongs
to schedules anything, nor what its host's crontab is holding. The affirmative
half is again the count above -- the reading reached the host, and it reached it
without the flag.

  $ grep -c -- '--cron-configured' ssh-argv.log
  0
  [1]

An orchestrator that never answers fails the setup and reports the server's own
account of why, rather than printing success. The alloy phase follows it even
here, where nothing declares alloy: the config directory is removed from what
the configuration says rather than from what a container listing shows, so the
report has a skipped phase to name rather than staying silent about the
question.

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
  Image: mlopez1506/bondi-server:0.15.0
  the wait for the orchestrator container to reach a running state ran on the host and failed: command failed (1): container bondi-orchestrator did not reach a running state after 30 attempts; its last state was exited
  Container state and logs from the server:
  status=exited exit=127 oom=false error=
  --- last 50 log lines ---
  Error loading shared library libzstd.so.1: No such file or directory (needed by /usr/local/bin/bondi-server)
  The container was left in place so it can be inspected: run `docker logs bondi-orchestrator` on 127.0.0.1. To restore service, set bondi_server.version in bondi.yaml back to a version known to run on this host and run `bondi setup` again.
  setup stopped part-way through the orchestrator phase on server 127.0.0.1, so these phases did not run: alloy.
  
  Server: 127.0.0.1
  
  Service
    NAME                   SOURCE  IMAGE                            TAG          STATUS        RESTARTS  HEALTH
    my-service             docker  -                                -            not found     -         -
                           orch    not reachable: <detail>
  
  Infrastructure
    NAME                   SOURCE  IMAGE                            TAG          STATUS        RESTARTS  HEALTH
    bondi-orchestrator     docker  mlopez1506/bondi-server          0.15.0       exited        0         no healthcheck defined
                           orch    not reachable: <detail>
  
  Crontab
    bondi section          docker  no Bondi section on the host



Nothing claimed success on that run.

  $ grep -c 'is serving' ssh-argv.log
  0
  [1]

An orchestrator that came up and cannot serve is the other refusal, and it is
the one the published health endpoint could not report: that endpoint answered
204 and named nothing, where the server's own check names the probe that failed.
The container is running here, so the wait passes and it is the reading that
refuses -- and the run still quotes the container's own account beside it.

  $ : > "$ORCHESTRATOR_PS"
  $ : > ssh-argv.log
  $ ORCHESTRATOR_NOT_READY=1 bondi-client setup > out.log 2>&1
  [1]
  $ grep -A4 'did not come up' out.log
  Error: bondi-orchestrator did not come up on server 127.0.0.1.
  Image: mlopez1506/bondi-server:0.15.0
  the box reported it is not in a state to serve: command failed (3): the Docker socket at /var/run/docker.sock is not readable
  Container state and logs from the server:
  status=running exit=0 oom=false error=

The reading was taken -- the box was asked and answered -- which is what makes
the refusal above the box's own verdict rather than a command that never ran.

  $ grep -c 'bondi-server check' ssh-argv.log
  1


An orchestrator that answers the check is not the same fact as an orchestrator
whose diagnostics can be seen. The check writes a line to its diagnostic sink
and reports that the sink took it; whether that line reaches the stream `docker
logs` serves is a question only something outside the container can ask. A
deployment that has quietly lost its log stream passes every probe and tells
nobody anything afterwards, which is the state this arm refuses.

  $ : > "$ORCHESTRATOR_PS"
  $ : > ssh-argv.log
  $ ORCHESTRATOR_LOG_SILENT=1 bondi-client setup > out.log 2>&1
  [1]
  $ grep -A3 'did not come up' out.log
  Error: bondi-orchestrator did not come up on server 127.0.0.1.
  Image: mlopez1506/bondi-server:0.15.0
  the box answered, and the line it writes to its diagnostic sink was not in the container's recent log output -- the sink took the bytes and the stream an operator and a log shipper read is not carrying them
  Container state and logs from the server:

The stream was read once, and it was read after the check that writes the line
being looked for. Read the other way round it would report every orchestrator as
silent, including the ones that are not.

  $ grep -c "docker logs --tail 50 'bondi-orchestrator'" ssh-argv.log
  1
  $ awk '/bondi-server check/ { check = NR } /docker logs --tail/ && !/docker inspect/ { logs = NR } END { print (check && logs && check < logs) ? "the check is first" : "out of order" }' ssh-argv.log
  the check is first

The affirmative half, on the same fixture: the only thing that differs is
whether the container's log stream carries the line, and with it there the same
run reports the orchestrator as serving. Without this arm the refusal above
could be a fixture that had stopped reaching the phase at all, and it would read
as coverage either way.

  $ : > "$ORCHESTRATOR_PS"
  $ : > ssh-argv.log
  $ bondi-client setup > out.log 2>&1
  $ grep 'is serving' out.log
  bondi-orchestrator is serving on server 127.0.0.1: mlopez1506/bondi-server:0.15.0
  $ grep -c "docker logs --tail 50 'bondi-orchestrator'" ssh-argv.log
  1


A container left behind by a failed start is removed before the next attempt,
rather than colliding with the name and making `bondi setup` — the command an
operator reaches for to recover — fail too.

  $ printf 'exited\tmlopez1506/bondi-server:0.15.0\n' > "$ORCHESTRATOR_PS"
  $ : > ssh-argv.log
  $ bondi-client setup > out.log 2>&1
  $ sed 's/not reachable: .*/not reachable: <detail>/' out.log | head -8
  Setting up the servers...
  Processing server: 127.0.0.1
  bondi-orchestrator on server 127.0.0.1 exists but is not running, replacing it...
  Docker is already installed on server 127.0.0.1: Docker version 27.0.0, build deadbeef
  Network bondi-network is present on server 127.0.0.1
  ACME file permissions updated on server 127.0.0.1: /etc/traefik/acme/acme.json
  Removed bondi-orchestrator container on server 127.0.0.1
  bondi-orchestrator is serving on server 127.0.0.1: mlopez1506/bondi-server:0.15.0


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
  $ PUBLISHED_ON=0.0.0.0 bondi-client setup > out.log 2>&1
  [1]
  $ grep -o 'orchestrator published on .* asks for [0-9.]*' out.log
  orchestrator published on 0.0.0.0 but bondi.yaml asks for 127.0.0.1

  $ : > "$ORCHESTRATOR_PS"
  $ PUBLISHED_ON= bondi-client setup > out.log 2>&1
  [1]
  $ grep -o 'orchestrator published on .* asks for [0-9.]*' out.log
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

  $ printf 'running\tmlopez1506/bondi-server:0.15.0\n' > "$ORCHESTRATOR_PS"
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

  $ printf 'running\tmlopez1506/bondi-server:0.15.0\n' > "$ORCHESTRATOR_PS"
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

  $ printf 'running\tmlopez1506/bondi-server:0.15.0\n' > "$ORCHESTRATOR_PS"
  $ printf 'no\n' > "$RESTART_POLICY"
  $ : > ssh-argv.log
  $ bondi-client setup > out.log 2>&1
  [1]
  $ grep 'still' out.log
  Error: bondi-orchestrator restart policy on server 127.0.0.1 is still no after asking for unless-stopped -- refusing to report success on a posture that was not applied


A host holding a Bondi section gets its cron payload directory copied out of the
orchestrator before that container is stopped and removed. On a box that does
not bind-mount the directory the files live in the container's writable layer,
so the removal deletes every job's run file while the line that reads it stays
in the spool -- and the job then fails silently at every fire until someone
deploys it again.

The stub answers the copy and the listing positively. A command falling through
to the stub's last arm answers with nothing, which this client reads as "the
directory could not be listed" rather than as an empty one, so an unanswered arm
would make the assertions below pass while proving nothing reached the host.

  $ printf 'BONDI_CRONTAB_CONTENTS\n# BEGIN BONDI CRON\n0 3 * * * docker exec bondi-orchestrator sh -c '"'"'bondi-server run < /etc/bondi/cron/nightly-report/run.json'"'"'\n# END BONDI CRON\nBONDI_CRONTAB_END\n' > crontab-spool.txt
  $ export CRONTAB_SPOOL="$PWD/crontab-spool.txt"
  $ printf 'running\tmlopez1506/bondi-server:0.9.0\n' > "$ORCHESTRATOR_PS"
  $ printf 'unless-stopped\n' > "$RESTART_POLICY"
  $ : > ssh-argv.log
  $ bondi-client setup > out.log 2>&1
  $ grep 'Preserved the cron payload' out.log
  Preserved the cron payload directory on server 127.0.0.1 ahead of the orchestrator recreate

The listing comes back empty, so the job the section names holds neither file --
which is the loss this phase exists to report rather than to hide.

The run says it twice, and the two are not a duplicate: the first is the listing
taken with the copy, before anything stopped the container, and the second is the
report taken after the whole run, which is the state the operator is left with.
A run that repaired the job between them would print the first and not the
second, and that difference is the only thing that could tell them apart.

  $ grep 'cron job nightly-report' out.log | sed 's/^ *//' | sort -u
  cron job nightly-report on server 127.0.0.1 has neither its run file nor its secret environment file on the box, so it fails at its next fire until it is deployed again
  $ grep -c 'cron job nightly-report' out.log
  2

The line above is worth nothing on its own: it is the only assertion in this
block that a degraded read silences, and it is silenced by absence. A crontab
that came back unreadable names no job, so no shortfall line prints, the grep
above returns nothing, and every other assertion here -- the copy, its ordering,
the mount -- goes on passing. So the same run is made to say out loud that the
section was read and read as holding this job.

  $ grep 'bondi section' out.log
    bondi section          docker  1 jobs (nightly-report)

The other half of the same silence is the payload listing. A directory that
could not be listed names no job either, and it says so on its own line; that
line not being here is what makes the emptiness the directory's answer rather
than a read that never happened.

  $ grep -c 'still hold their files could not be read' out.log
  0
  [1]

The copy reached the host, and it reached it before the stop. Planned the other
way round it would copy out of a container that is already gone and report every
job as having lost everything, on the run that lost it.

  $ grep -c -- 'docker cp' ssh-argv.log
  1
  $ awk '/docker cp/ { copy = NR } / stop bondi-orchestrator/ { stop = NR } END { print (copy && stop && copy < stop) ? "the copy is first" : "out of order" }' ssh-argv.log
  the copy is first

No job's name reaches a command line on either machine. The whole directory
moves in one copy, so nothing read out of the section is ever built into argv --
where it would be visible in the host's process table to anyone who can read
/proc.

  $ grep -c 'nightly-report' ssh-argv.log
  0
  [1]

The replacement container is given the host directory the copy just wrote into.
The crontab line's redirect is evaluated inside the container, so an orchestrator
started without this mount reads an empty /etc/bondi/cron -- and the listing,
which reads the host's copy, would go on reporting every job as holding its
files while every one of them failed at its next fire. The configuration here
declares no cron job at all: what asks for the mount is the section the host is
holding, which is the same fact that asked for the copy.

  $ grep -c 'etc/bondi/cron:/etc/bondi/cron' ssh-argv.log
  1

The reading is asked the same question the mount was. This box declares no cron
job and is holding a Bondi section all the same -- the shape the payload phase
exists for, and the shape whose crontab is likeliest to hold a line for a job
nothing declares any more. Asked from the configuration alone, the box that most
needs its spool and its divergence looked at would be the one the reading never
asks about, on a container that has the mounts and could answer.

  $ grep -c -- 'bondi-server check --cron-configured' ssh-argv.log
  1
