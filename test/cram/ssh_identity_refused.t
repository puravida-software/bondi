An encrypted private key with no passphrase cannot sign. The key file carries
its public half in cleartext, so ssh offers it, the host accepts it, and the
signature that never comes is reported by the host as an authorization failure
-- someone else's verdict on a fault that is entirely local, which is what sent
a real investigation at server configuration for hours. A configuration that
cannot work is refused where it is read, before anything is dialled.

  $ ROOT="$PWD"
  $ mkdir -p "$ROOT/bin"

The stub records the remote command of every call it receives, so "nothing was
dialled" is an assertion over a file rather than an absence nobody looked for.
The orchestrator arm is what the run that is *not* refused goes on to ask.

  $ cat > "$ROOT/bin/ssh" <<'STUB'
  > #!/bin/sh
  > while [ $# -gt 0 ] && [ "$1" != "--" ]; do shift; done
  > shift
  > printf '%s\n' "$1" >> "$SSH_ARGV_LOG"
  > cat > /dev/null
  > case "$1" in
  >   'docker ps -a --filter name=^/bondi-orchestrator$'*)
  >     echo 'mlopez1506/bondi-server:0.20.0' ;;
  >   'docker exec -i bondi-orchestrator bondi-server deploy')
  >     echo 'Error: No such container: bondi-orchestrator' >&2
  >     exit 1 ;;
  >   *) : ;;
  > esac
  > STUB
  $ chmod +x "$ROOT/bin/ssh"

The run that is not refused carries an encrypted key, so it raises an agent of
its own. Stubbed here for the same reason the ssh client is: this file is about
where a configuration is refused, and a real agent would make it also a test of
whichever OpenSSH is installed. Both stubs answer only what this file provokes
and say so loudly otherwise, because a catch-all that returns quietly makes a
missing arm read as a failing command.

  $ cat > "$ROOT/bin/ssh-agent" <<'STUB'
  > #!/bin/sh
  > case "$1" in
  >   -a)
  >     : > "$2"
  >     echo "SSH_AUTH_SOCK=$2; export SSH_AUTH_SOCK;"
  >     echo "SSH_AGENT_PID=4242; export SSH_AGENT_PID;"
  >     ;;
  >   -k) : ;;
  >   *)
  >     echo "ssh-agent stub: nothing stubs: $*" >&2
  >     exit 3
  >     ;;
  > esac
  > STUB
  $ chmod +x "$ROOT/bin/ssh-agent"
  $ cat > "$ROOT/bin/ssh-add" <<'STUB'
  > #!/bin/sh
  > "$SSH_ASKPASS" 'Enter passphrase:' > /dev/null 2>&1
  > echo 'Identity added'
  > STUB
  $ chmod +x "$ROOT/bin/ssh-add"
  $ export PATH="$ROOT/bin:$PATH"
  $ export SSH_ARGV_LOG="$PWD/ssh-argv.log"
  $ : > "$SSH_ARGV_LOG"

One manifest, written by one function, so the two runs below differ in the
passphrase and in nothing else. The key is an aes256-ctr OpenSSH key carried
base64-encoded, which is one of the two encodings a manifest may use; it is
authorised nowhere.

  $ write_manifest() {
  >   cat > bondi.yaml <<EOF
  > service:
  >   name: web
  >   image: registry.example.com/web
  >   port: 8080
  >   env_vars: {}
  >   servers:
  >     - ip_address: 10.0.0.1
  >       ssh:
  >         user: deploy
  >         private_key_contents: "LS0tLS1CRUdJTiBPUEVOU1NIIFBSSVZBVEUgS0VZLS0tLS0KYjNCbGJuTnphQzFyWlhrdGRqRUFBQUFBQ21GbGN6STFOaTFqZEhJQUFBQUdZbU55ZVhCMEFBQUFHQUFBQUJCNWFVamFYcApEUTFpR3cycUZNTVhMbUFBQUFHQUFBQUFFQUFBQXpBQUFBQzNOemFDMWxaREkxTlRFNUFBQUFJSUlpMWFBcFZBWWoxMjIvCm5DeXdxN2lNcWoyMk9Wd1d5NEdUK2pXOFFWTGRBQUFBa0NxbCtDN3IvRk9tQ1Vnc1JYRmJua216WW5XTXF2dDZYeG5yOCsKcFAzUEJOMmExWXRKeWRkdEwzMXl6dldrOXFzTFpqVHNmUnNBZmlDWEU0MjBDbVllSnNRNzRpMzhQQ1NCWFE3U0FJOHUyZQpvenNneHJCYUMwU1lJenppbUN4YVdZNVBTeWVEenFITkMwMFRSQUw2UkdMVWk1Wmg0UWdkM1ZzalpiV09hWTJ1NDBmL3ZqCm1UcDVTOURKb1d5ZjE5SUE9PQotLS0tLUVORCBPUEVOU1NIIFBSSVZBVEUgS0VZLS0tLS0K"
  >         private_key_pass: "$1"
  > bondi_server:
  >   version: "0.20.0"
  > EOF
  > }

