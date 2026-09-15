#!/usr/bin/env bash
#
# An encrypted private key signs against a real sshd.
#
# Every other test of this path stubs `ssh`, the agent, or both, and a stub
# answers whatever it was told to. None of them can say whether a key that needs
# a passphrase actually produces a signature a server accepts -- that behaviour
# exists only where the key classifier, the agent this client raises and the
# options it spells meet, and the only thing that can judge it is an sshd. So
# this file stands one up: its own host key, its own authorized_keys, its own
# port, all under a directory it owns and removes.
#
# What is real here: the ssh client, ssh-agent, ssh-add, the key formats, the
# signature, and sshd's verdict on it. What is not: the port, and the box's
# reply. `ssh` is reached through a one-line shim that adds `-p` and pins the
# host-key file, because this client spells no port and a test must not write to
# the operator's own known_hosts; the shim exec's the real ssh with everything
# else the client asked for, including `-o IdentitiesOnly=yes`. The reply comes
# from a forced command in authorized_keys, so a box that is this very machine
# runs a script of this test's rather than a real `docker`.
#
# The oracle is sshd's own VERBOSE log. "The command came back" would be equally
# true of a run that authenticated with whatever the operator's agent happened
# to hold, so each case asserts the key *fingerprint* sshd accepted is the
# fingerprint of the key the manifest declared.
#
# Written against, and executed under, OpenSSH_10.5p1 with OpenSSL 3.6.4 and GNU
# bash 5.3 -- the client, the agent and the daemon all of that one build. That
# is the whole of what has been run: the OpenSSH a runner's `openssh-server`
# package provides is an older series and this has never executed against it, so
# a failure there is a real possibility rather than an excluded one, and the
# named version is what makes it diagnosable. Nothing here pins a version. The
# workflow installs the package explicitly rather than relying on what a runner
# image happens to ship, which is the difference between a stated dependency and
# a lucky one.
#
# Run by bash, named as such where this is invoked: `local`, `RANDOM` and
# `$((...))` below are bash's, and this is not a `/bin/sh` script that happens
# to work.
#
# Absence of any of those programs is a failure when CI is set and a skip only
# on a developer machine. A skip-if-absent case is indistinguishable from no
# case, and this is the only test covering the behaviour the feature exists for.

set -u

client=${1:?usage: ssh_real_sshd.sh PATH_TO_BONDI_CLIENT}

