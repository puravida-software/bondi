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
  >   *'/var/spool/cron/crontabs/root'*) echo BONDI_CRONTAB_ABSENT ;;
  >   *'PortBindings'*) echo '127.0.0.1' ;;
  >   # The payload directory the crontab section is compared against. Without
  >   # this arm the command falls through to *) and answers nothing, which is a
  >   # listing that never happened rather than a directory that is empty -- and
  >   # the report says so, correctly, in a fixture that is about something else.
  >   *BONDI_CRON_PAYLOAD_LISTED*)
  >     echo BONDI_CRON_PAYLOAD_LISTED
  >     echo BONDI_CRON_PAYLOAD_END ;;
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

The run stops and reports which listing failed and what it said. A run refused
before it had a plan still reaches the report — the report's reads are its own
and are taken whether or not the plan ran.

  $ bondi-client setup > out.log 2>&1
  [1]
  $ sed 's/not reachable: .*/not reachable: <detail>/' out.log
  Setting up the servers...
  Processing server: 127.0.0.1
  Error: server 127.0.0.1: could not list the bondi-orchestrator container on the server, so setup will not act on whether it is running: the host was not reached (255): Connection closed by 10.0.0.1 port 22
  
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



No container was started under a name that was never checked. The affirmative
arm is the listing count: the probe did run, so the absence below is the refusal
to act on its failure rather than a run that stopped before reaching it. It is
the probe's own listing that is counted and not every command naming the
container: the report taken after the run reads the same container's image to
hold the box to the floor for the orchestrator's subcommands, which is a second
command against the same name and not this phase.

  $ grep -c -- 'ps -a --filter name=\^/bondi-orchestrator\$ --format .{{.State}}' ssh-argv.log
  1

  $ grep -c -F -- '--name bondi-orchestrator' ssh-argv.log
  0
  [1]
