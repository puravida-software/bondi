The incident, end to end. `plan` emits alloy ahead of the managed containers, so
an alloy action that fails strands every declared container behind it — and the
run used to report only the conflict, which reads as one small failure about
alloy rather than a host left part-way through a setup.

  $ ROOT="$PWD"

The stub reports no alloy container, so the plan runs one, and then fails that
`docker run` the way a host holding the name does. Everything before alloy
succeeds, so the failure is genuinely mid-plan.

  $ mkdir -p "$ROOT/bin"
  $ cat > "$ROOT/bin/ssh" <<'STUB'
  > #!/bin/sh
  > while [ $# -gt 0 ] && [ "$1" != "--" ]; do shift; done
  > shift
  > printf '%s\n' "$1" >> "$SSH_ARGV_LOG"
  > cat > /dev/null
  > case "$1" in
  >   *BONDI_ACME_PRESENT*) echo BONDI_ACME_PRESENT ;;
  >   'docker --version') echo 'Docker version 27.0.0, build deadbeef' ;;
  >   *'name=^/bondi-orchestrator$'*'{{.State}}'*)
  >     printf 'running\tmlopez1506/bondi-server:0.10.1\n' ;;
  >   *'ps -a --filter name=^/bondi-alloy$'*'{{.State}}'*) : ;;
  >   *'--name bondi-alloy'*)
  >     echo 'docker: Error response from daemon: Conflict. The container name "/bondi-alloy" is already in use by container "d671990dc231".' >&2
  >     exit 125 ;;
  >   *'/var/spool/cron/crontabs/root'*) echo BONDI_CRONTAB_ABSENT ;;
  >   *) : ;;
  > esac
  > STUB
  $ chmod +x "$ROOT/bin/ssh"
  $ export PATH="$ROOT/bin:$PATH"

Port 9 is the discard port and nothing listens on it, so the orchestrator's own
HTTP source is refused immediately rather than waited out. The stub answers
nothing for the three reads the report takes off the host, so every row below
reads as not found — which is what a host this run never reached looks like.

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
  >   version: "0.10.1"
  > alloy:
  >   grafana_cloud:
  >     instance_id: "123456"
  >     api_key: "glc_secret"
  >     endpoint: "https://logs-prod.grafana.net/loki/api/v1/push"
  > managed_containers:
  >   - name: gateway
  >     image: example.com/ib-gateway
  >     tag: "10.48.1e"
  >     restart: unless-stopped
  > EOF

The run stops on the conflict, and says so: the host's own words, then the phase
it stopped in, the server it happened on, and the phase that never ran. It then
reports the host, so the container the abort stranded is a row an operator reads
rather than a phase name they have to translate into one.

  $ bondi-client setup > out.log 2>&1
  [1]
  $ sed 's/not reachable: .*/not reachable: <detail>/' out.log
  Setting up the servers...
  Processing server: 127.0.0.1
  bondi-orchestrator container is already running on server 127.0.0.1: 0.10.1, skipping...
  Docker is already installed on server 127.0.0.1: Docker version 27.0.0, build deadbeef
  Network bondi-network is present on server 127.0.0.1
  ACME file permissions updated on server 127.0.0.1: /etc/traefik/acme/acme.json
  Alloy config written on server 127.0.0.1: /etc/bondi/alloy/config.alloy
  Error: command failed (125): docker: Error response from daemon: Conflict. The container name "/bondi-alloy" is already in use by container "d671990dc231".
  setup stopped part-way through the alloy phase on server 127.0.0.1, so these phases did not run: managed containers.
  
  Server: 127.0.0.1
  
  Service
    NAME                   SOURCE  IMAGE                            TAG          STATUS        RESTARTS  HEALTH
    my-service             docker  -                                -            not found     -         -
                           orch    not reachable: <detail>
  
  Infrastructure
    NAME                   SOURCE  IMAGE                            TAG          STATUS        RESTARTS  HEALTH
    bondi-orchestrator     docker  -                                -            not found     -         -
                           orch    not reachable: <detail>
    bondi-alloy            docker  -                                -            not found     -         -
                           orch    not reachable: <detail>
    bondi-gateway          docker  -                                -            not found     -         -
                           orch    not reachable: <detail>
  
  Crontab
    bondi section          docker  no Bondi section on the host


The declared container really was stranded — nothing was run for it.

  $ grep -c -F -- 'bondi-gateway' ssh-argv.log
  0
  [1]

Its affirmative arm is the same plan with alloy withdrawn: the managed container
is reached and run, so the absence above is the abort rather than a plan that
never declared it.

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
  >   version: "0.10.1"
  > managed_containers:
  >   - name: gateway
  >     image: example.com/ib-gateway
  >     tag: "10.48.1e"
  >     restart: unless-stopped
  > EOF
  $ : > "$SSH_ARGV_LOG"
  $ bondi-client setup > /dev/null 2>&1
  $ grep -c -F -- 'bondi-gateway' ssh-argv.log
  1
