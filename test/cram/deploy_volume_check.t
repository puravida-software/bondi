A service that mounts host paths is only deployed to a box on which every one
of them exists. The daemon would refuse a missing source too, but only when it
creates the container -- and the simple strategy has stopped the old one by
then. So the paths are asked about over ssh while nothing on the box has
changed, and a missing one refuses the deploy before the payload is sent.

What is stubbed here is the transport, not the box's shell: the stub runs the
host-path check through a real sh on this machine, so the paths it tests are
real paths under this directory. The fixtures are removed first so the file is
re-runnable in a directory a previous run has already written to.

  $ ROOT="$PWD"
  $ rm -rf ssh-argv.log missing.log unreadable.log present.log "$ROOT/srv"
  $ mkdir -p "$ROOT/srv/web/data"

A stub ssh that answers three commands and records what it was asked. The
listing reports an orchestrator new enough to mount volumes, so the version
gate passes and the check is the only thing left that can refuse. The check
runs as the box would run it. $CHECK_FAILS makes it a box that was never
reached instead: ssh's own exit 255, with ssh's own complaint.

A stand-in sudo grants `sudo -n true` and refuses every test, so root sees
nothing the login user does not, and this machine's sudo is never asked.

  $ mkdir -p "$ROOT/bin"
  $ cat > "$ROOT/bin/sudo" <<'STUB'
  > #!/bin/sh
  > [ "$*" = "-n true" ]
  > STUB
  $ chmod +x "$ROOT/bin/sudo"
  $ cat > "$ROOT/bin/ssh" <<'STUB'
  > #!/bin/sh
  > while [ $# -gt 0 ] && [ "$1" != "--" ]; do shift; done
  > shift
  > printf '%s\n' "$1" >> "$SSH_ARGV_LOG"
  > case "$1" in
  >   'docker ps -a --filter name=^/bondi-orchestrator$'*)
  >     echo 'mlopez1506/bondi-server:0.23.0' ;;
  >   '[ -e '*)
  >     if [ -n "$CHECK_FAILS" ]; then
  >       echo 'ssh: connect to host 127.0.0.1 port 9: Connection refused' >&2
  >       exit 255
  >     fi
  >     sh -c "$1" ;;
  >   'docker exec -i bondi-orchestrator bondi-server deploy')
  >     cat > /dev/null
  >     echo 'deployed' ;;
  >   *) : ;;
  > esac
  > STUB
  $ chmod +x "$ROOT/bin/ssh"
  $ export PATH="$ROOT/bin:$PATH"
  $ export SSH_ARGV_LOG="$ROOT/ssh-argv.log"

One server, one service mounting two host paths. The first exists; the second,
the invoices directory, does not.

  $ cat > bondi.yaml <<EOF
  > service:
  >   name: web
  >   image: acme/web
  >   port: 8080
  >   env_vars: {}
  >   volumes:
  >     - host: $ROOT/srv/web/data
  >       container: /data
  >       read_only: false
  >     - host: $ROOT/srv/web/invoices
  >       container: /invoices
  >       read_only: true
  >   servers:
  >     - ip_address: 127.0.0.1
  >       port: 9
  >       ssh:
  >         user: deploy
  >         private_key_contents: "not-a-real-key"
  >         private_key_pass: ""
  > bondi_server:
  >   version: "0.23.0"
  > EOF

The missing path refuses the deploy, naming the server and the path -- and only
the path that is missing.

  $ : > ssh-argv.log
  $ bondi-client deploy web:v1 > missing.log 2>&1
  [1]
  $ cat missing.log
  Deployment process initiated...
  Error on server 127.0.0.1: the service mounts host paths that do not exist on the server: "$TESTCASE_ROOT/srv/web/invoices". Bondi does not create them: create each one, owned by the user the container runs as, then deploy again.

The box was asked for its version and its paths, and nothing else: the deploy
command never reached it.

  $ grep -c 'bondi-server deploy' ssh-argv.log
  0
  [1]
  $ wc -l < ssh-argv.log
  2

Nothing was created either. The check tests; it never makes the directory it
found missing.

  $ test -e "$ROOT/srv/web/invoices"
  [1]

A box that could not be reached for the check. A check that did not run is not
a check that passed, and it is not a missing path: the run refuses saying the
paths could not be checked, carries ssh's own account of why, and posts
nothing.

  $ : > ssh-argv.log
  $ CHECK_FAILS=1 bondi-client deploy web:v1 > unreadable.log 2>&1
  [1]
  $ cat unreadable.log
  Deployment process initiated...
  Error on server 127.0.0.1: the host paths the service mounts could not be checked, and a deploy is not sent to a server whose paths have not been seen: the host was not reached (255): ssh: connect to host 127.0.0.1 port 9: Connection refused
  $ grep -c 'bondi-server deploy' ssh-argv.log
  0
  [1]

The operator creates the missing directory, and the same file deploys: the
check passes and the deploy is posted. This is the arm that shows the refusals
above are the paths' and not the fixture's, and that the grep above does match
a deploy that was sent.

  $ mkdir -p "$ROOT/srv/web/invoices"
  $ : > ssh-argv.log
  $ bondi-client deploy web:v1 > present.log 2>&1
  $ cat present.log
  Deployment process initiated...
  Deploying to server: 127.0.0.1
  Deployment initiated on server 127.0.0.1
  $ grep -c 'bondi-server deploy' ssh-argv.log
  1
