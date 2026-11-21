`traefik.acme_ca_server` names the ACME directory Traefik orders certificates
from. A value that is set travels to the orchestrator in the deploy payload. One
that is absent travels as no field at all, because an orchestrator that
predates the field refuses a payload carrying it. A value that is not an https
URL is refused by the client, before any server is contacted.

What is stubbed here is the box: the stub answers the orchestrator listing and
the deploy, keeps the deploy's stdin in $DEPLOY_PAYLOAD_LOG, and records every
command it is asked in ssh-argv.log. The fixtures are removed first so the file
is re-runnable in a directory a previous run has already written to.

  $ ROOT="$PWD"
  $ rm -f ssh-argv.log set.json absent.json
  $ mkdir -p "$ROOT/bin"
  $ cat > "$ROOT/bin/ssh" <<'STUB'
  > #!/bin/sh
  > while [ $# -gt 0 ] && [ "$1" != "--" ]; do shift; done
  > shift
  > printf '%s\n' "$1" >> "$SSH_ARGV_LOG"
  > case "$1" in
  >   'docker ps -a --filter name=^/bondi-orchestrator$'*)
  >     echo 'mlopez1506/bondi-server:0.23.0' ;;
  >   'docker exec -i bondi-orchestrator bondi-server deploy')
  >     cat > "${DEPLOY_PAYLOAD_LOG:-/dev/null}"
  >     echo 'deployed' ;;
  >   *) : ;;
  > esac
  > STUB
  $ chmod +x "$ROOT/bin/ssh"
  $ export PATH="$ROOT/bin:$PATH"
  $ export SSH_ARGV_LOG="$ROOT/ssh-argv.log"

A manifest with a Traefik block, whose certificate-server line is given as the
argument, or left out when there is none.

  $ manifest() {
  > cat > bondi.yaml <<EOF
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
  >   version: "0.23.0"
  > traefik:
  >   domain_name: web.example.com
  >   image: traefik:v3.6.8
  >   acme_email: ops@example.com
  > $1
  > EOF
  > }

Set to Let's Encrypt's staging directory, the value reaches the payload under
`traefik_acme_ca_server`, exactly as written.

  $ manifest '  acme_ca_server: https://acme-staging-v02.api.letsencrypt.org/directory'
  $ DEPLOY_PAYLOAD_LOG=set.json bondi-client deploy web:v1
  Deployment process initiated...
  Deploying to server: 127.0.0.1
  Deployment initiated on server 127.0.0.1
  $ grep -o '"traefik_acme_ca_server":"[^"]*"' set.json
  "traefik_acme_ca_server":"https://acme-staging-v02.api.letsencrypt.org/directory"

Absent, the payload carries the rest of the Traefik block and no
certificate-server key at all.

  $ manifest ''
  $ DEPLOY_PAYLOAD_LOG=absent.json bondi-client deploy web:v1
  Deployment process initiated...
  Deploying to server: 127.0.0.1
  Deployment initiated on server 127.0.0.1
  $ grep -c '"traefik_acme_email":"ops@example.com"' absent.json
  1
  $ grep -c 'acme_ca_server' absent.json
  0
  [1]

An http directory is refused, naming the field and echoing the value, and the
box is never asked anything.

  $ : > ssh-argv.log
  $ manifest '  acme_ca_server: http://acme-staging-v02.api.letsencrypt.org/directory'
  $ bondi-client deploy web:v1 2>&1
  Deployment process initiated...
  Error reading configuration: invalid bondi.yaml: traefik.acme_ca_server "http://acme-staging-v02.api.letsencrypt.org/directory" is not an ACME directory URL: it must be an absolute https:// URL that names a host and holds no whitespace or control character
  [1]
  $ cat ssh-argv.log
