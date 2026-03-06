Unknown subcommand produces an error.

  $ TERM=dumb bondi-client nonexistent 2>&1 | sed "s/'//g" | sed ':a;N;$!ba;s/\n */ /g'
  bondi: unknown command nonexistent, must be one of deploy, docker, init, setup or status. Usage: bondi COMMAND … Try bondi --help for more information.
