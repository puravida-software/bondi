A key that needs a passphrase cannot be handed to ssh as a file: ssh offers its
public half, the host accepts it, and the signature never comes -- which the
host reports as an authorization failure for a fault that is entirely local.
Bondi raises an agent of its own instead, loads the key into it, and tears the
agent down again. The decrypted key exists only inside that process; nothing
decrypted is written anywhere.

The client reaches the agent through the session it opens -- the last section of
this file is a deploy doing exactly that -- but nothing it does puts a caller
where the agent's own lifetime can be observed, so the scenarios below it drive
the module through a private probe built beside this file. The probe prints one
line per outcome and never prints a passphrase.

  $ ROOT="$PWD"
  $ PROBE="$PWD/ssh_agent_probe.exe"
  $ mkdir -p "$ROOT/bin"

The ssh-agent stub reports the socket it was told to bind, in the shape the real
one reports it, and records every teardown. It uses shell builtins only, so a
scenario may hand it a PATH with nothing else on it. An invocation nothing
stubs exits non-zero and says so: a stub whose catch-all returns quietly makes
a missing arm read as a failing command, which is how a file passes for the
wrong reason.

  $ cat > "$ROOT/bin/ssh-agent" <<'STUB'
  > #!/bin/sh
  > case "$1" in
  >   -a)
  >     printf '%s\n' "$2" > "$AGENT_SOCKET_FILE"
  >     : > "$2"
  >     echo "SSH_AUTH_SOCK=$2; export SSH_AUTH_SOCK;"
  >     echo "SSH_AGENT_PID=4242; export SSH_AGENT_PID;"
  >     echo "echo Agent pid 4242;"
  >     ;;
  >   -k)
  >     printf 'killed pid %s at socket %s\n' "$SSH_AGENT_PID" "${SSH_AUTH_SOCK##*/}" >> "$AGENT_LOG"
  >     ;;
  >   *)
  >     echo "ssh-agent stub: nothing stubs: $*" >&2
  >     exit 3
  >     ;;
  > esac
  > STUB
  $ chmod +x "$ROOT/bin/ssh-agent"

The ssh-add stub records its own argv, then asks the askpass helper for the
passphrase exactly as the real ssh-add does, and answers on whether what the
helper handed over is the secret this run configured. That is what makes the
argv assertion below a statement about where the passphrase travelled rather
than about a passphrase that never travelled at all. It asks a second time, so
the helper's one-shot property is observed rather than asserted: a helper that
kept answering would make the real ssh-add retry a wrong passphrase until it
gave up, and the call would not return.

Listing what the agent holds is a second, separate invocation, and the stub
answers it before any of that: no passphrase is asked for, because none is in
that call's environment. What it prints stands in for the public half the real
program would report, which is what the client writes beside the staged key so
that ssh has a public key for an identity whose file keeps one inside the
encryption.

  $ cat > "$ROOT/bin/ssh-add" <<'STUB'
  > #!/bin/sh
  > printf '%s\n' "$*" >> "$SSH_ADD_ARGV_LOG"
  > if [ "$1" = -L ]; then
  >   echo 'ssh-ed25519 AAAAstub the identity this agent holds'
  >   exit 0
  > fi
  > if [ -e "$SSH_AUTH_SOCK" ]; then
  >   echo 'the agent socket was pointed at' >> "$SSH_ADD_ENV_LOG"
  > else
  >   echo 'no agent socket was pointed at' >> "$SSH_ADD_ENV_LOG"
  > fi
  > answer=$("$SSH_ASKPASS" 'Enter passphrase:')
  > "$SSH_ASKPASS" 'Enter passphrase:' > /dev/null 2>&1
  > printf 'the helper answered a second time with status %s\n' "$?" >> "$SSH_ADD_ENV_LOG"
  > if [ "$answer" = "$EXPECTED_PASSPHRASE" ]; then
  >   echo 'the helper handed over the expected passphrase' >> "$SSH_ADD_ENV_LOG"
  >   echo 'Identity added'
  >   exit 0
  > fi
  > echo 'the helper handed over something else' >> "$SSH_ADD_ENV_LOG"
  > echo 'Bad passphrase, try again' >&2
  > exit 1
  > STUB
  $ chmod +x "$ROOT/bin/ssh-add"
  $ export PATH="$ROOT/bin:$PATH"
  $ export AGENT_LOG="$ROOT/agent.log"
  $ export AGENT_SOCKET_FILE="$ROOT/agent-socket.path"
  $ export SSH_ADD_ARGV_LOG="$ROOT/ssh-add-argv.log"
  $ export SSH_ADD_ENV_LOG="$ROOT/ssh-add-env.log"
  $ export EXPECTED_PASSPHRASE=fixture-passphrase
  $ export BONDI_PROBE_TIMEOUT_SECONDS=120

