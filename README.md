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
- pulls and runs the bondi-server Docker image
- triggers deployments of your service's Docker image to the server

## Prerequisites

- A server with a public IP address
- SSH access to the server and `~/.ssh/known_hosts` file configured
- A Docker image for your service
- Go installed on your local machine (until we release binaries)

## Usage (WIP)

1. Install the CLI

TODO

2. Initialise the project

Make sure you are inside the project directory, then run:

```bondi init```

3. Configure the project

Edit the `bondi.yaml` file to configure the project.

> Make sure the necessary environment variables are exported in your shell.

4. Setup the bondi-server in your server

```bondi setup```

5. Deploy the project

```bondi deploy 0.0.1```

6. Check the status of the deployed service

```bondi status```

## Available Commands

- `bondi init` - Initialize a new Bondi project
- `bondi setup` - Set up the bondi-server on configured servers
- `bondi deploy <tag>` - Deploy a service with the specified tag
- `bondi status` - Get the status of the deployed service on all servers

## Deployment Strategies

Bondi will eventually support two deployment strategies:

- **Simple**: Pull the new image, stop the old container, and run the new container.
- **Blue-green (TODO)**: Run the new image in a new container, make it's health check passes, change Traefik's routing to point to the new container, then stop the old container.

## Roadmap

Docs:
- [ ] Add docs for the CLI
- [ ] Add docs for the server

Use cases:
- [ ] `bondi status` - Show all containers on all servers
- [ ] Subcommands for Docker, e.g. `bondi docker logs`, `bondi docker ps`
- [ ] Redeploy Traefik
    - e.g. config changed, but same Traefik version
- [ ] Keep X amount of previous Docker images
- [ ] Remove old bondi-server containers on the server

Solve:
- [ ] What to do if deploying the same version again?
- [ ] Should we hardcode the `www` in the domain name?

Misc:
- [x] Add Traefik for TLS
- [ ] Increase coverage to a decent level
- [ ] Add blue-green deployments
- [ ] Add a UI/TUI for the server
- [ ] Add CD pipeline that creates a new release with executables (multiple OSes)
- [ ] Improve CI pipeline
    - https://github.com/uber-go/nilaway
- [ ] Optimise SSH remote execution
    - e.g. create a single SSH connection and re-use it for multiple commands
