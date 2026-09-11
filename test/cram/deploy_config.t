Deploy with valid args but no config file.

  $ bondi-client deploy app:v1 2>&1
  Deployment process initiated...
  Error reading configuration: Sys_error("bondi.yaml: No such file or directory")
  [1]

Deploy with invalid YAML.

  $ echo "not: valid: yaml: [" > bondi.yaml
  $ bondi-client deploy app:v1 2>&1
  Deployment process initiated...
  Error reading configuration: error calling parser: mapping values are not allowed in this context character 0 position 0 returned: 0
  [1]

Deploy with unknown target.

  $ cat > bondi.yaml <<'EOF'
  > bondi_server:
  >   version: "0.1.0"
  > EOF
  $ bondi-client deploy unknown:v1 2>&1
  Deployment process initiated...
  Unknown deployment target: unknown
  [1]

Deploy with valid target but no servers.

  $ cat > bondi.yaml <<'EOF'
  > service:
  >   name: web
  >   image: myimg
  >   port: 8080
  >   registry_user: null
  >   registry_pass: null
  >   env_vars: {}
  >   servers: []
  > bondi_server:
  >   version: "0.1.0"
  > EOF
  $ bondi-client deploy web:v1 2>&1
  Deployment process initiated...
  Error: no servers configured. Add servers to bondi.yaml under service or each cron job.
  [1]

A cron-declaring deploy reads the box's two cron sources and compares them
before it posts anything, so what it prints is the state it found rather than
the state it just created. The stub answers the version gate, the crontab spool
and the payload listing, dispatching on the remote command string the client
sends. $CRON_FILES_KEPT is the only thing that differs between the two runs
below: it makes the payload directory hold the job's two files.
$ORCHESTRATOR_TAG is what the box reports its orchestrator to be, and the
version the pin expects unless a run says otherwise.

  $ ROOT="$PWD"
  $ mkdir -p "$ROOT/bin"
  $ cat > "$ROOT/bin/ssh" <<'STUB'
  > #!/bin/sh
  > while [ $# -gt 0 ] && [ "$1" != "--" ]; do shift; done
  > shift
  > case "$1" in
  >   'docker ps -a --filter name=^/bondi-orchestrator$'*)
  >     echo "mlopez1506/bondi-server:${ORCHESTRATOR_TAG:-0.20.0}" ;;
  >   *'/var/spool/cron/crontabs/root'*)
  >     echo BONDI_CRONTAB_CONTENTS
  >     echo '# BEGIN BONDI CRON'
  >     echo "0 3 * * * docker exec bondi-orchestrator sh -c 'bondi-server run < /etc/bondi/cron/nightly-report/run.json'"
  >     echo '# END BONDI CRON'
  >     echo BONDI_CRONTAB_END ;;
  >   *BONDI_CRON_PAYLOAD_LISTED*)
  >     echo BONDI_CRON_PAYLOAD_LISTED
  >     if [ -n "$CRON_FILES_KEPT" ]; then
  >       echo /etc/bondi/cron/nightly-report/run.json
  >       echo /etc/bondi/cron/nightly-report/env
  >     fi
  >     echo BONDI_CRON_PAYLOAD_END ;;
  >   *) : ;;
  > esac
  > STUB
  $ chmod +x "$ROOT/bin/ssh"
  $ export PATH="$ROOT/bin:$PATH"

  $ cat > bondi.yaml <<'EOF'
  > cron_jobs:
  >   - name: nightly-report
  >     image: acme/report
  >     schedule: "0 3 * * *"
  >     server:
  >       ip_address: 127.0.0.1
  >       port: 9
  >       ssh:
  >         user: deploy
  >         private_key_contents: "not-a-real-key"
  >         private_key_pass: ""
  > bondi_server:
  >   version: "0.20.0"
  > EOF

The section still fires nightly-report and the directory holds neither of its
files, so the job fails at its next fire and this deploy is the thing that
repairs it. The divergence is named on its own line, in the ordinary output,
with no flag asked for it -- and the run carries straight on to contact the box,
which is what the line beneath it says. Nothing of the crontab line itself is
rendered: what is printed is a job's name and what the box will do with it.

  $ bondi-client deploy nightly-report:v1 > out.log 2>&1
  [1]
  $ head -3 out.log
  Deployment process initiated...
  cron job nightly-report on server 127.0.0.1 has neither its run file nor its secret environment file on the box, so it fails at its next fire until it is deployed again
  Deploying to server: 127.0.0.1 at http://127.0.0.1:9/api/v1/deploy

The same fixture with the files on the box. The two sources agree, so nothing
new is said -- silence here is the report, which is what makes the loud case
above legible -- and the exit code is the same as the run that diverged. No cram
deploy reaches an orchestrator, so both runs end on the refused connection to
port 9 rather than on a success; the claim these two arms pin is that the
divergence is not what decides the code, and it is pinned by the two codes being
equal rather than by either one's value. A divergence that refused, or that set
its own code, changes exactly one of these two blocks.

  $ CRON_FILES_KEPT=1 bondi-client deploy nightly-report:v1 > agreed.log 2>&1
  [1]
  $ head -2 agreed.log
  Deployment process initiated...
  Deploying to server: 127.0.0.1 at http://127.0.0.1:9/api/v1/deploy

The same box, a version behind what a crontab line needs. The gate refuses and
the run stops before anything is posted -- and no divergence is printed. The
two sources are read after the gate on purpose: a run that is about to refuse
should neither pay for two reads per server nor bury its own refusal under
them. $ORCHESTRATOR_TAG is the only thing that differs from the first run
above, whose payload directory is equally empty, so the silence below is where
the read sits and not a box whose two sources agree. Move that read above the
gate and the second arm stops being 0.

  $ ORCHESTRATOR_TAG=0.12.0 bondi-client deploy nightly-report:v1 > refused.log 2>&1
  [1]
  $ grep -c 'the server is running bondi-server 0.12.0' refused.log
  1
  $ grep -c 'cron job nightly-report on server' refused.log
  0
  [1]
