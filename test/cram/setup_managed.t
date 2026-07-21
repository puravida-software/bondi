Setup converges managed containers: the secret environment file is written
without its contents ever reaching a command line, and the container is started
with that file passed by reference.

Capture the sandbox root ($TESTCASE_ROOT is substituted in expected output but
is not exported into the shell, so derive it from $PWD).

  $ ROOT="$PWD"

A stub ssh records the remote command it was asked to run and, separately,
anything piped to it. Keeping the two logs apart is what lets the test tell
what reaches argv from what reaches stdin.

  $ mkdir -p "$ROOT/bin"
  $ cat > "$ROOT/bin/ssh" <<'STUB'
  > #!/bin/sh
  > while [ $# -gt 0 ] && [ "$1" != "--" ]; do shift; done
  > shift
  > printf '%s\n' "$1" >> "$SSH_ARGV_LOG"
  > cat >> "$SSH_STDIN_LOG"
  > case "$1" in
  >   'docker --version') echo 'Docker version 27.0.0, build deadbeef' ;;
  >   *'label=bondi.type=managed'*)
  >     if [ -n "$MANAGED_PS_FAILS" ]; then exit 7; fi
  >     cat "$MANAGED_PS" ;;
  >   *) : ;;
  > esac
  > STUB
  $ chmod +x "$ROOT/bin/ssh"
  $ export PATH="$ROOT/bin:$PATH"

A declared managed container that the server does not have.

  $ cd "$ROOT" && rm -rf declared && mkdir declared && cd declared
  $ export SSH_ARGV_LOG="$PWD/ssh-argv.log"
  $ export SSH_STDIN_LOG="$PWD/ssh-stdin.log"
  $ export MANAGED_PS="$PWD/managed-ps.txt"
  $ : > "$MANAGED_PS"
  $ cat > bondi.yaml <<'EOF'
  > bondi_server:
  >   version: "0.1.0"
  > cron_jobs:
  >   - name: healthcheck
  >     image: example.com/healthcheck
  >     schedule: "*/5 * * * *"
  >     server:
  >       ip_address: 10.0.0.1
  >       ssh:
  >         user: deploy
  >         private_key_contents: "not-a-real-key"
  >         private_key_pass: ""
  > managed_containers:
  >   - name: gateway
  >     image: example.com/ib-gateway
  >     tag: "10.48.1e"
  >     restart: unless-stopped
  >     network: bondi-network
  >     ports:
  >       - "4002:4002"
  >     env_vars:
  >       TRADING_MODE: paper
  >     secret_env_vars:
  >       TWS_PASSWORD: hunter2
  > EOF
  $ bondi-client setup
  Setting up the servers...
  Processing server: 10.0.0.1
  Docker is already installed on server 10.0.0.1: Docker version 27.0.0, build deadbeef
  Network bondi-network is present on server 10.0.0.1
  bondi-orchestrator container started on server 10.0.0.1: 
  Wrote secret environment file on server 10.0.0.1: /etc/bondi/gateway/env
  bondi-gateway container started on server 10.0.0.1: 

The env file is created under a umask that makes it mode 600 at creation, in a
single root-owned command — never written readable and chmod'd afterwards.

  $ grep 'umask' ssh-argv.log
  sudo sh -c 'umask 077; mkdir -p '\''/etc/bondi/gateway'\''; cat > '\''/etc/bondi/gateway/env'\'''

The shared network is ensured before anything joins it, and idempotently: the
inspect is what makes re-running setup a no-op rather than an error.

  $ grep 'network' ssh-argv.log | head -1
  docker network inspect 'bondi-network' > /dev/null 2>&1 || docker network create 'bondi-network'

The secret value reaches stdin and only stdin. Plain env values are inline by
design, so the affirmative arm below proves this log is not simply empty.

  $ cat ssh-stdin.log
  TWS_PASSWORD=hunter2
  $ grep -c hunter2 ssh-argv.log
  0
  [1]
  $ grep -c TRADING_MODE=paper ssh-argv.log
  1

The container runs with the env file passed by reference, plain env inline, and
the Bondi label set. No Traefik routing label is emitted.

  $ grep 'docker .run.' ssh-argv.log | sed "s/bondi.spec-hash=[0-9a-f]*/bondi.spec-hash=HASH/"
  docker 'run' '-d' '--name' 'bondi-gateway' '--restart' 'unless-stopped' '--network' 'bondi-network' '-p' '4002:4002' '--env-file' '/etc/bondi/gateway/env' '-e' 'TRADING_MODE=paper' '--label' 'bondi.managed=true' '--label' 'bondi.type=managed' '--label' 'bondi.name=gateway' '--label' 'bondi.spec-hash=HASH' 'example.com/ib-gateway:10.48.1e'
  $ grep -c 'traefik\.' ssh-argv.log
  0
  [1]

