Unknown subcommand produces an error.

  $ bondi-client nonexistent 2>&1 | sed "s/'//g" | tr '\n' ' ' | sed 's/  */ /g' | grep -oP 'bondi:.*?(?=Usage:|Try |$)' | sed 's/ $//;s/\. [Mm]ust/, must/;s/\.$//'
  bondi: unknown command nonexistent, must be one of deploy, docker, init, setup or status
