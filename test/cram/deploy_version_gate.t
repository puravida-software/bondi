The version a box reports for its orchestrator is what decides whether a deploy
is sent to it at all, and the whole of that decision runs against a real
[docker ps] read over a real ssh invocation. What is stubbed here is the box,
not the reading of it: the stub answers the listing and the deploy and nothing
else, and every arm below differs only in what the listing says.

The fixtures are removed first so the file is re-runnable in a directory a
previous run has already written to.

  $ ROOT="$PWD"
  $ rm -f ssh-argv.log refused.log proceeded.log unreadable.log empty.log

A stub ssh that answers two commands and records what it was asked. The two
arms are disjoint by construction: the listing's pattern is anchored at the
start of the command and the deploy's is the whole of it, so neither can
swallow the other. Anything else falls through to *) and comes back empty --
which is a failure and not an unstubbed command, so a run that reaches a third
remote command fails here rather than passing quietly.

$ORCHESTRATOR_TAG is what the box reports its orchestrator image to be.
$LISTING_FAILS makes the listing exit non-zero instead, which is the box
refusing to answer rather than answering something old.

  $ mkdir -p "$ROOT/bin"
  $ cat > "$ROOT/bin/ssh" <<'STUB'
  > #!/bin/sh
  > while [ $# -gt 0 ] && [ "$1" != "--" ]; do shift; done
  > shift
  > printf '%s\n' "$1" >> "$SSH_ARGV_LOG"
  > case "$1" in
  >   'docker ps -a --filter name=^/bondi-orchestrator$'*)
  >     if [ -n "$LISTING_FAILS" ]; then echo 'permission denied' >&2; exit 7; fi
  >     echo "mlopez1506/bondi-server:${ORCHESTRATOR_TAG}" ;;
  >   'docker exec -i bondi-orchestrator bondi-server deploy')
  >     cat > /dev/null
  >     echo 'deployed' ;;
  >   *) : ;;
  > esac
  > STUB
  $ chmod +x "$ROOT/bin/ssh"
  $ export PATH="$ROOT/bin:$PATH"
  $ export SSH_ARGV_LOG="$ROOT/ssh-argv.log"

One server, one service, no cron jobs -- so the floor this box is held to is the
one a deploy needs to run a subcommand inside the orchestrator at all, and the
listing is the only remote read the run makes before the deploy itself.

  $ cat > bondi.yaml <<'EOF'
  > service:
  >   name: web
  >   image: acme/web
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
  >   version: "0.20.0"
  > EOF

A box below the floor. The refusal names the version the box is running and the
version it needs, both, in the output the operator is already watching -- which
is the whole of what makes this an answer rather than an obscure failure later
on. It is transcribed rather than matched because both numbers and the reason
are the assertion.

  $ ORCHESTRATOR_TAG=0.12.0 bondi-client deploy web:v1 > refused.log 2>&1
  [1]
  $ cat refused.log
  Deployment process initiated...
  Error on server 127.0.0.1: the server is running bondi-server 0.12.0, but this command runs a 'bondi-server' subcommand inside the orchestrator container, which requires 0.15.0 or later. An older image has no subcommands: it ignores the arguments and starts a second server against a port already bound, so the command would fail without ever running. Set bondi_server.version in bondi.yaml to 0.15.0 or later, run bondi setup, then try again.

Nothing was posted. The refusal is only a refusal if it arrived before the box
was written to, and the box being asked exactly once -- for the listing that
refused it -- is what says so.

  $ cat ssh-argv.log
  docker ps -a --filter name=^/bondi-orchestrator$ --format '{{.Image}}'

The same box at the floor exactly. The gate passes, the deploy is posted, and
the run ends on the line that says so.

  $ : > ssh-argv.log
  $ ORCHESTRATOR_TAG=0.15.0 bondi-client deploy web:v1 > proceeded.log 2>&1
  $ cat proceeded.log
  Deployment process initiated...
  Deploying to server: 127.0.0.1
  Deployment initiated on server 127.0.0.1
  $ cat ssh-argv.log
  docker ps -a --filter name=^/bondi-orchestrator$ --format '{{.Image}}'
  docker exec -i bondi-orchestrator bondi-server deploy

A box that would not answer the listing. A version nobody read is not a version
that passed: the run refuses, says the read is what failed, and carries the
host's own account of why -- and it still posts nothing.

  $ : > ssh-argv.log
  $ LISTING_FAILS=1 bondi-client deploy web:v1 > unreadable.log 2>&1
  [1]
  $ cat unreadable.log
  Deployment process initiated...
  Error on server 127.0.0.1: the orchestrator's version could not be read, and a deploy is not sent to a server whose image it has not seen: the orchestrator listing ran on the host and failed: command failed (7): permission denied
  $ cat ssh-argv.log
  docker ps -a --filter name=^/bondi-orchestrator$ --format '{{.Image}}'

A box that answered the listing with nothing at all. This is the arm the other
three exist to protect: a typo in the filter, a renamed container, a docker that
prints to its error stream instead -- each of them leaves the listing empty and
exiting zero, and an empty answer read as a pass would send every deploy in the
estate to a box nobody has a version for. It refuses, and it refuses saying the
version could not be read rather than naming a number it did not have.

  $ : > ssh-argv.log
  $ ORCHESTRATOR_TAG= bondi-client deploy web:v1 > empty.log 2>&1
  [1]
  $ grep -c 'could not read an orchestrator version from the server' empty.log
  1
  $ grep -c 'Deployment initiated on server' empty.log
  0
  [1]

The affirmative arm for the grep above, on the run that did proceed: the same
pattern does match when the deploy went through, so the zero is the deploy
having been refused and not the pattern being wrong.

  $ grep -c 'Deployment initiated on server' proceeded.log
  1
  $ cat ssh-argv.log
  docker ps -a --filter name=^/bondi-orchestrator$ --format '{{.Image}}'
