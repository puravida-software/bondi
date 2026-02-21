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
