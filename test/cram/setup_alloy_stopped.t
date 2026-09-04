A `bondi-alloy` container that exists but is stopped still holds its name, so
`docker run` against it fails with a conflict and the whole setup stops there —
including every phase after alloy. The listing used to omit `-a`, which made a
stopped container invisible and indistinguishable from no container at all, and
the only way out was a manual `docker rm bondi-alloy` on the host.

  $ ROOT="$PWD"

The stub reports a stopped alloy container and an orchestrator already serving
the declared version, so the run reduces to the alloy phase.

  $ mkdir -p "$ROOT/bin"
  $ cat > "$ROOT/bin/ssh" <<'STUB'
  > #!/bin/sh
  > while [ $# -gt 0 ] && [ "$1" != "--" ]; do shift; done
  > shift
  > printf '%s\n' "$1" >> "$SSH_ARGV_LOG"
  > cat >> "$SSH_STDIN_LOG"
  > case "$1" in
  >   *BONDI_ACME_PRESENT*) echo BONDI_ACME_PRESENT ;;
  >   'docker --version') echo 'Docker version 27.0.0, build deadbeef' ;;
  >   *'name=^/bondi-orchestrator$'*'{{.State}}'*)
  >     printf 'running\tmlopez1506/bondi-server:0.10.1\n' ;;
  >   *'ps -a --filter name=^/bondi-alloy$'*'{{.State}}'*)
  >     printf 'exited\tgrafana/alloy:v1.8.0\n' ;;
  >   # The mode the host reports for the config file after it was written,
  >   # answered from $ALLOY_MODE so that a box agreeing with the declaration
  >   # and a box disagreeing with it are the same fixture with one variable
  >   # changed. Without this arm the probe falls through to *) and answers
  >   # nothing, which setup reads as a refusal to report rather than as
  >   # agreement -- so every arm below would pass for the wrong reason.
  >   *'sudo stat -c %04a'*) echo "${ALLOY_MODE-0640}" ;;
  >   # The credentials write. Its output is deliberately not consulted by the
  >   # client -- unlike the mode probe above -- so this arm answers nothing on
  >   # purpose, and says so rather than leaving the command to reach *) where a
  >   # reader cannot tell a considered silence from an unhandled command.
  >   #
  >   # It matches the write and only the write. The run command below names the
  >   # same file through --env-file, so an arm matching the path alone would
  >   # swallow it -- case takes the first match -- and the container id would
  >   # come back empty from an arm that reads as deliberate.
  >   *'cat > '*'/etc/bondi/alloy/env'*) : ;;
  >   *'--name bondi-alloy'*) echo 'd671990dc2318f4b' ;;
  >   *'/var/spool/cron/crontabs/root'*) echo BONDI_CRONTAB_ABSENT ;;
  >   *'PortBindings'*) echo '127.0.0.1' ;;
  >   # The host's applied restart policy. Without this arm the command falls
  >   # through to *) and answers nothing, which setup reads as a refusal to
  >   # report rather than as agreement.
  >   *'RestartPolicy'*) echo unless-stopped ;;
  >   *) : ;;
  > esac
  > STUB
  $ chmod +x "$ROOT/bin/ssh"
  $ export PATH="$ROOT/bin:$PATH"

  $ export SSH_ARGV_LOG="$PWD/ssh-argv.log"
  $ : > "$SSH_ARGV_LOG"

Everything the client sends a remote command on standard input is captured too,
so a payload that is kept out of `argv` can still be shown to have reached the
host rather than merely to have gone missing.

  $ export SSH_STDIN_LOG="$PWD/ssh-stdin.log"
  $ : > "$SSH_STDIN_LOG"
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
  > alloy:
  >   grafana_cloud:
  >     instance_id: "123456"
  >     api_key: "glc_secret"
  >     endpoint: "https://logs-prod.grafana.net/loki/api/v1/push"
  > EOF

The stopped container is removed before the new one is run, and the setup
completes rather than stopping on a name conflict. The run's own lines are what
this case is about, so they are taken here without the report that follows them.

