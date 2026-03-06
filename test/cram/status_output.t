Status with --output json is accepted (no parse error).

  $ cat > bondi.yaml <<'EOF'
  > bondi_server:
  >   version: "0.1.0"
  > EOF
  $ bondi-client status --output json 2>&1
  {}

Status with --output table is accepted (no parse error, empty table for no servers).

  $ bondi-client status --output table 2>&1

Status with --output invalid produces a parse error.

  $ bondi-client status --output invalid 2>&1 | sed "s/'//g" | tr '\n' ' ' | sed 's/  */ /g' | grep -oP 'bondi:.*?(?=Usage:|Try |$)' | sed 's/ $//'
  bondi: option --output: invalid value invalid, expected either json or table

Default (no --output flag) behaves like --output table (no parse error, empty table for no servers).

  $ bondi-client status 2>&1
