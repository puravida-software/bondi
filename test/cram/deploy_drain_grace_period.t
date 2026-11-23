`service.drain_grace_period` no longer does anything: a blue-green deploy stops
the old container while it is still attached to the network and waits for no
drain. A manifest that still sets it deploys, the client says the setting is
ignored, and the payload does not carry it.

What is stubbed here is the box: the stub answers the orchestrator listing and
the deploy, and keeps the deploy's stdin in payload.json. The fixtures are
removed first so the file is re-runnable in a directory a previous run has
already written to.

  $ ROOT="$PWD"
  $ rm -f payload.json
  $ mkdir -p "$ROOT/bin"
  $ cat > "$ROOT/bin/ssh" <<'STUB'
  > #!/bin/sh
  > while [ $# -gt 0 ] && [ "$1" != "--" ]; do shift; done
  > shift
  > case "$1" in
  >   'docker ps -a --filter name=^/bondi-orchestrator$'*)
  >     echo 'mlopez1506/bondi-server:0.23.0' ;;
  >   'docker exec -i bondi-orchestrator bondi-server deploy')
  >     cat > "$DEPLOY_PAYLOAD_LOG"
  >     echo 'deployed' ;;
  >   *) : ;;
  > esac
  > STUB
  $ chmod +x "$ROOT/bin/ssh"
  $ export PATH="$ROOT/bin:$PATH"
  $ export DEPLOY_PAYLOAD_LOG="$ROOT/payload.json"

  $ cat > bondi.yaml <<EOF
  > service:
  >   name: web
  >   image: acme/web
  >   port: 8080
  >   env_vars: {}
  >   deployment_strategy: blue-green
  >   drain_grace_period: 5
  >   servers:
  >     - ip_address: 127.0.0.1
  >       ssh:
  >         user: deploy
  > bondi_server:
  >   version: "0.23.0"
  > traefik:
  >   domain_name: web.example.com
  >   image: traefik:v3.6.8
  >   acme_email: ops@example.com
  > EOF

The deploy succeeds and says the setting is ignored, on the same stream as
every other notice about a field Bondi parses and no longer acts on.

  $ bondi-client deploy web:v1 2>&1
  Deployment process initiated...
  service.drain_grace_period is set to 5 and is ignored: a blue-green deploy stops the old container while it is still attached to the network, and no longer waits for it to drain. Remove it from bondi.yaml.
  Deploying to server: 127.0.0.1
  Deployment initiated on server 127.0.0.1

The payload is the service's, and carries no drain_grace_period key.

  $ grep -c '"service_name":"web"' payload.json
  1
  $ grep -c 'drain_grace_period' payload.json
  0
  [1]
