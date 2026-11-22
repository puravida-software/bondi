A box whose journal has to be provisioned and refuses a provisioning command
stops the run at that command. The restart that would move the journal is never
sent, and the Alloy already running is not touched.

  $ ROOT="$PWD"

  $ mkdir -p "$ROOT/bin"
  $ cat > "$ROOT/bin/ssh" <<'STUB'
  > #!/bin/sh
  > while [ $# -gt 0 ] && [ "$1" != "--" ]; do shift; done
  > shift
  > printf '%s\n' "$1" >> "$SSH_ARGV_LOG"
  > cat > /dev/null
  > case "$1" in
  >   # The pull setup takes ahead of any stop or run, answered as the docker
  >   # CLI answers one for an image already on the box: four lines on stdout,
  >   # exit 0.
  >   'docker pull '*)
  >     ref=$(printf '%s\n' "$1" | sed "s/^docker pull '\(.*\)'\$/\1/")
  >     printf '%s: Pulling from %s\n' "${ref##*:}" "${ref%:*}"
  >     printf 'Digest: sha256:66a6306db78bf2dbf3487f293aa8d6990d8e506fdffab9cc43fe422becf886e4\n'
  >     printf 'Status: Image is up to date for %s\n%s\n' "$ref" "$ref" ;;
  >   *BONDI_JOURNAL_PRESENT*) echo BONDI_JOURNAL_ABSENT ;;
  >   # The three provisioning commands, each succeeding: the box accepts them
  >   # and its journald still writes nowhere persistent. Named rather than left
  >   # to *) so that a considered silence and an unhandled command read
  >   # differently.
  >   "sudo mkdir -p '/var/log/journal'") : ;;
  >   "sudo systemd-tmpfiles --create --prefix '/var/log/journal'")
  >     echo 'systemd-tmpfiles: permission denied' >&2; exit 1 ;;
  >   'sudo systemctl restart systemd-journald') : ;;
  >   *BONDI_ACME_PRESENT*) echo BONDI_ACME_PRESENT ;;
  >   'docker --version') echo 'Docker version 27.0.0, build deadbeef' ;;
  >   # The orchestrator this file's box already runs, carrying the digest setup
  >   # stamps on a 0.25.0 orchestrator created without the cron payload mounts:
  >   # what this setup would create, so it is pulled and checked rather than
  >   # replaced. Without the digest it reads as a container no setup recorded,
  >   # which is replaced once.
  >   *'name=^/bondi-orchestrator$'*'{{.State}}'*)
  >     printf 'running\tmlopez1506/bondi-server:0.25.0\t92eba0ed2e6c82a23cd21b6c85e10e71\n' ;;
  >   # The image check that follows the pull on that orchestrator: the pulled
  >   # image's id, then the container's, one per line in the docker CLI's full
  >   # sha256 form, and equal because nothing moved the tag.
  >   'docker image inspect '*)
  >     printf 'sha256:66a6306db78bf2dbf3487f293aa8d6990d8e506fdffab9cc43fe422becf886e4\nsha256:66a6306db78bf2dbf3487f293aa8d6990d8e506fdffab9cc43fe422becf886e4\n' ;;
  >   *'ps -a --filter name=^/bondi-alloy$'*'{{.State}}'*)
  >     printf 'running\tgrafana/alloy:v1.8.0\t\n' ;;
  >   *BONDI_ALLOY_MODE_ABSENT*) echo 0640 ;;
  >   *'sudo stat -c %04a'*) echo 0640 ;;
  >   *'cat > '*'/etc/bondi/alloy/env'*) : ;;
  >   *'--name bondi-alloy'*) echo 'd671990dc2318f4b' ;;
  >   *'/var/spool/cron/crontabs/root'*) echo BONDI_CRONTAB_ABSENT ;;
  >   *BONDI_CRON_PAYLOAD_LISTED*)
  >     echo BONDI_CRON_PAYLOAD_LISTED
  >     echo BONDI_CRON_PAYLOAD_END ;;
  >   *'RestartPolicy'*) echo unless-stopped ;;
  >   *'name=^/bondi-orchestrator$'*"--format '{{.Image}}'") echo 'mlopez1506/bondi-server:0.25.0' ;;
  >   *'bondi-server status'*) echo 'this fixture does not answer the report' >&2; exit 1 ;;
  >   *) : ;;
  > esac
  > STUB
  $ chmod +x "$ROOT/bin/ssh"
  $ export PATH="$ROOT/bin:$PATH"
  $ export SSH_ARGV_LOG="$PWD/ssh-argv.log"
  $ : > "$SSH_ARGV_LOG"
  $ cat > bondi.yaml <<'EOF'
  > service:
  >   name: my-service
  >   image: acme/app
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
  >   version: "0.25.0"
  > alloy:
  >   grafana_cloud:
  >     instance_id: "123456"
  >     api_key: "glc_secret"
  >     endpoint: "https://logs-prod.grafana.net/loki/api/v1/push"
  > EOF

The journal reads absent, so setup provisions. The tmpfiles step fails.

  $ bondi-client setup > out.log 2>&1
  [1]
  $ grep -c -F -- 'Error:' out.log
  1
  $ grep -c -F -- 'permission denied' out.log
  1

The command before it ran and the one after it did not.

  $ grep -c -x -F -- "sudo mkdir -p '/var/log/journal'" ssh-argv.log
  1
  $ grep -c -x -F -- 'sudo systemctl restart systemd-journald' ssh-argv.log
  0
  [1]

Alloy was left as it was found: nothing stopped, removed or run.

  $ grep -c -E -- 'docker (stop|rm) bondi-alloy|docker run -d --name bondi-alloy' ssh-argv.log
  0
  [1]
