Help output for the main command.

  $ bondi-client --help=plain
  NAME
         bondi - Bondi deployment CLI.
  
  SYNOPSIS
         bondi COMMAND …
  
  COMMANDS
         deploy [--redeploy-traefik] [OPTION]… [NAME:TAG]…
             Deploy services and cron jobs. Specify name:tag for each target.
  
         docker COMMAND …
             Docker related commands.
  
         init [OPTION]…
             Initialize Bondi configuration.
  
         setup [OPTION]…
             Set up Bondi for a project.
  
         status [OPTION]…
             Get the status of the deployed service container on all configured
             servers.
  
  COMMON OPTIONS
         --help[=FMT] (default=auto)
             Show this help in format FMT. The value FMT must be one of auto,
             pager, groff or plain. With auto, the format is pager or plain
             whenever the TERM env var is dumb or undefined.
  
         --version
             Show version information.
  
  EXIT STATUS
         bondi exits with:
  
         0   on success.
  
         123 on indiscriminate errors reported on standard error.
  
         124 on command line parsing errors.
  
         125 on unexpected internal errors (bugs).
  

Help for init.

  $ bondi-client init --help=plain
  NAME
         bondi-init - Initialize Bondi configuration.
  
  SYNOPSIS
         bondi init [OPTION]…
  
  COMMON OPTIONS
         --help[=FMT] (default=auto)
             Show this help in format FMT. The value FMT must be one of auto,
             pager, groff or plain. With auto, the format is pager or plain
             whenever the TERM env var is dumb or undefined.
  
         --version
             Show version information.
  
  EXIT STATUS
         bondi init exits with:
  
         0   on success.
  
         123 on indiscriminate errors reported on standard error.
  
         124 on command line parsing errors.
  
         125 on unexpected internal errors (bugs).
  
  SEE ALSO
         bondi(1)
  

Help for setup.

  $ bondi-client setup --help=plain
  NAME
         bondi-setup - Set up Bondi for a project.
  
  SYNOPSIS
         bondi setup [OPTION]…
  
  COMMON OPTIONS
         --help[=FMT] (default=auto)
             Show this help in format FMT. The value FMT must be one of auto,
             pager, groff or plain. With auto, the format is pager or plain
             whenever the TERM env var is dumb or undefined.
  
         --version
             Show version information.
  
  EXIT STATUS
         bondi setup exits with:
  
         0   on success.
  
         123 on indiscriminate errors reported on standard error.
  
         124 on command line parsing errors.
  
         125 on unexpected internal errors (bugs).
  
  SEE ALSO
         bondi(1)
  

Help for deploy.

  $ bondi-client deploy --help=plain
  NAME
         bondi-deploy - Deploy services and cron jobs. Specify name:tag for
         each target.
  
  SYNOPSIS
         bondi deploy [--redeploy-traefik] [OPTION]… [NAME:TAG]…
  
  ARGUMENTS
         NAME:TAG
             Deployments as name:tag (e.g. my-service:v1.2.3 backup:v2).
  
  OPTIONS
         --redeploy-traefik
             Force Traefik to be redeployed to pick up config changes.
  
  COMMON OPTIONS
         --help[=FMT] (default=auto)
             Show this help in format FMT. The value FMT must be one of auto,
             pager, groff or plain. With auto, the format is pager or plain
             whenever the TERM env var is dumb or undefined.
  
         --version
             Show version information.
  
  EXIT STATUS
         bondi deploy exits with:
  
         0   on success.
  
         123 on indiscriminate errors reported on standard error.
  
         124 on command line parsing errors.
  
         125 on unexpected internal errors (bugs).
  
  SEE ALSO
         bondi(1)
  

Help for status.

  $ bondi-client status --help=plain
  NAME
         bondi-status - Get the status of the deployed service container on all
         configured servers.
  
  SYNOPSIS
         bondi status [OPTION]…
  
  COMMON OPTIONS
         --help[=FMT] (default=auto)
             Show this help in format FMT. The value FMT must be one of auto,
             pager, groff or plain. With auto, the format is pager or plain
             whenever the TERM env var is dumb or undefined.
  
         --version
             Show version information.
  
  EXIT STATUS
         bondi status exits with:
  
         0   on success.
  
         123 on indiscriminate errors reported on standard error.
  
         124 on command line parsing errors.
  
         125 on unexpected internal errors (bugs).
  
  SEE ALSO
         bondi(1)
  

Help for docker group.

  $ bondi-client docker --help=plain
  NAME
         bondi-docker - Docker related commands.
  
  SYNOPSIS
         bondi docker COMMAND …
  
  COMMANDS
         logs [OPTION]… CONTAINER_NAME
             Show Docker container logs.
  
         ps [OPTION]…
             List Docker containers.
  
  COMMON OPTIONS
         --help[=FMT] (default=auto)
             Show this help in format FMT. The value FMT must be one of auto,
             pager, groff or plain. With auto, the format is pager or plain
             whenever the TERM env var is dumb or undefined.
  
         --version
             Show version information.
  
  EXIT STATUS
         bondi docker exits with:
  
         0   on success.
  
         123 on indiscriminate errors reported on standard error.
  
         124 on command line parsing errors.
  
         125 on unexpected internal errors (bugs).
  
  SEE ALSO
         bondi(1)
  

Help for docker ps.

  $ bondi-client docker ps --help=plain
  NAME
         bondi-docker-ps - List Docker containers.
  
  SYNOPSIS
         bondi docker ps [OPTION]…
  
  COMMON OPTIONS
         --help[=FMT] (default=auto)
             Show this help in format FMT. The value FMT must be one of auto,
             pager, groff or plain. With auto, the format is pager or plain
             whenever the TERM env var is dumb or undefined.
  
         --version
             Show version information.
  
  EXIT STATUS
         bondi docker ps exits with:
  
         0   on success.
  
         123 on indiscriminate errors reported on standard error.
  
         124 on command line parsing errors.
  
         125 on unexpected internal errors (bugs).
  
  SEE ALSO
         bondi(1)
  

Help for docker logs.

  $ bondi-client docker logs --help=plain
  NAME
         bondi-docker-logs - Show Docker container logs.
  
  SYNOPSIS
         bondi docker logs [OPTION]… CONTAINER_NAME
  
  ARGUMENTS
         CONTAINER_NAME (required)
             Container name.
  
  COMMON OPTIONS
         --help[=FMT] (default=auto)
             Show this help in format FMT. The value FMT must be one of auto,
             pager, groff or plain. With auto, the format is pager or plain
             whenever the TERM env var is dumb or undefined.
  
         --version
             Show version information.
  
  EXIT STATUS
         bondi docker logs exits with:
  
         0   on success.
  
         123 on indiscriminate errors reported on standard error.
  
         124 on command line parsing errors.
  
         125 on unexpected internal errors (bugs).
  
  SEE ALSO
         bondi(1)
  
