`bondi setup` reads the Docker version twice: once while gathering the host's
state, and again when it carries out the EnsureDocker step. They are separate
SSH round trips, so a dropped connection can hit either one on its own. A drop
on the second used to be read as "Docker is not installed" and answered by
piping get.docker.com into root's shell, which restarts the daemon and every
container with it — on a host whose Docker was already current.

Every probe this file covers is the same shape: a command that could not be run
at all is not the host's answer to what it was asked. The three arms below are
the three places setup asks something of a host and can be told nothing.

  $ ROOT="$PWD"

The stub answers each probe, and drops the connection on whichever one the arm
under test names. Only one is ever dropped at a time, so a run that stopped can
only have stopped on the probe that arm broke.

  $ mkdir -p "$ROOT/bin"
  $ cat > "$ROOT/bin/ssh" <<'STUB'
  > #!/bin/sh
  > while [ $# -gt 0 ] && [ "$1" != "--" ]; do shift; done
  > shift
  > printf '%s\n' "$1" >> "$SSH_ARGV_LOG"
  > cat > /dev/null
  > drop() { echo 'Connection closed by 10.0.0.1 port 22' >&2; exit 255; }
  > case "$1" in
  >   *BONDI_ACME_PRESENT*)
  >     [ -n "$ACME_DROPS" ] && drop
  >     echo BONDI_ACME_PRESENT ;;
  >   'curl --version')
  >     [ -n "$CURL_DROPS" ] && drop
  >     echo 'curl 8.5.0 (x86_64-pc-linux-gnu) libcurl/8.5.0' ;;
  >   'docker --version')
  >     probes=$(($(cat "$DOCKER_PROBES") + 1))
  >     echo "$probes" > "$DOCKER_PROBES"
  >     if [ -n "$DOCKER_DROPS_SECOND" ] && [ "$probes" -ge 2 ]; then drop; fi
  >     echo 'Docker version 29.2.1, build deadbeef' ;;
  >   *'/var/spool/cron/crontabs/root'*) echo BONDI_CRONTAB_ABSENT ;;
  >   *) : ;;
  > esac
  > STUB
  $ chmod +x "$ROOT/bin/ssh"
  $ export PATH="$ROOT/bin:$PATH"

  $ export SSH_ARGV_LOG="$PWD/ssh-argv.log"
  $ : > "$SSH_ARGV_LOG"
  $ export DOCKER_PROBES="$PWD/docker-probes.txt"
  $ echo 0 > "$DOCKER_PROBES"
  $ export DOCKER_DROPS_SECOND=1
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

The run stops and reports the transport error, naming the server and the phases
it never reached. A run that stopped in its first phase still reaches the report,
which is where the host it stopped on is described: the stub answers nothing for
the report's own reads, so every row reads as not found.

  $ bondi-client setup > out.log 2>&1
  [1]
  $ sed 's/not reachable: .*/not reachable: <detail>/' out.log
  Setting up the servers...
  Processing server: 127.0.0.1
  Error: could not read the Docker version, so Docker will not be installed: command failed (255): Connection closed by 10.0.0.1 port 22
  setup stopped part-way through the Docker phase on server 127.0.0.1, so these phases did not run: network, ACME file, orchestrator.
  
  Server: 127.0.0.1
  
  Service
    NAME                   SOURCE  IMAGE                            TAG          STATUS        RESTARTS  HEALTH
    my-service             docker  -                                -            not found     -         -
                           orch    not reachable: <detail>
  
  Infrastructure
    NAME                   SOURCE  IMAGE                            TAG          STATUS        RESTARTS  HEALTH
    bondi-orchestrator     docker  -                                -            not found     -         -
                           orch    not reachable: <detail>
  
  Crontab
    bondi section          docker  no Bondi section on the host



Nothing was installed. The affirmative arm is the probe count: the second probe
did run, so the absence below is the refusal to act on it rather than a run that
stopped earlier.

  $ grep -c 'docker --version' ssh-argv.log
  2

  $ grep -c 'get.docker.com' ssh-argv.log
  0
  [1]

The curl probe is the same shape. The crontab line uses --fail-with-body and an
older curl rejects it as unknown, so setup reads the version before the
orchestrator starts — and a read that never happened has no version in it. Its
text used to be handed to the version comparison as though curl had printed it,
so the operator was told the host reported "command failed (255): Connection
closed by 10.0.0.1 port 22" but 7.76.0 is required.

  $ : > "$SSH_ARGV_LOG"
  $ echo 0 > "$DOCKER_PROBES"
  $ unset DOCKER_DROPS_SECOND
  $ export CURL_DROPS=1
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
  > EOF
  $ bondi-client setup > out.log 2>&1
  [1]
  $ grep -A1 '^Error:' out.log
  Error: could not read the curl version on the server, so setup will not act on whether it can run the crontab command: command failed (255): Connection closed by 10.0.0.1 port 22
  setup stopped part-way through the cron curl phase on server 127.0.0.1, so these phases did not run: ACME file, orchestrator.

The affirmative arm is the probe count again: curl was asked, so the refusal
below is setup declining to act on an answer it never got rather than a run that
stopped before reaching the question.

  $ grep -c 'curl --version' ssh-argv.log
  1
  $ grep -c 'name bondi-orchestrator' ssh-argv.log
  0
  [1]
  $ unset CURL_DROPS

And the ACME file. This one asks whether a file exists, which a shell answers by
exiting non-zero when it does not — the same channel a dropped connection
arrives on. Read as the file being absent, a blip answered with mkdir, touch,
chown and chmod against a host that was never asked.

  $ : > "$SSH_ARGV_LOG"
  $ echo 0 > "$DOCKER_PROBES"
  $ export ACME_DROPS=1
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
  $ bondi-client setup > out.log 2>&1
  [1]
  $ grep -A1 '^Error:' out.log
  Error: could not read whether /etc/traefik/acme/acme.json exists on the server, so setup will not act on whether it does: command failed (255): Connection closed by 10.0.0.1 port 22
  setup stopped part-way through the ACME file phase on server 127.0.0.1, so these phases did not run: orchestrator.

Nothing was written. The probe did run, so the absence below is the refusal to
act on a reading nobody took rather than a phase that was never reached.

  $ grep -c 'BONDI_ACME_PRESENT' ssh-argv.log
  1
  $ grep -c 'sudo mkdir -p /etc/traefik/acme' ssh-argv.log
  0
  [1]
  $ grep -c 'sudo chown root:root' ssh-argv.log
  0
  [1]