The output is captured to a file and sliced afterwards rather than piped into
`head`. Through a pipe the status cram checks is `head`'s, so the run could exit
non-zero -- or be killed by the SIGPIPE `head` raises when it has its ten lines
-- and the case would still read as a pass. Slicing a file that a completed run
wrote leaves the status this line asserts belonging to `bondi-client`.

  $ bondi-client setup > out.log 2>&1
  $ head -11 out.log
  Setting up the servers...
  Processing server: 127.0.0.1
  bondi-orchestrator container is already running on server 127.0.0.1: 0.10.1, skipping...
  Docker is already installed on server 127.0.0.1: Docker version 27.0.0, build deadbeef
  Network bondi-network is present on server 127.0.0.1
  ACME file permissions updated on server 127.0.0.1: /etc/traefik/acme/acme.json
  Stopped bondi-alloy container on server 127.0.0.1
  Removed bondi-alloy container and config on server 127.0.0.1
  Alloy config written on server 127.0.0.1: /etc/bondi/alloy/config.alloy
  Wrote Alloy credentials file on server 127.0.0.1: /etc/bondi/alloy/env
  bondi-alloy container started on server 127.0.0.1: d671990dc2318f4b

The removal is what the incident needed a human for.

  $ grep -c -F -- 'docker rm bondi-alloy' ssh-argv.log
  1

The container's name was not the only thing left behind. The credentials file
has no removal action of its own -- it is carried off because it sits inside the
directory this command deletes, so the directory named here has to be the same
one the writes below create their files in. Spelled out rather than derived: a
removal aimed at a directory nothing writes to leaves a withdrawn credential on
the host and fails no assertion of its own.

  $ grep -c -F -- "sudo rm -rf '/etc/bondi/alloy'" ssh-argv.log
  1

Its affirmative arm is the listing itself: without `-a` a stopped container is
not reported, so the state the removal answers to would never be read.

  $ grep -c -F -- 'ps -a --filter name=^/bondi-alloy$' ssh-argv.log
  1

The run command that reaches the host declares a restart policy. Without it the
sidecar is gone after a host reboot or a docker-ce upgrade and logs stop
shipping silently, with nothing on the box saying so. The policy is spelled out
rather than built from the shared constant on purpose: through the constant this
would pass for whatever value the constant takes, including `always`.

  $ grep -c -F -- 'docker run -d --name bondi-alloy --restart unless-stopped' ssh-argv.log
  1

The config file's mode is Bondi's own rather than whatever the remote shell's
umask happened to be. The write reaching the host carries the mode explicitly,
and the value is spelled out rather than read from the constant that produced
it: through the constant this would pass for whatever value the constant takes,
including the `0600` that would undo the narrowing already applied to these
boxes out of band.

  $ grep -c -E -- "chmod 0640 .*config[.]alloy" ssh-argv.log
  1

The Grafana Cloud credentials are written to their own file at mode 0600, and
they get there on standard input. `docker --env-file` has no escaping syntax, so
the file is written fresh rather than truncated: a redirect onto a file that
already exists creates nothing and therefore consults no umask, which is how a
credential file could keep a mode somebody else chose for it.

  $ grep -c -E -- "chmod 0600 .*/etc/bondi/alloy/env" ssh-argv.log
  1

Both writes chain their steps with `&&`. `sh -c` exits with the status of the
last command it ran, so under `;` the status of a write is the trailing chmod's
-- and chmod succeeds on a file `cat` created and then failed to fill. A
connection dropped mid-transfer would report success and pass the mode read-back
below, because the mode really was applied.

  $ grep -c -E -- "cat > [^&]*/etc/bondi/alloy/env[^&]* && chmod 0600 " ssh-argv.log
  1
  $ grep -c -E -- "cat > [^&]*/etc/bondi/alloy/config[.]alloy[^&]* && chmod 0640 " ssh-argv.log
  1

The negative half of that pair, over both writes at once: no step of either is
separated by a `;`, so no step's failure can be discarded by the one after it.

  $ grep -E -- "cat > [^&]*/etc/bondi/alloy/" ssh-argv.log | grep -c -F -- ';'
  0
  [1]

The command that writes it carries no credential of its own -- the values arrive
on the pipe. The affirmative pair for that absence is the arm above, which proves
the write really did reach `argv` for this run, and the arm below, which proves
the values really did reach the host by the intended route. Without both, the
absence would pass just as well against a run that stopped writing the file.

  $ grep -E -- "cat > .*/etc/bondi/alloy/env" ssh-argv.log | grep -c -F -- glc_secret
  0
  [1]