The key is a file the stubs never read. What is staged and how long it lives is
the caller's, not the agent's -- the agent is handed a path that is already
there, because a second write-then-delete is a second place a copy can be left
behind.

  $ printf 'a staged key the stubs never read\n' > "$ROOT/key"

One reset, so every scenario below starts from the same state and the file is
the same whether it runs once or ten times.

  $ reset_logs() {
  >   : > "$AGENT_LOG"
  >   : > "$SSH_ADD_ARGV_LOG"
  >   : > "$SSH_ADD_ENV_LOG"
  >   rm -f "$AGENT_SOCKET_FILE"
  > }

A passphrase reaches ssh-add through the environment and not the command line.

  $ reset_logs
  $ BONDI_PROBE_PASSPHRASE=fixture-passphrase "$PROBE" "$ROOT/key" report
  ok, socket named s in a directory at mode 0700

The command line carries the key and a lifetime, and nothing else, and then the
listing that asks the agent what it now holds. The lifetime is the bound the
session was opened at and a margin, not a number of its own: a constant here
asserts that it outlives every command this client issues, and that assertion is
refuted by the caller that asks for longer than it.

  $ cat "$SSH_ADD_ARGV_LOG"
  -t 180 $TESTCASE_ROOT/key
  -L
  $ grep -c fixture-passphrase "$SSH_ADD_ARGV_LOG"
  0
  [1]

And the passphrase did travel, down the helper's channel, to a program that was
pointed at the agent this run raised. Without this the zero above would be true
of an implementation that never passed a passphrase at all. The second call
answering non-zero is the helper refusing to serve twice.

  $ cat "$SSH_ADD_ENV_LOG"
  the agent socket was pointed at
  the helper answered a second time with status 1
  the helper handed over the expected passphrase

The agent is torn down and its private directory goes with it.

  $ cat "$AGENT_LOG"
  killed pid 4242 at socket s
  $ SOCKET=$(cat "$AGENT_SOCKET_FILE")
  $ test -e "$SOCKET" || echo 'the socket is gone'
  the socket is gone
  $ test -d "${SOCKET%/*}" || echo 'the private directory is gone'
  the private directory is gone

A session opened at a different bound loads an identity that lives a different
length of time. Two bounds rather than one, because a single number is equally
true of an implementation that ignored the bound and happened to agree with it.

  $ reset_logs
  $ BONDI_PROBE_TIMEOUT_SECONDS=1800 BONDI_PROBE_PASSPHRASE=fixture-passphrase "$PROBE" "$ROOT/key" report
  ok, socket named s in a directory at mode 0700
  $ cut -d' ' -f1,2 "$SSH_ADD_ARGV_LOG"
  -t 1860
  -L

A rejected passphrase is reported as a rejected passphrase, and the call
returns. It returning at all is half the assertion: a helper that answered
every prompt would have ssh-add retrying, and this line would hang rather than
fail.

  $ reset_logs
  $ BONDI_PROBE_PASSPHRASE=not-the-passphrase "$PROBE" "$ROOT/key" report
  passphrase rejected: Bad passphrase, try again
  $ cat "$SSH_ADD_ENV_LOG"
  the agent socket was pointed at
  the helper answered a second time with status 1
  the helper handed over something else

