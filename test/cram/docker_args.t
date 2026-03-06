Docker logs with no container name argument.

  $ bondi-client docker logs 2>&1 | sed "s/'//g" | tr '\n' ' ' | sed 's/  */ /g' | grep -oP 'bondi:.*?(?=Usage:|Try |$)' | sed 's/ $//'
  bondi: required argument CONTAINER_NAME is missing
