A service with no traefik: block is deployed with no proxy in front of it. Its
port is optional there, since nothing routes to it and nothing publishes it; a
port declared anyway is still sent, and the client says on stderr that it does
nothing. With traefik: the port is still required. Blue-green needs the proxy
to switch traffic through, so declaring it without traefik: is refused before
any server is reached.

What is stubbed here is the box: the stub answers the orchestrator listing and
the deploy, records every command it is asked in ssh-argv.log, and keeps the
deploy's stdin in payload.json. The fixtures are removed first so the file is
re-runnable in a directory a previous run has already written to.

  $ ROOT="$PWD"
  $ rm -f payload.json ssh-argv.log out.txt err.txt
  $ mkdir -p "$ROOT/bin"
  $ cat > "$ROOT/bin/ssh" <<'STUB'
  > #!/bin/sh
  > while [ $# -gt 0 ] && [ "$1" != "--" ]; do shift; done
  > shift
  > printf '%s\n' "$1" >> "$SSH_ARGV_LOG"
  > case "$1" in
  >   'docker ps -a --filter name=^/bondi-orchestrator$'*)
  >     echo "mlopez1506/bondi-server:${ORCHESTRATOR_TAG}" ;;
  >   'docker exec -i bondi-orchestrator bondi-server deploy')
  >     cat > "$DEPLOY_PAYLOAD_LOG"
  >     echo 'deployed' ;;
  >   *) : ;;
  > esac
  > STUB
  $ chmod +x "$ROOT/bin/ssh"
  $ export PATH="$ROOT/bin:$PATH"
  $ export SSH_ARGV_LOG="$ROOT/ssh-argv.log"
  $ export DEPLOY_PAYLOAD_LOG="$ROOT/payload.json"
  $ export ORCHESTRATOR_TAG=0.32.0

A service with no traefik: block and no port.

  $ cat > bondi.yaml <<'EOF'
  > service:
  >   name: web
  >   image: acme/web
  >   env_vars: {}
  >   servers:
  >     - ip_address: 127.0.0.1
  >       ssh:
  >         user: deploy
  > bondi_server:
  >   version: "0.32.0"
  > EOF

It deploys, and says nothing about a port it does not have.

  $ bondi-client deploy web:v1 2> err.txt
  Deployment process initiated...
  Deploying to server: 127.0.0.1
  Deployment initiated on server 127.0.0.1
  $ grep -c 'service.port' err.txt
  0
  [1]

It says that a service with no strategy and no traefik: block is deployed
with simple, on stderr and from the manifest alone.

  $ cat err.txt
  service web has no traefik: block; deploying with simple

The box was read and then deployed to, and the payload is the service's with
no port key at all.

  $ cat ssh-argv.log
  docker ps -a --filter name=^/bondi-orchestrator$ --format '{{.Image}}'
  docker exec -i bondi-orchestrator bondi-server deploy
  $ grep -c '"service_name":"web"' payload.json
  1
  $ grep -c '"port"' payload.json
  0
  [1]

The same service declaring a port.

  $ rm -f payload.json ssh-argv.log
  $ cat > bondi.yaml <<'EOF'
  > service:
  >   name: web
  >   image: acme/web
  >   port: 8080
  >   env_vars: {}
  >   servers:
  >     - ip_address: 127.0.0.1
  >       ssh:
  >         user: deploy
  > bondi_server:
  >   version: "0.32.0"
  > EOF

It deploys, and the payload is the one a client has always sent for this
service: the port is carried, and there are no Traefik fields.

  $ bondi-client deploy web:v1 2>/dev/null
  Deployment process initiated...
  Deploying to server: 127.0.0.1
  Deployment initiated on server 127.0.0.1
  $ cat payload.json
  {"service_name":"web","image":"acme/web:v1","port":8080,"env_vars":{},"force_traefik_redeploy":false}