The failure does not leak the agent either.

  $ cat "$AGENT_LOG"
  killed pid 4242 at socket s

A missing ssh-add is settled before any spawn. A local shell that cannot find a
command exits 127, which is what a host reports a missing Docker with, and
setup reads that as authorisation to install Docker -- so the absence is
answered here rather than discovered after the fact.

  $ rm -rf "$ROOT/bin-without-ssh-add" && mkdir "$ROOT/bin-without-ssh-add"
  $ cp "$ROOT/bin/ssh-agent" "$ROOT/bin-without-ssh-add/ssh-agent"
  $ reset_logs
  $ PATH="$ROOT/bin-without-ssh-add" BONDI_PROBE_PASSPHRASE=fixture-passphrase "$PROBE" "$ROOT/key" report
  not available: ssh-add
  $ wc -l < "$AGENT_LOG"
  0
  $ test -e "$AGENT_SOCKET_FILE" || echo 'no agent was spawned'
  no agent was spawned

A missing ssh-agent is settled the same way and before the loader is looked for
at all, because the agent is what would be spawned first. An operator with
neither is told about the agent, which is the one that has to exist for any of
this to be possible.

  $ rm -rf "$ROOT/bin-without-ssh-agent" && mkdir "$ROOT/bin-without-ssh-agent"
  $ cp "$ROOT/bin/ssh-add" "$ROOT/bin-without-ssh-agent/ssh-add"
  $ reset_logs
  $ PATH="$ROOT/bin-without-ssh-agent" BONDI_PROBE_PASSPHRASE=fixture-passphrase "$PROBE" "$ROOT/key" report
  not available: ssh-agent
  $ wc -l < "$SSH_ADD_ARGV_LOG"
  0
  $ test -e "$AGENT_SOCKET_FILE" || echo 'no agent was spawned'
  no agent was spawned

The same narrow PATH with both programs on it does spawn one, so the absence
above is the missing binary and not the narrowing.

  $ reset_logs
  $ PATH="$ROOT/bin" BONDI_PROBE_PASSPHRASE=fixture-passphrase "$PROBE" "$ROOT/key" report
  ok, socket named s in a directory at mode 0700
  $ test -e "$AGENT_SOCKET_FILE" && echo 'an agent was spawned'
  an agent was spawned

An ssh-agent that is on PATH and fails is this machine's own work failing, and
is reported in the agent's own words rather than as anything a host said. The
two are what this whole feature exists to stop confusing for each other, so the
arm has a scenario rather than only a printer. The stubs below are
single-purpose: each one is the failure it is named for and nothing else.

  $ rm -rf "$ROOT/bin-agent-that-fails" && mkdir "$ROOT/bin-agent-that-fails"
  $ cp "$ROOT/bin/ssh-add" "$ROOT/bin-agent-that-fails/ssh-add"
  $ cat > "$ROOT/bin-agent-that-fails/ssh-agent" <<'STUB'
  > #!/bin/sh
  > echo 'no descriptors left' >&2
  > exit 2
  > STUB
  $ chmod +x "$ROOT/bin-agent-that-fails/ssh-agent"
  $ reset_logs
  $ PATH="$ROOT/bin-agent-that-fails" BONDI_PROBE_PASSPHRASE=fixture-passphrase "$PROBE" "$ROOT/key" report
  spawn failed: ssh-agent exited 2: no descriptors left

Nothing was loaded and nothing was left to tear down.

  $ wc -l < "$SSH_ADD_ARGV_LOG"
  0
  $ wc -l < "$AGENT_LOG"
  0

