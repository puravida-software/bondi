Setup with no config file.

  $ bondi-client setup 2>&1
  Error reading configuration: Sys_error("bondi.yaml: No such file or directory")
  [1]

Setup with invalid YAML.

  $ echo "bad: yaml: [" > bondi.yaml
  $ bondi-client setup 2>&1
  Error reading configuration: error calling parser: mapping values are not allowed in this context character 0 position 0 returned: 0
  [1]

Setup with valid config but no servers.

  $ cat > bondi.yaml <<'EOF'
  > bondi_server:
  >   version: "0.1.0"
  > EOF
  $ bondi-client setup 2>&1
  Error: no servers configured. Add servers to bondi.yaml or configure a service with servers.
  [1]