The match is whole-line rather than a substring. `env_file_contents` emits one
undelimited `KEY=VALUE` per line, so an unanchored `...INSTANCE_ID=123456` also
matches `...INSTANCE_ID=1234567` and an unanchored `...API_KEY=glc_secret` also
matches `...API_KEY=glc_secret_and_then_some` -- which is exactly the trailing
corruption a truncated or extended write produces, and the thing these two arms
exist to see.

  $ grep -c -x -F -- 'GRAFANA_CLOUD_API_KEY=glc_secret' ssh-stdin.log
  1
  $ grep -c -x -F -- 'GRAFANA_CLOUD_INSTANCE_ID=123456' ssh-stdin.log
  1

The generated River config travels on the same pipe and names both variables,
but it carries neither value: the config reads them through `sys.env`, so the
only thing on the host that holds the key is the file written above.

  $ grep -c -F -- 'sys.env("GRAFANA_CLOUD_API_KEY")' ssh-stdin.log
  1

The run command that starts the sidecar carries no credential either. The key
appears nowhere in any command line this run sent — not in the write, not in the
run — and the same run proves it reached the host anyway, by the file above.
Without that pair the absence would pass against a run that never got as far as
starting Alloy, and against an empty log.

  $ grep -c -F -- glc_secret ssh-argv.log
  0
  [1]
  $ grep -c -F -- GRAFANA_CLOUD_INSTANCE_ID ssh-argv.log
  0
  [1]

The affirmative arm for both absences: the run command names the file the
credentials were written to, so the container still gets them. The path is
spelled out rather than derived, because a run command pointing at a path nothing
wrote starts a sidecar that ships nothing and fails no assertion of its own.

  $ grep -c -F -- '--env-file /etc/bondi/alloy/env' ssh-argv.log
  1

Asking is not applying, so the mode is read back off the host. The run above had
the host report the declared mode: it completed, and it said nothing about the
mode, because there was nothing to correct.

  $ grep -c -F -- 'Alloy config written on server 127.0.0.1: /etc/bondi/alloy/config.alloy' out.log
  1
  $ grep -c 'is mode' out.log
  0
  [1]

The affirmative half of that pair: the same stub and the same bondi.yaml,
differing only in what the host reports the mode to be. Now the read-back
disagrees, the run fails on it, and the message names both what was asked for
and what the host said -- and quotes none of the file it is talking about.

  $ ALLOY_MODE=0644 bondi-client setup > out.log 2>&1
  [1]
  $ grep 'is mode' out.log
  Error: /etc/bondi/alloy/config.alloy on server 127.0.0.1 is mode 0644 after being written at 0640 -- refusing to report success on a posture that was not applied

The other half of the read-back's negative space: a host that answers nothing.
A `stat` the host refused, an output that never arrived and a stub with no arm
for the command all look like this, and none of them is a mode. The run fails
rather than reporting one it never read, and the file it is talking about is
named once -- the verdict carries what happened and the message does the wording,
so there is one place the path can come from.

  $ ALLOY_MODE= bondi-client setup > out.log 2>&1
  [1]
  $ grep 'could not read back' out.log
  Error: could not read back the mode of /etc/bondi/alloy/config.alloy on server 127.0.0.1 after writing it at 0640, so whether the mode was applied is unknown: the host reported nothing
  $ grep -o -F -- '/etc/bondi/alloy/config.alloy' out.log | wc -l
  1

The other kind of unreadable, on the same fixture: the host answered, and what
it answered was the probe's own marker rather than a mode. That is a file `stat`
refused, not a host that said nothing, and the message says which -- the verdict
carries the two apart as data and the wording is built here, in one place, from
one path.

  $ ALLOY_MODE=BONDI_ALLOY_MODE_UNREADABLE bondi-client setup > out.log 2>&1
  [1]
  $ grep 'could not read back' out.log
  Error: could not read back the mode of /etc/bondi/alloy/config.alloy on server 127.0.0.1 after writing it at 0640, so whether the mode was applied is unknown: the host could not read it and answered BONDI_ALLOY_MODE_UNREADABLE
  $ grep -o -F -- '/etc/bondi/alloy/config.alloy' out.log | wc -l
  1
