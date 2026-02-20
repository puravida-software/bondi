# Bondi 🏖️

> Bondi blue belongs to the cyan family of blues. It is very similar to the Crayola crayon color "blue-green". [^1]

[^1]: https://en.wikipedia.org/wiki/Blue-green#Bondi_blue

Dead simple deployment tool for Dockerized services.

## What does it do?

Bondi is both a server and a CLI.

The server:
- listens for deployments from the CLI or API
- pulls the Docker image and runs it
- exposes a web UI for managing the server

The CLI:
- installs Docker on the server if it's not already installed
- pulls and runs the bondi-orchestrator Docker image
- triggers deployments of your service/workload's Docker image to the server

## Prerequisites

- A server with a public IP address
- SSH access to the server and `~/.ssh/known_hosts` file configured
- A Docker image for your service/workload
- DNS `A/AAAA` records pointing your domain to the server IP
- Firewall/security groups allow inbound `80/tcp` and `443/tcp` for Traefik

## Usage (WIP)

1. Install the CLI (Homebrew)

```bash
brew tap puravida-software/homebrew-bondi
brew install bondi
brew upgrade bondi
```

2. Initialise the project config file

Make sure you are inside the project directory, then run:

```bondi init```

3. Configure the project config file as needed:

Edit the `bondi.yaml` file to configure the project.

> Make sure the necessary environment variables are exported in your shell.

4. Setup the bondi-orchestrator in your server, this will install and run:
- Docker
- the Bondi orchestrator

```bondi setup```

5. Deploy your workload (this will also start Traefik)

Single service:

```bondi deploy my-service:v1.2.3```

Multiple targets (service and cron):

```bondi deploy my-service:v1.2.3 backup:v2 cron-job:v3```

6. Check the status of the deployed workload

```bondi status```

## Available Commands

- `bondi init` - Initialize a new Bondi project
- `bondi setup` - Set up the bondi-orchestrator on configured servers
- `bondi deploy NAME:TAG [NAME:TAG ...]` - Deploy services and cron jobs by name and tag
- `bondi status` - Get the status of the deployed workload on all servers

## Deployment Strategies

Bondi will eventually support two deployment strategies:

- **Simple**: Pull the new image, stop the old container, and run the new container.
- **Blue-green (TODO)**: Run the new image in a new container, make it's health check passes, change Traefik's routing to point to the new container, then stop the old container.

## Roadmap

Docs:
- [ ] Add docs for the CLI
- [ ] Add docs for the server

Use cases:
- [x] `bondi status` - Show all containers on all servers
- [x] Subcommands for Docker, e.g. `bondi docker logs`, `bondi docker ps`
- [x] Redeploy Traefik
    - e.g. config changed, but same Traefik version
- [x] Allow for cron workflows to be used
    - configure the underlying cron utility
    - Bondi runs the cron job itself
- [ ] When the cron job finishes, call a service like healthchecks.io
- [ ] Add Alloy support for Grafana Cloud
- [ ] Allow removing a service/cron job
- [ ] `status` should show the status of all Bondi
    - service(s)
    - cron jobs
    - bondi-orchestrator
    - Traefik
- [ ] Set and update for consistent naming for the different concepts and moving parts in Bondi
- [ ] Add blue-green deployments for services
- [ ] Allow multiple server workflows to be used
- [ ] Keep X amount of previous Docker images
- [ ] Remove old bondi-orchestrator containers on the server

Solve:
- [ ] What to do if deploying the same version again?
- [ ] Should we hardcode the `www` in the domain name?

Misc:
- [x] Add Traefik for TLS
- [x] Increase coverage to a decent level
- [x] Add CD pipeline that creates a new release with executables (multiple OSes)
- [ ] Create a `core` library for shared code between the client and server, there's quite a bit of duplication between the two.
- [ ] Proper timezone handling for cron jobs
- [ ] Add CD pipeline that pushes the Docker image to Github
- [ ] Improve error messages
    - e.g. bondi: internal error, uncaught exception:
       Mustache.Render_error:
       Line 4, characters 18-35: the variable 'REGISTRY_USER' is missing.
       Raised at Mustache.raise_err in file "mustache/lib/mustache.ml", line 349, characters 25-59
- [ ] Optimise SSH remote execution
    - e.g. create a single SSH connection and re-use it for multiple commands
- [ ] Add a UI/TUI for the server
