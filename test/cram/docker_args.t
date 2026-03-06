Docker logs with no container name argument.

  $ TERM=dumb bondi-client docker logs 2>&1 | sed ':a;N;$!ba;s/\n */ /g'
  bondi: required argument CONTAINER_NAME is missing Usage: bondi docker logs [OPTION]… CONTAINER_NAME Try 'bondi docker logs --help' or 'bondi --help' for more information.
