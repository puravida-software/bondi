`bondi status` reports on every configured server, and one server it cannot read
must neither hide the others nor pass for a run that read everything. Here one
server answers and the other cannot be reached at all.

  $ ROOT="$PWD"

The stub tells the two apart by the destination ssh is given, which is the word
just before the `--` that ends ssh's own arguments. Every read of 127.0.0.2 fails
before any command runs. 127.0.0.1 answers the container listing and its
inspection, and answers nothing else, so its orchestrator and cron sources are
cells saying so. Those are not what this file is about, and they do not decide
the exit code.

  $ mkdir -p "$ROOT/bin"
  $ cat > "$ROOT/bin/ssh" <<'STUB'
  > #!/bin/sh
  > destination=''
  > while [ $# -gt 0 ] && [ "$1" != "--" ]; do destination="$1"; shift; done
  > shift
  > case "$destination" in
  >   *@127.0.0.2) echo 'Permission denied (publickey).' >&2; exit 255 ;;
  > esac
  > case "$1" in
  >   'docker ps -a --format'*)
  >     printf 'my-service\tacme/app:1.4.0\trunning\n' ;;
  >   'docker ps -aq | while read -r id'*)
  >     printf '/my-service\tdeclared\thealthy\t0\t2026-08-01T10:00:00.111111111Z\n' ;;
  >   *) : ;;
  > esac
  > STUB
  $ chmod +x "$ROOT/bin/ssh"
  $ export PATH="$ROOT/bin:$PATH"

  $ cat > bondi.yaml <<'EOF'
  > service:
  >   name: my-service
  >   image: acme/app
  >   port: 8080
  >   env_vars: {}
  >   servers:
  >     - ip_address: 127.0.0.1
  >       ssh:
  >         user: deploy
  >         private_key_contents: "not-a-real-key"
  >         private_key_pass: ""
  >     - ip_address: 127.0.0.2
  >       ssh:
  >         user: deploy
  >         private_key_contents: "not-a-real-key"
  >         private_key_pass: ""
  > bondi_server:
  >   version: "0.10.3"
  > EOF

The table holds both servers: the one that answered with its container as the
host reported it, and the one that did not with the row saying it was not read.
Then stderr names the server that could not be read, and only that one, and the
run exits 1.

  $ bondi-client status > out.log 2> err.log
  [1]
  $ grep -E '^Server:|my-service +docker' out.log | sed 's/not read: .*/not read: <detail>/'
  Server: 127.0.0.1
    my-service             docker  acme/app                         1.4.0        running       0         healthy
  Server: 127.0.0.2
    my-service             docker  not read: <detail>
  $ cat err.log
  status could not read server 127.0.0.2: the host was not reached (255): Permission denied (publickey).
  $ grep -c '127.0.0.1' err.log
  0
  [1]

The same run as JSON follows the same rule. Both servers are keys of the report
on stdout, and the stderr line is the same one, kept off stdout so the JSON is
the report alone.

  $ bondi-client status --output json > out.json 2> err.log
  [1]
  $ grep -oE '^  "127\.0\.0\.[12]"' out.json
    "127.0.0.1"
    "127.0.0.2"
  $ grep -c 'status could not read server' out.json
  0
  [1]
  $ cat err.log
  status could not read server 127.0.0.2: the host was not reached (255): Permission denied (publickey).