An ssh-agent that starts and announces no pid is the same fault by another
route. Without the pid there is nothing to hand its own -k, so an agent that
had been kept would be one nothing could kill -- which is worse than not having
raised it. The stub prints the socket assignment and withholds only the pid, so
what is refused is the missing pid and not silence.

  $ rm -rf "$ROOT/bin-agent-without-a-pid" && mkdir "$ROOT/bin-agent-without-a-pid"
  $ cp "$ROOT/bin/ssh-add" "$ROOT/bin-agent-without-a-pid/ssh-add"
  $ cat > "$ROOT/bin-agent-without-a-pid/ssh-agent" <<'STUB'
  > #!/bin/sh
  > echo 'SSH_AUTH_SOCK=/dev/null; export SSH_AUTH_SOCK;'
  > STUB
  $ chmod +x "$ROOT/bin-agent-without-a-pid/ssh-agent"
  $ reset_logs
  $ PATH="$ROOT/bin-agent-without-a-pid" BONDI_PROBE_PASSPHRASE=fixture-passphrase "$PROBE" "$ROOT/key" report
  spawn failed: ssh-agent started and reported no pid: SSH_AUTH_SOCK=/dev/null; export SSH_AUTH_SOCK;
  $ wc -l < "$SSH_ADD_ARGV_LOG"
  0
  $ wc -l < "$AGENT_LOG"
  0

The agent is torn down when the body raises, and the body's exception is the
caller's still -- it is re-raised after the teardown rather than turned into a
value the caller would have to tell apart from its own failures.

  $ reset_logs
  $ BONDI_PROBE_PASSPHRASE=fixture-passphrase "$PROBE" "$ROOT/key" raise
  the body's exception reached the caller
  $ cat "$AGENT_LOG"
  killed pid 4242 at socket s
  $ SOCKET=$(cat "$AGENT_SOCKET_FILE")
  $ test -d "${SOCKET%/*}" || echo 'the private directory is gone'
  the private directory is gone

And a deploy goes over that agent. Everything above drives the module directly;
this is the client doing it, and it is the only thing that shows the socket the
agent opened reaching the process that has to sign with it. That the deploy
reaches the box is the whole assertion -- what the box then says about the
orchestrator is another file's subject.

The ssh stub records its own command line and what it was spawned with, then
answers the two remote commands a deploy issues. Shell builtins only, like the
two above, and an invocation nothing stubs exits non-zero and says so.

  $ cat > "$ROOT/bin/ssh" <<'STUB'
  > #!/bin/sh
  > printf '%s\n' "$*" >> "$SSH_ARGV_LOG"
  > if [ -n "$SSH_AUTH_SOCK" ] && [ -e "$SSH_AUTH_SOCK" ]; then
  >   printf 'pointed at an agent socket named %s\n' "${SSH_AUTH_SOCK##*/}" >> "$SSH_ENV_LOG"
  > else
  >   printf 'no agent socket was in the environment\n' >> "$SSH_ENV_LOG"
  > fi
  > while [ $# -gt 0 ] && [ "$1" != "--" ]; do shift; done
  > shift
  > cat > /dev/null
  > case "$1" in
  >   'docker ps -a --filter name=^/bondi-orchestrator$'*)
  >     echo 'mlopez1506/bondi-server:0.20.0' ;;
  >   'docker exec -i bondi-orchestrator bondi-server deploy')
  >     echo 'Error: No such container: bondi-orchestrator' >&2
  >     exit 1 ;;
  >   *)
  >     echo "ssh stub: nothing stubs: $1" >&2
  >     exit 3 ;;
  > esac
  > STUB
  $ chmod +x "$ROOT/bin/ssh"
  $ export SSH_ARGV_LOG="$ROOT/ssh-argv.log"
  $ export SSH_ENV_LOG="$ROOT/ssh-env.log"

