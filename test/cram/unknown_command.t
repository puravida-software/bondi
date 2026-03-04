Unknown subcommand produces an error.

  $ TERM=dumb bondi-client nonexistent 2>&1 | sed "s/'//g"
  Usage: bondi [--help] COMMAND …
  bondi: unknown command nonexistent. Must be one of deploy, docker,
         init, setup or status
