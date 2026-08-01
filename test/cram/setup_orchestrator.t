Setup reports whether the orchestrator is actually serving, not merely whether
`docker run -d` accepted the container. A server image whose process dies on
startup — a missing shared library aborts the loader before main and exits 127 —
used to present as a clean setup while the host was left with nothing listening.

  $ ROOT="$PWD"

The stub answers the readiness probe according to $ORCHESTRATOR_DIES, so the
same configuration can be run against a healthy image and a broken one.

  $ mkdir -p "$ROOT/bin"
  $ cat > "$ROOT/bin/ssh" <<'STUB'
  > #!/bin/sh
  > while [ $# -gt 0 ] && [ "$1" != "--" ]; do shift; done
  > shift
  > printf '%s\n' "$1" >> "$SSH_ARGV_LOG"
  > cat > /dev/null
  > case "$1" in
  >   'docker --version') echo 'Docker version 27.0.0, build deadbeef' ;;
  >   *'name=^/bondi-orchestrator$'*'{{.State}}'*) cat "$ORCHESTRATOR_PS" ;;
  >   *BONDI_ORCHESTRATOR_SERVING*)
  >     if [ -n "$ORCHESTRATOR_DIES" ]; then echo BONDI_ORCHESTRATOR_UNREACHABLE; else echo BONDI_ORCHESTRATOR_SERVING; fi ;;
  >   *'docker inspect --format'*'State.Status'*)
  >     echo 'status=exited exit=127 oom=false error='
  >     echo '--- last 50 log lines ---'
  >     echo 'Error loading shared library libzstd.so.1: No such file or directory (needed by /usr/local/bin/bondi-server)' ;;
  >   *) : ;;
  > esac
  > STUB
  $ chmod +x "$ROOT/bin/ssh"
  $ export PATH="$ROOT/bin:$PATH"

  $ export SSH_ARGV_LOG="$PWD/ssh-argv.log"
  $ export ORCHESTRATOR_PS="$PWD/orchestrator-ps.txt"
  $ : > "$ORCHESTRATOR_PS"
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

An orchestrator that answers its health endpoint is reported as serving, naming
the image that is actually up.

  $ bondi-client setup
  Setting up the servers...
  Processing server: 10.0.0.1
  Docker is already installed on server 10.0.0.1: Docker version 27.0.0, build deadbeef
  Network bondi-network is present on server 10.0.0.1
  ACME file permissions updated on server 10.0.0.1: /etc/traefik/acme/acme.json
  bondi-orchestrator is serving on server 10.0.0.1: mlopez1506/bondi-server:0.10.1

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

  $ : > ssh-argv.log
  $ ORCHESTRATOR_DIES=1 bondi-client setup
  Setting up the servers...
  Processing server: 10.0.0.1
  Docker is already installed on server 10.0.0.1: Docker version 27.0.0, build deadbeef
  Network bondi-network is present on server 10.0.0.1
  ACME file permissions updated on server 10.0.0.1: /etc/traefik/acme/acme.json
  Error: bondi-orchestrator did not come up on server 10.0.0.1.
  Image: mlopez1506/bondi-server:0.10.1
  the orchestrator container did not answer GET /api/v1/health. The readiness check answered: BONDI_ORCHESTRATOR_UNREACHABLE
  Container state and logs from the server:
  status=exited exit=127 oom=false error=
  --- last 50 log lines ---
  Error loading shared library libzstd.so.1: No such file or directory (needed by /usr/local/bin/bondi-server)
  The container was left in place so it can be inspected: run `docker logs bondi-orchestrator` on 10.0.0.1. To restore service, set bondi_server.version in bondi.yaml back to a version known to run on this host and run `bondi setup` again.
  setup stopped part-way through the orchestrator phase on server 10.0.0.1, which was the last one, so no phase was skipped.
  [1]

Nothing claimed success on that run.

  $ grep -c 'is serving' ssh-argv.log
  0
  [1]

A container left behind by a failed start is removed before the next attempt,
rather than colliding with the name and making `bondi setup` — the command an
operator reaches for to recover — fail too.

  $ printf 'exited\tmlopez1506/bondi-server:0.10.1\n' > "$ORCHESTRATOR_PS"
  $ : > ssh-argv.log
  $ bondi-client setup
  Setting up the servers...
  Processing server: 10.0.0.1
  bondi-orchestrator on server 10.0.0.1 exists but is not running, replacing it...
  Docker is already installed on server 10.0.0.1: Docker version 27.0.0, build deadbeef
  Network bondi-network is present on server 10.0.0.1
  ACME file permissions updated on server 10.0.0.1: /etc/traefik/acme/acme.json
  Removed bondi-orchestrator container on server 10.0.0.1
  bondi-orchestrator is serving on server 10.0.0.1: mlopez1506/bondi-server:0.10.1

The removal asserts the outcome rather than the exit status of `docker rm`: an
orchestrator started by an older Bondi ran with --rm, so `docker stop` has
already deleted it and `docker rm` reports "no such container" on a host that is
in exactly the state wanted.

  $ grep -c 'could not be removed' ssh-argv.log
  1
