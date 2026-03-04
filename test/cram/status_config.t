Status with no config file.

  $ bondi-client status 2>&1
  Error reading configuration: Sys_error("bondi.yaml: No such file or directory")
  [1]

Status with valid config but no service section and no servers (default table output is empty).

  $ cat > bondi.yaml <<'EOF'
  > bondi_server:
  >   version: "0.1.0"
  > EOF
  $ bondi-client status 2>&1
