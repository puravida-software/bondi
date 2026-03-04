Docker logs with no container name argument.

  $ TERM=dumb bondi-client docker logs 2>&1 | sed ':a;N;$!ba;s/\n */ /g'
  Usage: bondi docker logs [--help] [OPTION]… CONTAINER_NAME bondi: required argument CONTAINER_NAME is missing