A container withdrawn from configuration is stopped, removed, and its config
directory — which holds its secrets — deleted.

  $ cd "$ROOT" && rm -rf withdrawn && mkdir withdrawn && cd withdrawn
  $ export SSH_ARGV_LOG="$PWD/ssh-argv.log"
  $ export SSH_STDIN_LOG="$PWD/ssh-stdin.log"
  $ export MANAGED_PS="$PWD/managed-ps.txt"
  $ printf 'gateway\tstale-hash\n' > "$MANAGED_PS"
  $ cat > bondi.yaml <<'EOF'
  > bondi_server:
  >   version: "0.1.0"
  > cron_jobs:
  >   - name: healthcheck
  >     image: example.com/healthcheck
  >     schedule: "*/5 * * * *"
  >     server:
  >       ip_address: 10.0.0.1
  >       ssh:
  >         user: deploy
  >         private_key_contents: "not-a-real-key"
  >         private_key_pass: ""
  > EOF
  $ bondi-client setup
  Setting up the servers...
  Processing server: 10.0.0.1
  Docker is already installed on server 10.0.0.1: Docker version 27.0.0, build deadbeef
  Network bondi-network is present on server 10.0.0.1
  bondi-orchestrator container started on server 10.0.0.1: 
  Stopped bondi-gateway container on server 10.0.0.1
  Removed bondi-gateway container on server 10.0.0.1
  Removed config directory on server 10.0.0.1: /etc/bondi/gateway

  $ grep 'rm -rf' ssh-argv.log
  sudo rm -rf '/etc/bondi/gateway'

A managed-container lookup that fails is not the same as a server with no
managed containers. Setup stops and reports it rather than planning a run for a
container that may already exist.

  $ cd "$ROOT" && rm -rf unobserved && mkdir unobserved && cd unobserved
  $ export SSH_ARGV_LOG="$PWD/ssh-argv.log"
  $ export SSH_STDIN_LOG="$PWD/ssh-stdin.log"
  $ export MANAGED_PS="$PWD/managed-ps.txt"
  $ : > "$MANAGED_PS"
  $ export MANAGED_PS_FAILS=1
  $ cat > bondi.yaml <<'EOF'
  > bondi_server:
  >   version: "0.1.0"
  > cron_jobs:
  >   - name: healthcheck
  >     image: example.com/healthcheck
  >     schedule: "*/5 * * * *"
  >     server:
  >       ip_address: 10.0.0.1
  >       ssh:
  >         user: deploy
  >         private_key_contents: "not-a-real-key"
  >         private_key_pass: ""
  > managed_containers:
  >   - name: gateway
  >     image: example.com/ib-gateway
  >     tag: "10.48.1e"
  >     restart: unless-stopped
  > EOF
  $ bondi-client setup
  Setting up the servers...
  Processing server: 10.0.0.1
  Error: could not list managed containers on the server, so the declared ones cannot be converged: command failed (7): 
  [1]

Nothing was started, and no environment file was written.

  $ grep -c 'docker run' ssh-argv.log
  0
  [1]
  $ grep -c 'umask' ssh-argv.log
  0
  [1]

With the same failure but nothing declared, setup proceeds: there is nothing to
converge, so the lookup does not matter.

  $ cd "$ROOT" && rm -rf unobserved-undeclared && mkdir unobserved-undeclared && cd unobserved-undeclared
  $ export SSH_ARGV_LOG="$PWD/ssh-argv.log"
  $ export SSH_STDIN_LOG="$PWD/ssh-stdin.log"
  $ export MANAGED_PS="$PWD/managed-ps.txt"
  $ : > "$MANAGED_PS"
  $ cat > bondi.yaml <<'EOF'
  > bondi_server:
  >   version: "0.1.0"
  > cron_jobs:
  >   - name: healthcheck
  >     image: example.com/healthcheck
  >     schedule: "*/5 * * * *"
  >     server:
  >       ip_address: 10.0.0.1
  >       ssh:
  >         user: deploy
  >         private_key_contents: "not-a-real-key"
  >         private_key_pass: ""
  > EOF
  $ bondi-client setup
  Setting up the servers...
  Processing server: 10.0.0.1
  Docker is already installed on server 10.0.0.1: Docker version 27.0.0, build deadbeef
  Network bondi-network is present on server 10.0.0.1
  bondi-orchestrator container started on server 10.0.0.1: 
  $ unset MANAGED_PS_FAILS

