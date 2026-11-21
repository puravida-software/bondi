A service's name names its Traefik router on the box, and a name that cannot
be one is refused by the client, before any server is contacted. Traefik splits
a label key at `.`, so a router named with one would leave the service unserved.

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

A manifest whose service is named as given, on one server.

  $ manifest() {
  > cat > bondi.yaml <<EOF
  > service:
  >   name: "$1"
  >   image: ghcr.io/acme/web
  >   port: 8080
  >   env_vars: {}
  >   servers:
  >     - ip_address: 127.0.0.1
  >       ssh:
  >         user: deploy
  > bondi_server:
  >   version: "0.23.0"
  > EOF
  > }

A name holding a dot is refused, naming the field and echoing the value, and
nothing is dialled.

  $ manifest web.app
  $ bondi-client deploy web.app:v2 2>&1
  Deployment process initiated...
  Error reading configuration: invalid bondi.yaml: service.name "web.app" cannot name a Traefik router: a router name is a lowercase letter or digit followed by one or more lowercase letters, digits, _ or -
  [1]
  $ test -e "$SSH_CALLS_LOG" && cat "$SSH_CALLS_LOG" || echo "ssh was never called"
  ssh was never called

The affirmative arm, which is what makes the empty log above mean something:
a name that can be a router reaches the stub, so the stub is the ssh this
client runs.

  $ manifest web-app
  $ bondi-client deploy web-app:v2 > /dev/null 2>&1
  [1]
  $ test -s "$SSH_CALLS_LOG" && echo "ssh was called"
  ssh was called
