A host that genuinely has no Docker answers the version probe the only way a
shell can: a non-zero exit carrying "command not found". That is the host
speaking, not the transport failing, and it is the one reading that may install.
This is the affirmative arm of setup_docker_probe.t, which asserts that a
dropped connection installs nothing.

  $ ROOT="$PWD"

The stub answers every `docker --version` the way a Docker-less host does —
exit 127 with the shell's own message on stderr — and lets everything else
succeed, so the run reaches the install rather than stopping earlier.

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
  >     echo 'bash: docker: command not found' >&2
  >     exit 127 ;;
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

The run reports the absence and installs, rather than refusing a reading the
host did give it.

  $ bondi-client setup 2>&1 | head -4
  Setting up the servers...
  Processing server: 10.0.0.1
  Docker not found on server 10.0.0.1
  Installing Docker...

The installer was issued exactly once.

  $ grep -c 'get.docker.com' ssh-argv.log
  1

Both probes ran: the gather probe and the interpreter's own re-probe. Neither
was read as a transport failure.

  $ grep -c 'docker --version' ssh-argv.log
  2