# The build system hands this over relative to the directory the action runs in,
# and every case below runs the client from the directory holding the manifest
# it wrote. Resolved once, here, rather than at each of those.
case $client in
  /*) ;;
  *) client="$PWD/$client" ;;
esac

passphrase='fixture-passphrase'
wrong_passphrase='not-the-passphrase'

# Every program this needs is resolved here, before the shim below narrows PATH,
# and the answer to a missing one is decided by where this is running. A skip on
# a developer machine is a convenience; a skip on a runner would be this
# feature's only end-to-end coverage disappearing without anything saying so,
# which is exactly the erosion that let the configured passphrase sit unread for
# the life of the project. The OpenSSH programs are then run by the path found
# here rather than by name, so that the shim -- which is an `ssh` on PATH -- is
# reached by the client under test and by nothing else in this file.
#
# The answer is left in `resolved` rather than printed, because a function whose
# verdict is read through `$(...)` runs in a subshell, and a skip it decided on
# would exit that subshell and let the run carry on regardless -- silently, with
# the skip notice captured into a variable. [observed: an earlier draft of this
# file did exactly that.]
resolved=''

require() {
  if resolved=$(command -v "$1" 2> /dev/null); then
    return 0
  fi
  if [ -n "${CI:-}" ]; then
    printf 'FAIL: %s is not on this machine'"'"'s PATH, and CI is set. This is the only test that proves an encrypted key signs, so it is not skippable here: install openssh-server and openssh-client on the runner.\n' \
      "$1" >&2
    exit 1
  fi
  printf 'skipped: %s is not on this machine'"'"'s PATH. This case is not skippable where CI is set, and fails there instead.\n' "$1"
  exit 0
}

require sshd
sshd_bin=$resolved
require ssh
ssh_bin=$resolved
require ssh-agent
require ssh-add
require ssh-keygen
keygen_bin=$resolved
require setsid

# Never a clean slate: this runs in a build directory a previous run has already
# written to, so the working directory is removed rather than reused.
work="$PWD/real-sshd"
rm -rf "$work"
mkdir -p "$work/bin"

# sshd forks a child per connection, so the pid the shell recorded is not the
# whole tree. `setsid` makes it a process-group leader -- the background command
# is not one already, this shell having no job control -- and the teardown kills
# the group.
sshd_pgid=''
cleanup() {
  if [ -n "$sshd_pgid" ]; then
    kill -- "-$sshd_pgid" 2> /dev/null
  fi
  return 0
}
trap cleanup EXIT INT TERM

failures=0

report() {
  local description=$1 expected=$2 actual=$3
  if [ "$expected" = "$actual" ]; then
    printf 'ok: %s\n' "$description"
  else
    printf 'FAIL: %s\n  expected: %s\n  actual:   %s\n' \
      "$description" "$expected" "$actual" >&2
    failures=$((failures + 1))
  fi
}

# The keys, generated here rather than committed: what this file asserts is
# that a signature is accepted, which no fixture makes more true, and a key
# generated by the ssh-keygen that is installed is the key that build's agent
# and daemon will actually be asked to agree about.
#
# The fourth is a second unencrypted key and nothing more; it exists so that two
# servers in one run can be told apart by which key signed for them.
#
# The fifth is encrypted too, and in a different container: a traditional PEM
# with `Proc-Type: 4,ENCRYPTED`, which is what an operator who generated a key
# before OpenSSH 7.8 -- or with `openssl` -- already holds. ssh cannot read the
# public half out of one of those without the passphrase, which the OpenSSH
# container carries in clear; so the arm this exercises is a different arm, and
# the two RSA-only flags are because no PEM form of an ed25519 key exists.
"$keygen_bin" -q -t ed25519 -N '' -C bondi-real-sshd-host -f "$work/host_key"
"$keygen_bin" -q -t ed25519 -N "$passphrase" -C bondi-real-sshd-encrypted \
  -f "$work/encrypted_key"
"$keygen_bin" -q -t ed25519 -N '' -C bondi-real-sshd-unencrypted \
  -f "$work/unencrypted_key"
"$keygen_bin" -q -t ed25519 -N '' -C bondi-real-sshd-second \
  -f "$work/second_key"
"$keygen_bin" -q -t rsa -b 2048 -m PEM -N "$passphrase" \
  -C bondi-real-sshd-pem -f "$work/pem_key"
chmod 600 "$work/host_key" "$work/encrypted_key" "$work/unencrypted_key" \
  "$work/second_key" "$work/pem_key"

fingerprint() {
  "$keygen_bin" -l -f "$1" | awk '{ print $2 }'
}

encrypted_fingerprint=$(fingerprint "$work/encrypted_key.pub")
unencrypted_fingerprint=$(fingerprint "$work/unencrypted_key.pub")
second_fingerprint=$(fingerprint "$work/second_key.pub")
pem_fingerprint=$(fingerprint "$work/pem_key.pub")

# The reply the box gives. A forced command in authorized_keys, so that the
# command this client sends -- a real `docker ps` -- is recorded and answered by
# a script rather than run against this machine's own Docker. It is also what
# makes the session's success observable at all: the line below is the box's,
# and reaching it means sshd verified a signature.
cat > "$work/bin/box" << 'BOX'
#!/bin/sh
printf 'the box ran: %s\n' "$SSH_ORIGINAL_COMMAND"
BOX
chmod +x "$work/bin/box"

# A second box, reached only by the second key. Which box answers is therefore a
# statement about which key signed, and that is what makes the two-server case
# below able to say that the second server got its own connection rather than
# the first server's: a command that rode the first connection is answered by
# the first box, whatever the second server declared.
cat > "$work/bin/box2" << 'BOX'
#!/bin/sh
printf 'the second box ran: %s\n' "$SSH_ORIGINAL_COMMAND"
BOX
chmod +x "$work/bin/box2"

restrictions="command=\"$work/bin/box\",no-agent-forwarding,no-port-forwarding,no-pty,no-user-rc,no-X11-forwarding"
second_restrictions="command=\"$work/bin/box2\",no-agent-forwarding,no-port-forwarding,no-pty,no-user-rc,no-X11-forwarding"
{
  printf '%s %s\n' "$restrictions" "$(cat "$work/encrypted_key.pub")"
  printf '%s %s\n' "$restrictions" "$(cat "$work/unencrypted_key.pub")"
  printf '%s %s\n' "$second_restrictions" "$(cat "$work/second_key.pub")"
  printf '%s %s\n' "$restrictions" "$(cat "$work/pem_key.pub")"
} > "$work/authorized_keys"
chmod 600 "$work/authorized_keys"

# StrictModes is off because the key files live in a build directory whose
# ownership and mode are the build's, not a home directory's, and the daemon
# would otherwise refuse to read them. Password and keyboard-interactive
# authentication are off so that a failure to sign cannot be answered by
# anything else -- a fallback would make every case below pass for the wrong
# reason.
# Two loopback addresses, one daemon. Two servers in a manifest have to be two
# hosts as ssh sees them -- one address twice is one connection by every rule
# ssh has -- and a second address costs nothing here, where the whole of
# 127.0.0.0/8 is already local.
cat > "$work/sshd_config" << EOF
ListenAddress 127.0.0.1
ListenAddress 127.0.0.2
HostKey $work/host_key
AuthorizedKeysFile $work/authorized_keys
PidFile $work/sshd.pid
StrictModes no
UsePAM no
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitTTY no
LogLevel VERBOSE
EOF

# A port nothing else on this machine is using. Which one is not knowable in
# advance, so it is tried: a daemon that could not bind exits, and the next
# candidate is asked. The log is what says it is up -- a sleep long enough to be
# safe on a loaded runner is a sleep this file pays on every run.
port=''
for _attempt in 1 2 3 4 5 6 7 8 9 10; do
  candidate=$((20000 + RANDOM % 20000))
  : > "$work/sshd.log"
  setsid "$sshd_bin" -f "$work/sshd_config" -p "$candidate" \
    -E "$work/sshd.log" -D &
  sshd_pgid=$!
  # A counter rather than `for _wait in $(seq 1 100)`. A command substitution in
  # a for-list is the shape that turns a missing program into a loop body that
  # never runs: with `seq` absent -- and it is not among the programs `require`
  # resolves -- the wait would be skipped ten times over and the run would die
  # as "no sshd could be started", naming the wrong cause on the one test whose
  # whole value is being an honest oracle.
  waited=0
  while [ "$waited" -lt 100 ]; do
    if grep -q "Server listening on 127.0.0.1 port $candidate." \
      "$work/sshd.log" 2> /dev/null \
      && grep -q "Server listening on 127.0.0.2 port $candidate." \
        "$work/sshd.log" 2> /dev/null; then
      port=$candidate
      break
    fi
    kill -0 "$sshd_pgid" 2> /dev/null || break
    sleep 0.1
    waited=$((waited + 1))
  done
  if [ -n "$port" ]; then
    break
  fi
  cleanup
  sshd_pgid=''
done

if [ -z "$port" ]; then
  printf 'FAIL: no sshd could be started on 127.0.0.1 and 127.0.0.2. Its own last words:\n' >&2
  cat "$work/sshd.log" >&2
  exit 1
fi

# The host key is known before the first connection rather than accepted on it.
# `StrictHostKeyChecking=accept-new` would otherwise print a warning to the
# stream two of the cases below read as the box's answer, and would leave a
# client trusting a key it had never been told anything about -- which is the
# opposite of what this file is asserting about the other direction.
{
  printf '[127.0.0.1]:%s %s\n' "$port" "$(cat "$work/host_key.pub")"
  printf '[127.0.0.2]:%s %s\n' "$port" "$(cat "$work/host_key.pub")"
} > "$work/known_hosts"

# The shim. This client spells no port, and it must not be taught one for a
# test; and the known-hosts file written above is no use unless ssh is told to
# read it rather than the operator's. Those two are pinned here and everything
# else -- the identity, `IdentitiesOnly=yes`, the bounds, the multiplexing -- is
# passed through to the real ssh untouched. Configuration files are skipped for
# the same reason the host key was pre-seeded: an operator's `Host *` stanza is
# not this test's input.
cat > "$work/bin/ssh" << EOF
#!/bin/sh
exec "$ssh_bin" -F none -p "$port" \\
  -o UserKnownHostsFile="$work/known_hosts" \\
  -o GlobalKnownHostsFile=/dev/null "\$@"
EOF
chmod +x "$work/bin/ssh"
export PATH="$work/bin:$PATH"

# One manifest, written by one function, so the cases differ in the key and the
# passphrase and in nothing else. The key is carried base64-encoded, which is
# one of the two encodings a manifest may use. `base64` without a wrap flag and
# `tr -d` rather than `base64 -w0`, because the flag is GNU coreutils' and the
# pipeline is not.
write_manifest() {
  local key_file=$1 declared_passphrase=$2
  cat > "$work/bondi.yaml" << EOF
service:
  name: web
  image: registry.example.com/web
  port: 8080
  env_vars: {}
  servers:
    - ip_address: 127.0.0.1
      ssh:
        user: $(id -un)
        private_key_contents: "$(base64 < "$key_file" | tr -d '\n')"
        private_key_pass: "$declared_passphrase"
bondi_server:
  version: "0.20.0"
EOF
}

# The same manifest with two servers, each declaring its own key. Written by its
# own function rather than by parameterising the one above, because what differs
# is the shape of the document and not a value in it.
write_two_server_manifest() {
  local first_key=$1 second_key=$2
  cat > "$work/bondi.yaml" << EOF
service:
  name: web
  image: registry.example.com/web
  port: 8080
  env_vars: {}
  servers:
    - ip_address: 127.0.0.1
      ssh:
        user: $(id -un)
        private_key_contents: "$(base64 < "$first_key" | tr -d '\n')"
        private_key_pass: ""
    - ip_address: 127.0.0.2
      ssh:
        user: $(id -un)
        private_key_contents: "$(base64 < "$second_key" | tr -d '\n')"
        private_key_pass: ""
bondi_server:
  version: "0.20.0"
EOF
}

# What sshd said about this case alone. The log is appended to across the whole
# run, so each case marks where it started and reads only what came after --
# otherwise the third case would be reading the first two's connections.
log_mark=0

mark_log() {
  log_mark=$(wc -l < "$work/sshd.log")
}

# Carriage returns are stripped because this sshd terminates its log lines with
# CRLF [observed under OpenSSH_10.5p1], which an assertion comparing strings
# would otherwise carry into every fingerprint it reads.
log_since_mark() {
  tail -n "+$((log_mark + 1))" "$work/sshd.log" | tr -d '\r'
}

accepted_fingerprint() {
  log_since_mark | sed -n 's/.*Accepted publickey for .* ssh2: [^ ]* //p'
}

run_client() {
  (
    cd "$work" || exit 1
    "$client" docker ps
  ) > "$work/case.log" 2>&1
  printf '%s\n' "$?"
}

# An encrypted key authenticates against a real sshd.
#
# The client classifies the declared key as encrypted, raises an agent of its
# own, loads the key into it with the configured passphrase, and names the
# staged file to ssh with `IdentitiesOnly=yes`. That last option restricts which
# identities may be *offered*, not which agent may sign for them; until this run
# that was read off ssh's manual and never executed, and an accepted signature
# below is the execution.
write_manifest "$work/encrypted_key" "$passphrase"
mark_log
status=$(run_client)
report 'an encrypted key authenticates against a real sshd: the client exits 0' \
  '0' "$status"
report 'an encrypted key authenticates against a real sshd: the box answered' \
  "$(printf '[docker ps] Server: 127.0.0.1\nthe box ran: docker ps')" \
  "$(cat "$work/case.log")"
report 'an encrypted key authenticates against a real sshd: sshd accepted that key' \
  "$encrypted_fingerprint" "$(accepted_fingerprint)"

# An unencrypted key authenticates against a real sshd.
#
# Today's path, unchanged: the key is staged and named to ssh, no agent is
# raised. Here so that the case above is read as the encryption doing something
# rather than as this harness working at all.
write_manifest "$work/unencrypted_key" ''
mark_log
status=$(run_client)
report 'an unencrypted key authenticates against a real sshd: the client exits 0' \
  '0' "$status"
report 'an unencrypted key authenticates against a real sshd: the box answered' \
  "$(printf '[docker ps] Server: 127.0.0.1\nthe box ran: docker ps')" \
  "$(cat "$work/case.log")"
report 'an unencrypted key authenticates against a real sshd: sshd accepted that key' \
  "$unencrypted_fingerprint" "$(accepted_fingerprint)"

# An encrypted traditional-PEM key authenticates against a real sshd.
#
# The same arm as the first case by the classifier's reckoning -- encrypted, so
# an agent is raised and the key is loaded into it -- and a different arm
# entirely at the ssh client, which is what this is here for. An OpenSSH-format
# container carries its public half in clear and ssh reads it off the staged
# file; a traditional PEM does not, and under `BatchMode=yes` ssh cannot ask for
# the passphrase to derive it. With `IdentitiesOnly=yes` the identity is then
# skipped and the agent that holds the decrypted key is never consulted -- the
# key loads, and the host still answers "Permission denied (publickey)".
write_manifest "$work/pem_key" "$passphrase"
mark_log
status=$(run_client)
report 'an encrypted PEM key authenticates against a real sshd: the client exits 0' \
  '0' "$status"
report 'an encrypted PEM key authenticates against a real sshd: the box answered' \
  "$(printf '[docker ps] Server: 127.0.0.1\nthe box ran: docker ps')" \
  "$(cat "$work/case.log")"
report 'an encrypted PEM key authenticates against a real sshd: sshd accepted that key' \
  "$pem_fingerprint" "$(accepted_fingerprint)"

# A wrong passphrase fails without reaching the host.
#
# The key would have been offered, accepted, and then failed to sign, and this
# daemon -- which is listening, and which the two cases above reached -- would
# have reported that as an authorization failure of its own. It records nothing,
# because nothing was dialled.
#
# This is also what holds the first case to its subject. A key ssh-keygen had
# somehow left unencrypted would be staged rather than refused, would connect,
# and would make the first case pass while proving nothing about a passphrase --
# and would fail here, where an exit of 1 is asked for and a connection is asked
# not to happen.
write_manifest "$work/encrypted_key" "$wrong_passphrase"
mark_log
status=$(run_client)
report 'a wrong passphrase fails without reaching the host: the client exits 1' \
  '1' "$status"
report 'a wrong passphrase fails without reaching the host: the fault is named as this machine'"'"'s' \
  'yes' "$(
    case "$(cat "$work/case.log")" in
      'ssh.private_key_pass did not unlock the private key in ssh.private_key_contents on this machine, so no command was run: '*) echo yes ;;
      *) echo no ;;
    esac
  )"
report 'a wrong passphrase fails without reaching the host: sshd saw nothing' \
  '' "$(log_since_mark)"
report 'a wrong passphrase fails without reaching the host: the passphrase is in nothing that was printed' \
  '0' "$(grep -c "$wrong_passphrase" "$work/case.log")"

# Two servers in one process do not share a connection.
#
# Every command this client has loops the manifest's servers inside one process,
# and the connection the first one opens is held open by ControlPersist for
# longer than the whole run takes. A control socket named after the process and
# nothing else is therefore one socket for both -- and the second server's
# command runs down the first server's connection, past the `-i`, the
# `IdentitiesOnly=yes` and the agent that were all chosen for the second.
#
# The two servers differ in the key they declare, and each key is bound to its
# own forced command, so which box answers says which key signed. A run that
# multiplexed gets the first box's answer twice. sshd's log says the same thing
# from the other side: two accepted signatures rather than one.
write_two_server_manifest "$work/unencrypted_key" "$work/second_key"
mark_log
status=$(run_client)
report 'two servers in one process do not share a connection: the client exits 0' \
  '0' "$status"
report 'two servers in one process do not share a connection: each box answered for itself' \
  "$(printf '[docker ps] Server: 127.0.0.1\nthe box ran: docker ps\n[docker ps] Server: 127.0.0.2\nthe second box ran: docker ps')" \
  "$(cat "$work/case.log")"
report 'two servers in one process do not share a connection: sshd accepted both keys' \
  "$(printf '%s\n%s' "$unencrypted_fingerprint" "$second_fingerprint")" \
  "$(accepted_fingerprint)"

if [ "$failures" -ne 0 ]; then
  printf '%d assertion(s) failed against a real sshd (OpenSSH: %s).\n' \
    "$failures" "$("$ssh_bin" -V 2>&1)" >&2
  printf 'The last case left this behind:\n' >&2
  cat "$work/case.log" >&2
  printf 'and sshd said:\n' >&2
  cat "$work/sshd.log" >&2
  exit 1
fi