The manifest carries the same aes256-ctr OpenSSH key the refusal file uses,
base64-encoded, with the passphrase this run's ssh-add stub expects. It is
authorised nowhere.

  $ cat > bondi.yaml <<EOF
  > service:
  >   name: web
  >   image: registry.example.com/web
  >   port: 8080
  >   env_vars: {}
  >   servers:
  >     - ip_address: 10.0.0.1
  >       ssh:
  >         user: deploy
  >         private_key_contents: "LS0tLS1CRUdJTiBPUEVOU1NIIFBSSVZBVEUgS0VZLS0tLS0KYjNCbGJuTnphQzFyWlhrdGRqRUFBQUFBQ21GbGN6STFOaTFqZEhJQUFBQUdZbU55ZVhCMEFBQUFHQUFBQUJCNWFVamFYcApEUTFpR3cycUZNTVhMbUFBQUFHQUFBQUFFQUFBQXpBQUFBQzNOemFDMWxaREkxTlRFNUFBQUFJSUlpMWFBcFZBWWoxMjIvCm5DeXdxN2lNcWoyMk9Wd1d5NEdUK2pXOFFWTGRBQUFBa0NxbCtDN3IvRk9tQ1Vnc1JYRmJua216WW5XTXF2dDZYeG5yOCsKcFAzUEJOMmExWXRKeWRkdEwzMXl6dldrOXFzTFpqVHNmUnNBZmlDWEU0MjBDbVllSnNRNzRpMzhQQ1NCWFE3U0FJOHUyZQpvenNneHJCYUMwU1lJenppbUN4YVdZNVBTeWVEenFITkMwMFRSQUw2UkdMVWk1Wmg0UWdkM1ZzalpiV09hWTJ1NDBmL3ZqCm1UcDVTOURKb1d5ZjE5SUE9PQotLS0tLUVORCBPUEVOU1NIIFBSSVZBVEUgS0VZLS0tLS0K"
  >         private_key_pass: "fixture-passphrase"
  > bondi_server:
  >   version: "0.20.0"
  > EOF
  $ reset_logs
  $ : > "$SSH_ARGV_LOG"
  $ : > "$SSH_ENV_LOG"
  $ bondi-client deploy web:v1 > deploy.log 2>&1
  [1]

It failed for the box's reason and not for a credential one. That is the whole
point of the two arms this adds: had the agent not been raised, or the key not
been loaded into it, the run would have stopped here with a fault of this
machine's rather than reaching the orchestrator at all.

  $ grep -c 'No such container: bondi-orchestrator' deploy.log
  1
  $ grep -c 'did not unlock' deploy.log
  0
  [1]
  $ grep -c 'was not found on this machine' deploy.log
  0
  [1]

The client reached the box, and every call it made was spawned pointing at the
agent this run raised rather than at whatever the operator's own shell had set.

  $ sort -u "$SSH_ENV_LOG"
  pointed at an agent socket named s

Each of those calls named the staged key too, because the file still carries the
public half ssh offers; what changed is that the agent is what signs for it.

  $ grep -c -- '-i /' "$SSH_ARGV_LOG"
  2

The passphrase reached no command line -- not ssh's, and not the loader's.

  $ grep -c fixture-passphrase "$SSH_ARGV_LOG"
  0
  [1]
  $ grep -c fixture-passphrase "$SSH_ADD_ARGV_LOG"
  0
  [1]

And it did travel, down the helper's channel, which is what stops the two zeros
above from being equally true of a run that carried no passphrase at all.

It travelled twice, because a deploy opens two sessions: one to read what the
box is running, one to send the deploy. That was already two stagings of the
key before an agent existed, and it is now two agents as well. Pinned at two
rather than rounded to "at least one", so that a change to how many sessions a
deploy opens is a change this file reports.

  $ grep -c 'the helper handed over the expected passphrase' "$SSH_ADD_ENV_LOG"
  2

And each identity was given the life of the session it was loaded for rather
than one number for both. A deploy reads the box under a short bound and sends
the deploy under a long one, and the two lifetimes below are those two bounds
and a margin -- which is what makes "longer than the command" a property of the
code rather than a claim about it.

  $ cut -d' ' -f1,2 "$SSH_ADD_ARGV_LOG" | sort
  -L
  -L
  -t 120
  -t 1860

Neither agent outlives the session it was raised for.

  $ cat "$AGENT_LOG"
  killed pid 4242 at socket s
  killed pid 4242 at socket s
  $ SOCKET=$(cat "$AGENT_SOCKET_FILE")
  $ test -d "${SOCKET%/*}" || echo 'the private directory is gone'
  the private directory is gone