With the passphrase empty the configuration is refused at read time. The
message names the server, the field that holds the key, the field that should
hold the passphrase and what could be determined of the cipher -- and it names
the second legal shape, declaring no key at all, because an operator who
already has a working agent is otherwise told to supply a secret they do not
have and do not need.

  $ write_manifest ""
  $ bondi-client deploy web:v1 2>&1
  Deployment process initiated...
  Error reading configuration: server 10.0.0.1: the private key in ssh.private_key_contents is encrypted (aes256-ctr) and ssh.private_key_pass is empty; set the passphrase, or remove the key and let ssh use your own configuration
  [1]

Nothing was dialled.

  $ wc -l < ssh-argv.log
  0

The same manifest with the passphrase set is not refused and reaches the box.
This is what makes the zero above a statement about the refusal rather than
about a stub that nothing ever calls.

  $ write_manifest "fixture-passphrase"
  $ bondi-client deploy web:v1 > proceeded.log 2>&1
  [1]
  $ grep -c 'Error reading configuration' proceeded.log
  0
  [1]
  $ test -s ssh-argv.log && echo the stub recorded a call
  the stub recorded a call

A key that reaches the manifest verbatim through a template variable rather
than base64-encoded is folded by YAML onto a single line: every newline becomes
a space, the armour runs into the body, and what is substituted is no longer a
key. It is armoured all the same -- it names its container and then does not
hold one -- so it is not a format this client has never met and is not staged
for ssh to judge. Refused here, before anything is dialled, is the difference
between a sentence about the manifest and the host's Permission denied.

  $ : > "$SSH_ARGV_LOG"
  $ cat > verbatim.key <<'KEY'
  > -----BEGIN OPENSSH PRIVATE KEY-----
  > b3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jdHIAAAAGYmNyeXB0AAAAGAAAABB5aUjaXp
  > DQ1iGw2qFMMXLmAAAAGAAAAAEAAAAzAAAAC3NzaC1lZDI1NTE5AAAAIIIi1aApVAYj122/
  > nCywq7iMqj22OVwWy4GT+jW8QVLdAAAAkCql+C7r/FOmCUgsRXFbnkmzYnWMqvt6Xxnr8+
  > pP3PBN2a1YtJyddtL31yzvWk9qsLZjTsfRsAfiCXE420CmYeJsQ74i38PCSBXQ7SAI8u2e
  > ozsgxrBaC0SYIzzimCxaWY5PSyeDzqHNC00TRAL6RGLUi5Zh4Qgd3VsjZbWOaY2u40f/vj
  > mTp5S9DJoWyf19IA==
  > -----END OPENSSH PRIVATE KEY-----
  > KEY
  $ SSH_PRIVATE_KEY_CONTENTS="$(cat verbatim.key)"
  $ export SSH_PRIVATE_KEY_CONTENTS
  $ cat > bondi.yaml <<'EOF'
  > service:
  >   name: web
  >   image: registry.example.com/web
  >   port: 8080
  >   env_vars: {}
  >   servers:
  >     - ip_address: 10.0.0.1
  >       ssh:
  >         user: deploy
  >         private_key_contents: "{{SSH_PRIVATE_KEY_CONTENTS}}"
  >         private_key_pass: "fixture-passphrase"
  > bondi_server:
  >   version: "0.20.0"
  > EOF
  $ bondi-client deploy web:v1 2>&1
  Deployment process initiated...
  Error reading configuration: server 10.0.0.1: the private key in ssh.private_key_contents has PEM armour around a body this client cannot read -- the body decoded and did not begin with the OpenSSH key magic; found ""; a key substituted into a quoted scalar is folded onto one line and stops being a key, so carry it base64-encoded or as a block scalar, or remove the key and let ssh use your own configuration
  [1]

Nothing was dialled for it either.

  $ wc -l < ssh-argv.log
  0