A container that declares no secrets still has its environment file written, so
that withdrawing the last credential truncates the file rather than leaving the
old one on disk under a container that no longer references it.

  $ cd "$ROOT" && rm -rf no-secrets && mkdir no-secrets && cd no-secrets
  $ export SSH_ARGV_LOG="$PWD/ssh-argv.log"
  $ export SSH_STDIN_LOG="$PWD/ssh-stdin.log"
  $ export MANAGED_PS="$PWD/managed-ps.txt"
  $ : > "$MANAGED_PS"
  $ cat > bondi.yaml <<'EOF'
  > bondi_server:
  >   version: "0.1.0"
  > cron_jobs:
  >   - name: healthcheck
  >     image: example.com/healthcheck
  >     schedule: "*/5 * * * *"
  >     server:
  >       ip_address: 10.0.0.1
  >       ssh:
  >         user: deploy
  >         private_key_contents: "not-a-real-key"
  >         private_key_pass: ""
  > managed_containers:
  >   - name: gateway
  >     image: example.com/ib-gateway
  >     tag: "10.48.1e"
  >     restart: unless-stopped
  >     env_vars:
  >       TRADING_MODE: paper
  > EOF
  $ bondi-client setup
  Setting up the servers...
  Processing server: 10.0.0.1
  Docker is already installed on server 10.0.0.1: Docker version 27.0.0, build deadbeef
  Network bondi-network is present on server 10.0.0.1
  bondi-orchestrator container started on server 10.0.0.1: 
  Wrote secret environment file on server 10.0.0.1: /etc/bondi/gateway/env
  bondi-gateway container started on server 10.0.0.1: 

The write happens under the same umask, and nothing is piped to it.

  $ grep 'umask' ssh-argv.log
  sudo sh -c 'umask 077; mkdir -p '\''/etc/bondi/gateway'\''; cat > '\''/etc/bondi/gateway/env'\'''
  $ test -s ssh-stdin.log && echo "stdin was written" || echo "stdin is empty"
  stdin is empty

With no secrets there is no file to reference, so --env-file is not passed.

  $ grep -c 'env-file' ssh-argv.log
  0
  [1]

A declaration that has not changed converges to nothing at all: setup is safe to
re-run, which is the path every repeat run takes. The observed spec hash is
taken from the run above rather than hardcoded, so this scenario cannot drift
away from what the digest actually produces.

  $ cd "$ROOT" && rm -rf converged && mkdir converged && cd converged
  $ export SSH_ARGV_LOG="$PWD/ssh-argv.log"
  $ export SSH_STDIN_LOG="$PWD/ssh-stdin.log"
  $ export MANAGED_PS="$PWD/managed-ps.txt"
  $ cat > bondi.yaml <<'EOF'
  > bondi_server:
  >   version: "0.1.0"
  > cron_jobs:
  >   - name: healthcheck
  >     image: example.com/healthcheck
  >     schedule: "*/5 * * * *"
  >     server:
  >       ip_address: 10.0.0.1
  >       ssh:
  >         user: deploy
  >         private_key_contents: "not-a-real-key"
  >         private_key_pass: ""
  > managed_containers:
  >   - name: gateway
  >     image: example.com/ib-gateway
  >     tag: "10.48.1e"
  >     restart: unless-stopped
  >     env_vars:
  >       TRADING_MODE: paper
  > EOF

First run: the container is absent, so it is written and started.

  $ : > "$MANAGED_PS"
  $ bondi-client setup > first-run.log
  $ grep -c 'bondi-gateway container started' first-run.log
  1

Seed the observed state with the hash that run stamped on the container.

  $ HASH=$(grep -o "bondi.spec-hash=[0-9a-f]*" ssh-argv.log | head -1 | cut -d= -f2)
  $ test -n "$HASH" && echo "hash captured"
  hash captured
  $ printf 'gateway\t%s\n' "$HASH" > "$MANAGED_PS"

Second run: same declaration, same hash. Nothing is stopped, removed, written or
started.

  $ : > ssh-argv.log
  $ bondi-client setup
  Setting up the servers...
  Processing server: 10.0.0.1
  Docker is already installed on server 10.0.0.1: Docker version 27.0.0, build deadbeef
  Network bondi-network is present on server 10.0.0.1
  bondi-orchestrator container started on server 10.0.0.1: 
  $ grep -c 'bondi-gateway' ssh-argv.log
  0
  [1]
  $ grep -c 'umask' ssh-argv.log
  0
  [1]

Affirmative arm: a changed declaration against the same observed hash does
recreate, so the silence above is caused by the hashes matching and not by the
fixture missing the code path.

  $ sed -i 's/tag: "10.48.1e"/tag: "10.49.0a"/' bondi.yaml
  $ : > ssh-argv.log
  $ bondi-client setup | grep gateway
  Stopped bondi-gateway container on server 10.0.0.1
  Removed bondi-gateway container on server 10.0.0.1
  Wrote secret environment file on server 10.0.0.1: /etc/bondi/gateway/env
  bondi-gateway container started on server 10.0.0.1: 
