`bondi setup` reads the Docker version twice: once while gathering the host's
state, and again when it carries out the EnsureDocker step. They are separate
SSH round trips, so a dropped connection can hit either one on its own. A drop
on the second used to be read as "Docker is not installed" and answered by
piping get.docker.com into root's shell, which restarts the daemon and every
container with it — on a host whose Docker was already current.

  $ ROOT="$PWD"

The stub answers the first probe with a version and drops the connection on the
second, which is the shape of the incident.

  $ mkdir -p "$ROOT/bin"
  $ cat > "$ROOT/bin/ssh" <<'STUB'
  > #!/bin/sh
  > while [ $# -gt 0 ] && [ "$1" != "--" ]; do shift; done
  > shift
  > printf '%s\n' "$1" >> "$SSH_ARGV_LOG"
  > cat > /dev/null
  > case "$1" in
  >   'docker --version')
  >     probes=$(($(cat "$DOCKER_PROBES") + 1))
  >     echo "$probes" > "$DOCKER_PROBES"
  >     if [ "$probes" -ge 2 ]; then
  >       echo 'Connection closed by 10.0.0.1 port 22' >&2
  >       exit 255
  >     fi
  >     echo 'Docker version 29.2.1, build deadbeef' ;;
  >   *) : ;;
  > esac
  > STUB
  $ chmod +x "$ROOT/bin/ssh"
  $ export PATH="$ROOT/bin:$PATH"

  $ export SSH_ARGV_LOG="$PWD/ssh-argv.log"
  $ : > "$SSH_ARGV_LOG"
  $ export DOCKER_PROBES="$PWD/docker-probes.txt"
  $ echo 0 > "$DOCKER_PROBES"
  $ cat > bondi.yaml <<'EOF'
  > service:
  >   name: my-service
  >   image: acme/app
  >   port: 8080
  >   env_vars: {}
  >   servers:
  >     - ip_address: 10.0.0.1
  >       ssh:
  >         user: deploy
  >         private_key_contents: "not-a-real-key"
  >         private_key_pass: ""
  > bondi_server:
  >   version: "0.10.1"
  > EOF

The run stops and reports the transport error, naming the server and the phases
it never reached.

  $ bondi-client setup 2>&1
  Setting up the servers...
  Processing server: 10.0.0.1
  Error: could not read the Docker version, so Docker will not be installed: command failed (255): Connection closed by 10.0.0.1 port 22
  setup stopped part-way through the Docker phase on server 10.0.0.1, so these phases did not run: network, ACME file, orchestrator.
  [1]

Nothing was installed. The affirmative arm is the probe count: the second probe
did run, so the absence below is the refusal to act on it rather than a run that
stopped earlier.

  $ grep -c 'docker --version' ssh-argv.log
  2

  $ grep -c 'get.docker.com' ssh-argv.log
  0
  [1]
