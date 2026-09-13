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
  >   # The ACME file the orchestrator phase needs in place before it runs.
  >   # Without this arm the command falls through to *) and answers nothing,
  >   # which setup reads as a host that could not be asked, and the run stops
  >   # in the ACME phase -- before the convergence this file now asserts.
  >   *BONDI_ACME_PRESENT*) echo BONDI_ACME_PRESENT ;;
  >   *'PortBindings'*) echo '127.0.0.1' ;;
  >   # The restart-policy reading the run takes after it has started the
  >   # container. This box reports the policy setup asked for, so the reading
  >   # is the whole of the convergence: nothing is corrected, and the count
  >   # below is the inspect alone.
  >   *'RestartPolicy'*) echo 'unless-stopped' ;;
  >   # The orchestrator's image on its own, which is the version the report's
  >   # orchestrator read holds this box to before running a subcommand inside
  >   # its container. Without this arm the command falls through to *) and
  >   # answers nothing, which reads as a box whose version could not be read --
  >   # the same unavailable source for a reason no fixture chose. The pattern
  >   # ends the command rather than merely containing it: the probe's own
  >   # listing asks for {{.State}} and {{.Image}} together, and an arm that
  >   # matched both would answer the probe with a version.
  >   *'name=^/bondi-orchestrator$'*"--format '{{.Image}}'") echo 'mlopez1506/bondi-server:0.15.0' ;;
  >   # The three readings setup takes off the box once it has started the
  >   # container: the wait for a running state, the server's own check inside
  >   # it, and a read of the container's log stream for the line the check
  >   # writes to its diagnostic sink. The check writes a document and the log
  >   # read carries the marker because an answer that says nothing is a
  >   # rejection rather than a pass, so a command falling through to the
  >   # catch-all below would fail this run for a reason no fixture here chose.
  >   'attempt=0; while'*) : ;;
  >   *'bondi-server check'*) echo '{"ready":true,"observations":[]}' ;;
  >   'docker logs --tail'*) echo 'bondi check: diagnostic sink is writable' ;;
  >   # The closing report's own reading, which is a different question from the
  >   # one setup takes and is answered here so that a fall-through to *) cannot
  >   # stand in for it. This box clears the floor, so the report does ask; what
  >   # it is told is a refusal, and every report line this file prints is
  >   # normalised, so the wording is not the subject.
  >   *'bondi-server status'*) echo 'this fixture does not answer the report' >&2; exit 1 ;;
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
  >   version: "0.15.0"
  > EOF

The run reports the absence and installs, rather than refusing a reading the
host did give it. The status is asserted rather than piped away: this stub
answers every reading the run takes, so the run converges, and a run that had
stopped part-way would still print the four lines below.

  $ bondi-client setup > out.log 2>&1
  $ head -4 out.log
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

The restart-policy inspect reaches the host. A host that had no Docker holds
only the container this run just created, and the `--restart` that created it
is a request rather than a reading -- so this is the one run whose policy has
never been inspected, and it used to be the one run that never asked. The
count is one because this box reports the policy setup asked for: the reading
happens, and nothing follows it.

  $ grep -c 'RestartPolicy' ssh-argv.log
  1
