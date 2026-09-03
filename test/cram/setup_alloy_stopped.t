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
  > cat > /dev/null
  > case "$1" in
  >   *BONDI_ACME_PRESENT*) echo BONDI_ACME_PRESENT ;;
  >   'docker --version') echo 'Docker version 27.0.0, build deadbeef' ;;
  >   *'name=^/bondi-orchestrator$'*'{{.State}}'*)
  >     printf 'running\tmlopez1506/bondi-server:0.10.1\n' ;;
  >   *'ps -a --filter name=^/bondi-alloy$'*'{{.State}}'*)
  >     printf 'exited\tgrafana/alloy:v1.8.0\n' ;;
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

  $ bondi-client setup 2>&1 | head -10
  Setting up the servers...
  Processing server: 127.0.0.1
  bondi-orchestrator container is already running on server 127.0.0.1: 0.10.1, skipping...
  Docker is already installed on server 127.0.0.1: Docker version 27.0.0, build deadbeef
  Network bondi-network is present on server 127.0.0.1
  ACME file permissions updated on server 127.0.0.1: /etc/traefik/acme/acme.json
  Stopped bondi-alloy container on server 127.0.0.1
  Removed bondi-alloy container and config on server 127.0.0.1
  Alloy config written on server 127.0.0.1: /etc/bondi/alloy/config.alloy
  bondi-alloy container started on server 127.0.0.1: d671990dc2318f4b

The removal is what the incident needed a human for.

  $ grep -c -F -- 'docker rm bondi-alloy' ssh-argv.log
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
