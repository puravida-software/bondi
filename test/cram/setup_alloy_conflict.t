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
  >   'docker --version') echo 'Docker version 27.0.0, build deadbeef' ;;
  >   *'name=^/bondi-orchestrator$'*'{{.State}}'*)
  >     printf 'running\tmlopez1506/bondi-server:0.10.1\n' ;;
  >   *'ps -a --filter name=^/bondi-alloy$'*'{{.State}}'*) : ;;
  >   *'--name bondi-alloy'*)
  >     echo 'docker: Error response from daemon: Conflict. The container name "/bondi-alloy" is already in use by container "d671990dc231".' >&2
  >     exit 125 ;;
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
  >     - ip_address: 10.0.0.1
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
it stopped in, the server it happened on, and the phase that never ran.

  $ bondi-client setup 2>&1 | tail -2
  Error: command failed (125): docker: Error response from daemon: Conflict. The container name "/bondi-alloy" is already in use by container "d671990dc231".
  setup stopped part-way through the alloy phase on server 10.0.0.1, so these phases did not run: managed containers.

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
  >     - ip_address: 10.0.0.1
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
