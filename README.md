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

```go install github.com/puravida-software/bondi/cli```

2. Initialise the project

Make sure you are inside the project directory, then run:

```bondi init```

3. Configure the project

Edit the `bondi.yaml` file to configure the project.

> Make sure the necessary environment variables exported in your shell.

4. Setup the bondi-server

```bondi setup```

5. Deploy the project

```bondi deploy 0.0.1```

## Roadmap

- [ ] Add Traefik for TLS
- [ ] Increase coverage to a decent level
- [ ] Add blue-green deployments
- [ ] Add a UI/TUI for the server
- [ ] Add CD pipeline that creates a new release with executables (multiple OSes)
