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

A configuration declaring the two fields Bondi still parses and no longer acts
on. Both are named, once, before this run reaches anything the configuration is
about -- a notice about the file does not wait on the estate being right. The
file still reads, which is the whole of what keeping the fields buys: a box that
declares one is set up rather than refused.

  $ cat > bondi.yaml <<'EOF'
  > bondi_server:
  >   version: "0.1.0"
  >   bind_address: "0.0.0.0"
  >   api_token: "not-a-real-token"
  > EOF
  $ bondi-client setup 2>&1
  bondi_server.bind_address is set to 0.0.0.0 and no longer does anything: the orchestrator serves no HTTP, so there is no socket to bind. Remove it from bondi.yaml.
  bondi_server.api_token is set and no longer does anything: the orchestrator serves no HTTP, so there is no request to authenticate. Remove it from bondi.yaml, and rotate it if it was ever a real secret -- a credential that sat in a configuration file is compromised whether or not anything still reads it.
  Error: no servers configured. Add servers to bondi.yaml or configure a service with servers.
  [1]