Stdout above holds no notice. The notices are on stderr, the port first.

  $ bondi-client deploy web:v1 >/dev/null
  service.port is set to 8080 and does nothing without a traefik: block: no proxy routes to it and no host port is published. Remove it from bondi.yaml, or declare traefik:.
  service web has no traefik: block; deploying with simple

With traefik: and no port, bondi.yaml is refused when it is read, naming the
field, and no server is reached.

  $ rm -f payload.json ssh-argv.log
  $ cat > bondi.yaml <<'EOF'
  > service:
  >   name: web
  >   image: acme/web
  >   env_vars: {}
  >   servers:
  >     - ip_address: 127.0.0.1
  >       ssh:
  >         user: deploy
  > bondi_server:
  >   version: "0.32.0"
  > traefik:
  >   domain_name: web.example.com
  >   image: traefik:v3.6.8
  >   acme_email: ops@example.com
  > EOF
  $ bondi-client deploy web:v1 > out.txt 2> err.txt
  [1]
  $ grep -c 'service.port' err.txt
  1
  $ test -e ssh-argv.log
  [1]

Blue-green without traefik: is refused, naming the service, and no server is
reached.

  $ cat > bondi.yaml <<'EOF'
  > service:
  >   name: web
  >   image: acme/web
  >   env_vars: {}
  >   deployment_strategy: blue-green
  >   servers:
  >     - ip_address: 127.0.0.1
  >       ssh:
  >         user: deploy
  > bondi_server:
  >   version: "0.32.0"
  > EOF
  $ bondi-client deploy web:v1 2>&1
  Deployment process initiated...
  Error: service web declares deployment_strategy blue-green and no traefik: block. Blue-green switches traffic through the proxy, so it needs one: declare traefik:, or declare simple or no strategy
  [1]
  $ test -e ssh-argv.log
  [1]

A box from before proxy-less services pulls the image and only then fails, so
a proxy-less service is held to the release that deploys one. The box is read,
refused, and never deployed to.

  $ rm -f payload.json ssh-argv.log
  $ cat > bondi.yaml <<'EOF'
  > service:
  >   name: web
  >   image: acme/web
  >   env_vars: {}
  >   servers:
  >     - ip_address: 127.0.0.1
  >       ssh:
  >         user: deploy
  > bondi_server:
  >   version: "0.31.0"
  > EOF
  $ ORCHESTRATOR_TAG=0.31.0 bondi-client deploy web:v1 > out.txt 2> err.txt
  [1]
  $ grep -c '0.31.0, but .* requires 0.32.0 or later' err.txt
  1
  $ cat ssh-argv.log
  docker ps -a --filter name=^/bondi-orchestrator$ --format '{{.Image}}'
  $ test -e payload.json
  [1]

A run that deploys only a cron job does not deploy the service, so it says
nothing about the service's port or strategy, even though the manifest
declares a port and no traefik: block. Neither is a sentence about a deploy
that is happening. The same manifest deploying the service says both.

  $ rm -f payload.json ssh-argv.log
  $ cat > bondi.yaml <<'EOF'
  > service:
  >   name: web
  >   image: acme/web
  >   port: 8080
  >   env_vars: {}
  >   servers:
  >     - ip_address: 127.0.0.1
  >       ssh:
  >         user: deploy
  > bondi_server:
  >   version: "0.32.0"
  > cron_jobs:
  >   - name: nightly
  >     image: acme/nightly
  >     schedule: "0 3 * * *"
  >     server:
  >       ip_address: 127.0.0.1
  >       ssh:
  >         user: deploy
  > EOF
  $ bondi-client deploy nightly:v1 > out.txt 2> err.txt
  $ grep -c 'service.port\|deploying with simple' err.txt
  0
  [1]
  $ grep -c '"service_name"' payload.json
  0
  [1]
  $ bondi-client deploy web:v1 nightly:v1 > out.txt 2> err.txt
  $ grep -c 'service.port\|deploying with simple' err.txt
  2
