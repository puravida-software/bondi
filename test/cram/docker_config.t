Docker ps with no config file.

  $ bondi-client docker ps 2>&1
  Error reading configuration: Sys_error("bondi.yaml: No such file or directory")
  [1]

Docker logs with no config file.

  $ bondi-client docker logs mycontainer 2>&1
  Error reading configuration: Sys_error("bondi.yaml: No such file or directory")
  [1]
