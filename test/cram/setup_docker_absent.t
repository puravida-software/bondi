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
  >   *'/var/spool/cron/crontabs/root'*) echo BONDI_CRONTAB_ABSENT ;;
  >   # The payload directory the crontab section is compared against. Without
  >   # this arm the command falls through to *) and answers nothing, which is a
  >   # listing that never happened rather than a directory that is empty -- and
  >   # the report says so, correctly, in a fixture that is about something else.
  >   *BONDI_CRON_PAYLOAD_LISTED*)
  >     echo BONDI_CRON_PAYLOAD_LISTED
  >     echo BONDI_CRON_PAYLOAD_END ;;
  >   *'PortBindings'*) echo '127.0.0.1' ;;
  >   # The orchestrator's image on its own, which is the version the report's
  >   # orchestrator read holds this box to before running a subcommand inside
  >   # its container. Without this arm the command falls through to *) and
  >   # answers nothing, which reads as a box whose version could not be read --
  >   # the same unavailable source for a reason no fixture chose. The pattern
  >   # ends the command rather than merely containing it: the probe's own
  >   # listing asks for {{.State}} and {{.Image}} together, and an arm that
  >   # matched both would answer the probe with a version.
  >   *'name=^/bondi-orchestrator$'*"--format '{{.Image}}'") echo 'mlopez1506/bondi-server:0.10.1' ;;
  >   # This box is below the floor, so its orchestrator is never asked. The arm
  >   # is here so that a change which stopped asking the version would show up
  >   # as this line rather than as a silent fall-through to *).
  >   *'bondi-server status'*) echo 'a box below the floor was asked anyway' >&2; exit 1 ;;
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
  >     - ip_address: 127.0.0.1
  >       port: 9
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
  Processing server: 127.0.0.1
  Docker not found on server 127.0.0.1
  Installing Docker...

The installer was issued exactly once.

  $ grep -c 'get.docker.com' ssh-argv.log
  1

Both probes ran: the gather probe and the interpreter's own re-probe. Neither
was read as a transport failure.

  $ grep -c 'docker --version' ssh-argv.log
  2

A host with no Docker holds no container that predates this run, so the
restart-policy convergence is skipped entirely rather than asked about. The two
counts above are taken from the same log and are non-zero, so this zero is the
inspect being absent rather than the log being empty.

  $ grep -c 'RestartPolicy' ssh-argv.log
  0
  [1]
