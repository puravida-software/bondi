`bondi setup` finds the orchestrator by listing containers over SSH. A listing
that never ran used to be read as "there is no orchestrator on this host", which
plans a `docker run` under a name the host may already be holding — and the
transport error the client saw was discarded, so the operator never learned why.

  $ ROOT="$PWD"

The stub answers the Docker version and drops the connection on the container
listing.

  $ mkdir -p "$ROOT/bin"
  $ cat > "$ROOT/bin/ssh" <<'STUB'
  > #!/bin/sh
  > while [ $# -gt 0 ] && [ "$1" != "--" ]; do shift; done
  > shift
  > printf '%s\n' "$1" >> "$SSH_ARGV_LOG"
  > cat > /dev/null
  > case "$1" in
  >   'docker --version') echo 'Docker version 29.2.1, build deadbeef' ;;
  >   *'name=^/bondi-orchestrator$'*'{{.State}}'*)
  >     echo 'Connection closed by 10.0.0.1 port 22' >&2
  >     exit 255 ;;
  >   *) : ;;
  > esac
  > STUB
  $ chmod +x "$ROOT/bin/ssh"
  $ export PATH="$ROOT/bin:$PATH"

  $ export SSH_ARGV_LOG="$PWD/ssh-argv.log"
  $ : > "$SSH_ARGV_LOG"
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

The run stops and reports which listing failed and what it said.

  $ bondi-client setup 2>&1
  Setting up the servers...
  Processing server: 10.0.0.1
  Error: server 10.0.0.1: could not list the bondi-orchestrator container on the server, so setup will not act on whether it is running: command failed (255): Connection closed by 10.0.0.1 port 22
  [1]

No container was started under a name that was never checked. The affirmative
arm is the listing count: the probe did run, so the absence below is the refusal
to act on its failure rather than a run that stopped before reaching it.

  $ grep -c -F -- 'ps -a --filter name=^/bondi-orchestrator$' ssh-argv.log
  1

  $ grep -c -F -- '--name bondi-orchestrator' ssh-argv.log
  0
  [1]
