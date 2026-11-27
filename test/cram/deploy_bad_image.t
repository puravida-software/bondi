An image that is not a reference the orchestrator would take is refused by the
client, before any server is contacted. Left to the server, it would be refused
there too, but only after a session had been opened to every box the run names.

The stub ssh records every call it is given and answers none of them, so an
empty log is a run that never reached a server. The fixtures are removed first
so the file can be re-run in a directory a previous run has written to.

  $ ROOT="$PWD"
  $ rm -f "$ROOT/ssh-calls.log"
  $ mkdir -p "$ROOT/bin"
  $ cat > "$ROOT/bin/ssh" <<'STUB'
  > #!/bin/sh
  > printf '%s\n' "$*" >> "$SSH_CALLS_LOG"
  > exit 255
  > STUB
  $ chmod +x "$ROOT/bin/ssh"
  $ export PATH="$ROOT/bin:$PATH"
  $ export SSH_CALLS_LOG="$ROOT/ssh-calls.log"

A manifest whose service image is written as the given one, on one server.

  $ manifest() {
  > cat > bondi.yaml <<EOF
  > service:
  >   name: web
  >   image: "$1"
  >   port: 8080
  >   env_vars: {}
  >   servers:
  >     - ip_address: 127.0.0.1
  >       ssh:
  >         user: deploy
  > traefik:
  >   domain_name: web.example.com
  >   image: traefik:v3.6.8
  >   acme_email: ops@example.com
  > bondi_server:
  >   version: "0.23.0"
  > EOF
  > }

`service.image` is documented as the image without a tag, because the tag is
given at deploy time. One that carries a tag is refused, naming the field and
echoing the value, and nothing is dialled.

  $ manifest ghcr.io/acme/web:1.0
  $ bondi-client deploy web:v2 2>&1
  Deployment process initiated...
  Error reading configuration: invalid bondi.yaml: service.image "ghcr.io/acme/web:1.0" carries a tag or digest: give the image without one, such as ghcr.io/acme/web, and its tag at deploy time
  [1]
  $ test -e "$SSH_CALLS_LOG" && cat "$SSH_CALLS_LOG" || echo "ssh was never called"
  ssh was never called

An image that is no reference at all is refused the same way.

  $ manifest "Acme/Web"
  $ bondi-client deploy web:v2 2>&1
  Deployment process initiated...
  Error reading configuration: invalid bondi.yaml: service.image "Acme/Web" is not an image reference
  [1]
  $ test -e "$SSH_CALLS_LOG" && cat "$SSH_CALLS_LOG" || echo "ssh was never called"
  ssh was never called

A good image with a tag from the command line that composes no reference: the
command line's split cuts at the first colon, so `v2:rc` reads as a tag there,
but no reference carries a colon in its tag.

  $ manifest ghcr.io/acme/web
  $ bondi-client deploy web:v2:rc 2>&1
  Deployment process initiated...
  Error: web:v2:rc cannot be deployed: "ghcr.io/acme/web:v2:rc" is not an image reference
  [1]
  $ test -e "$SSH_CALLS_LOG" && cat "$SSH_CALLS_LOG" || echo "ssh was never called"
  ssh was never called

The affirmative arm, which is what makes the empty logs above mean something:
the same manifest and a tag that composes does reach the stub, so the stub is
the ssh this client runs.

  $ bondi-client deploy web:v2 > /dev/null 2>&1
  [1]
  $ test -s "$SSH_CALLS_LOG" && echo "ssh was called"
  ssh was called
