# Usage Guide

This guide walks through deploying a hypothetical Dockerised service with Bondi, step by step. Each section builds on the previous one — start from the top if this is your first time.

The example service throughout this guide is a web API called `my-api`, published as a Docker image at `ghcr.io/acme/my-api`.

## Table of Contents

- [Prerequisites](#prerequisites)
- [1. Deploying a Service](#1-deploying-a-service)
  - [Initialize the project](#initialize-the-project)
  - [Configure your service](#configure-your-service)
  - [SSH configuration](#ssh-configuration)
  - [Environment variables](#environment-variables)
  - [Private registries](#private-registries)
  - [Set up the server](#set-up-the-server)
  - [Deploy](#deploy)
  - [Check the status](#check-the-status)
- [2. Deployment Strategies](#2-deployment-strategies)
  - [Simple (default)](#simple-default)
  - [Blue-Green](#blue-green)
- [3. Cron Jobs](#3-cron-jobs)
- [4. Alloy (Grafana Cloud Logs)](#4-alloy-grafana-cloud-logs)
- [5. Status and Troubleshooting](#5-status-and-troubleshooting)

---

## Prerequisites

Before you start, you need:

- **A server** with a public IP address (e.g. a VPS from Hetzner, DigitalOcean, etc.)
- **SSH access** to the server — Bondi uses SSH to install Docker and run the orchestrator
- **A Docker image** for your service, pushed to a registry (Docker Hub, GHCR, etc.)
- **DNS records** — an `A` (or `AAAA`) record pointing your domain to the server IP
- **Firewall rules** — inbound ports `80/tcp` and `443/tcp` must be open (Traefik handles TLS)

Install the CLI:

```bash
brew tap puravida-software/homebrew-bondi
brew install bondi
```

---

## 1. Deploying a Service

### Initialize the project

Navigate to your project directory and run:

```bash
bondi init
```

This creates a `bondi.yaml` file with a commented example configuration. The file is the single source of truth for your deployment.

### Configure your service

Edit `bondi.yaml` to describe your service. Here is a minimal configuration:

```yaml
service:
  name: my-api
  image: ghcr.io/acme/my-api
  port: 8080
  servers:
    - ip_address: "203.0.113.10"

bondi_server:
  version: 0.0.0

traefik:
  domain_name: my-api.example.com
  image: traefik:v3.6.8
  acme_email: ops@example.com
```

Key fields:

| Field | Description |
|---|---|
| `service.name` | Name for the Docker container on the server. Also used as the deploy target in `bondi deploy my-api:v1.0.0`. |
| `service.image` | Base image **without a tag**. The tag is provided at deploy time. |
| `service.port` | The port your application listens on inside the container. Traefik routes HTTPS traffic to this port. |
| `traefik.domain_name` | Your domain. Traefik will request a TLS certificate from Let's Encrypt and route traffic for both `my-api.example.com` and `www.my-api.example.com`. |
| `traefik.acme_email` | Email for Let's Encrypt certificate notifications. |
| `bondi_server.version` | Version of the bondi-orchestrator image to run on the server. |

### SSH configuration

Bondi connects to your server via SSH during `bondi setup`. Add SSH credentials to each server entry:

```yaml
servers:
  - ip_address: "203.0.113.10"
    ssh:
      user: root
      private_key_contents: "{{SSH_PRIVATE_KEY_CONTENTS}}"
      private_key_pass: "{{SSH_PRIVATE_KEY_PASS}}"
```

The `{{...}}` syntax is a template variable — Bondi replaces it with the value of the corresponding environment variable at runtime. This keeps secrets out of the config file.

Export the variables before running any Bondi command:

```bash
export SSH_PRIVATE_KEY_CONTENTS="$(cat ~/.ssh/my_server_key | base64)"
export SSH_PRIVATE_KEY_PASS="my-key-passphrase"
```

> **Note:** The private key contents must be base64-encoded.

### Environment variables

Pass environment variables to your service container using the `env_vars` map. Template variables work here too:

```yaml
service:
  name: my-api
  image: ghcr.io/acme/my-api
  port: 8080
  env_vars:
    ENV: "production"
    DATABASE_URL: "{{DATABASE_URL}}"
    SECRET_KEY: "{{SECRET_KEY}}"
  servers:
    - ip_address: "203.0.113.10"
      ssh:
        user: root
        private_key_contents: "{{SSH_PRIVATE_KEY_CONTENTS}}"
        private_key_pass: "{{SSH_PRIVATE_KEY_PASS}}"
```

Then export them in your shell (or CI):

```bash
export DATABASE_URL="postgres://user:pass@db.example.com/mydb"
export SECRET_KEY="super-secret"
```

### Private registries

If your image is in a private registry, add `registry_user` and `registry_pass`:

```yaml
service:
  name: my-api
  image: ghcr.io/acme/my-api
  port: 8080
  registry_user: "{{REGISTRY_USER}}"
  registry_pass: "{{REGISTRY_PASS}}"
  env_vars:
    ENV: "production"
  servers:
    - ip_address: "203.0.113.10"
      ssh:
        user: root
        private_key_contents: "{{SSH_PRIVATE_KEY_CONTENTS}}"
        private_key_pass: "{{SSH_PRIVATE_KEY_PASS}}"
```

```bash
export REGISTRY_USER="my-github-username"
export REGISTRY_PASS="ghp_xxxxxxxxxxxxxxxxxxxx"
```

Bondi uses these credentials to `docker pull` the image on the server. For GitHub Container Registry, use a personal access token with `read:packages` scope as the password.

### Set up the server

Once your `bondi.yaml` is ready and environment variables are exported, provision the server:

```bash
bondi setup
```

This will:

1. Connect to the server via SSH
2. Install Docker if it is not already installed
3. Create the ACME directory for TLS certificates
4. Pull and run the bondi-orchestrator container

You only need to run `bondi setup` once per server, or again when you change the `bondi_server.version` or add features that require server-side changes (like Alloy).

### Deploy

Deploy your service by specifying the name and tag:

```bash
bondi deploy my-api:v1.0.0
```

The name (`my-api`) must match `service.name` in your config. The tag (`v1.0.0`) is appended to `service.image` to form the full image reference (`ghcr.io/acme/my-api:v1.0.0`).

Bondi sends the deployment to the orchestrator running on the server, which:

1. Pulls the image
2. Stops the old container (if any)
3. Starts the new container with Traefik labels for automatic HTTPS routing

### Check the status

After deploying, verify everything is running:

```bash
bondi status
```

This shows a table with your service, infrastructure components (orchestrator, Traefik), and their current state.

---

## 2. Deployment Strategies

### Simple (default)

The simple strategy is the default. It stops the old container, then starts the new one. There is a brief period of downtime during the switch.

You do not need to set anything — omitting `deployment_strategy` uses simple.

### Blue-Green

Blue-green deployments eliminate downtime. Bondi starts the new container alongside the old one, waits for it to pass its health check, then switches Traefik's routing and drains the old container.

> **Important:** Your Docker image must define a `HEALTHCHECK` instruction. Blue-green deployments rely on Docker's health check to decide when the new container is ready.

Enable it by adding `deployment_strategy: blue-green` to your service:

```yaml
service:
  name: my-api
  image: ghcr.io/acme/my-api
  port: 8080
  deployment_strategy: blue-green
  env_vars:
    ENV: "production"
  servers:
    - ip_address: "203.0.113.10"
      ssh:
        user: root
        private_key_contents: "{{SSH_PRIVATE_KEY_CONTENTS}}"
        private_key_pass: "{{SSH_PRIVATE_KEY_PASS}}"
```

Deploy exactly the same way:

```bash
bondi deploy my-api:v2.0.0
```

What happens under the hood:

1. A temporary container (`my-api-new`) is started with the new image
2. Bondi polls Docker's health check until the container reports `healthy` (or the timeout is reached)
3. The old container is disconnected from the Traefik network — it stops receiving new traffic
4. A grace period allows in-flight requests to drain
5. The old container is stopped and removed
6. The new container is renamed to `my-api`

If the health check fails or the timeout is reached, Bondi **automatically rolls back** — the new container is stopped and removed, and the old container continues serving traffic.

#### Tuning blue-green deployments

Three optional fields let you adjust the behavior:

```yaml
service:
  name: my-api
  image: ghcr.io/acme/my-api
  port: 8080
  deployment_strategy: blue-green
  health_timeout: 120       # seconds to wait for healthy (default: 120)
  poll_interval: 1          # seconds between health checks (default: 1)
  drain_grace_period: 2     # seconds to drain before stopping old container (default: 2)
```

| Field | Default | Description |
|---|---|---|
| `health_timeout` | `120` | Maximum seconds to wait for the new container to become healthy. If exceeded, Bondi rolls back. |
| `poll_interval` | `1` | Seconds between health check polls. |
| `drain_grace_period` | `2` | Seconds to wait after disconnecting the old container from the network, allowing in-flight requests to complete. |

---

## 3. Cron Jobs

Bondi can run scheduled tasks using cron. Each cron job runs as a Docker container on a specific server.

Add a `cron_jobs` section to your `bondi.yaml`:

```yaml
cron_jobs:
  - name: daily-backup
    image: ghcr.io/acme/backup-job
    schedule: "0 2 * * *"
    env_vars:
      BUCKET: "s3://my-backups"
      AWS_ACCESS_KEY_ID: "{{AWS_ACCESS_KEY_ID}}"
      AWS_SECRET_ACCESS_KEY: "{{AWS_SECRET_ACCESS_KEY}}"
    server:
      ip_address: "203.0.113.10"
      ssh:
        user: root
        private_key_contents: "{{SSH_PRIVATE_KEY_CONTENTS}}"
        private_key_pass: "{{SSH_PRIVATE_KEY_PASS}}"
```

Key differences from services:

- Each cron job has exactly **one server** (not a list)
- The `schedule` field uses standard cron syntax
- Cron jobs are deployed with the same `bondi deploy` command, by name and tag

Run `bondi setup` again if this is the first time adding cron jobs (the orchestrator needs to be restarted with cron support).

Then deploy the cron job alongside your service, or on its own:

```bash
# Deploy service and cron job together
bondi deploy my-api:v2.0.0 daily-backup:v1.0.0

# Deploy only the cron job
bondi deploy daily-backup:v1.0.0
```

Private registries work the same way — add `registry_user` and `registry_pass` to the cron job:

```yaml
cron_jobs:
  - name: daily-backup
    image: ghcr.io/acme/backup-job
    schedule: "0 2 * * *"
    registry_user: "{{REGISTRY_USER}}"
    registry_pass: "{{REGISTRY_PASS}}"
    server:
      ip_address: "203.0.113.10"
      ssh:
        user: root
        private_key_contents: "{{SSH_PRIVATE_KEY_CONTENTS}}"
        private_key_pass: "{{SSH_PRIVATE_KEY_PASS}}"
```

---

## 4. Alloy (Grafana Cloud Logs)

Bondi can ship container logs to Grafana Cloud using [Grafana Alloy](https://grafana.com/docs/alloy/latest/). Alloy runs as a sidecar container on the server, discovers Bondi-managed containers via the Docker socket, and forwards their logs to Loki.

Add an `alloy` section to your `bondi.yaml`:

```yaml
alloy:
  grafana_cloud:
    instance_id: "{{GRAFANA_INSTANCE_ID}}"
    api_key: "{{GRAFANA_API_KEY}}"
    endpoint: "https://logs-prod-us-central1.grafana.net/loki/api/v1/push"
```

You can find these values in your Grafana Cloud portal under **Connections > Loki**.

Export the credentials:

```bash
export GRAFANA_INSTANCE_ID="123456"
export GRAFANA_API_KEY="glc_xxxxxxxxxxxxxxxx"
```

Then run setup to provision Alloy on the server:

```bash
bondi setup
```

This writes the Alloy configuration to `/etc/bondi/alloy/config.alloy` on the server and starts the `bondi-alloy` container.

### Optional settings

```yaml
alloy:
  grafana_cloud:
    instance_id: "{{GRAFANA_INSTANCE_ID}}"
    api_key: "{{GRAFANA_API_KEY}}"
    endpoint: "https://logs-prod-us-central1.grafana.net/loki/api/v1/push"
  image: grafana/alloy:v1.8.0    # pin a specific version (default: grafana/alloy:v1.8.0)
  collect: all                    # "all" or "services_only" (default: all)
  labels:                         # extra labels attached to every log line
    env: production
    team: platform
```

| Field | Default | Description |
|---|---|---|
| `image` | `grafana/alloy:v1.8.0` | Alloy Docker image. Override to pin or upgrade. |
| `collect` | `all` | `all` collects logs from every Bondi-managed container (service, cron, infrastructure). `services_only` restricts to service and cron containers, excluding infrastructure like the orchestrator and Traefik. |
| `labels` | _(none)_ | Key-value pairs added as external labels on every log line sent to Grafana Cloud. Useful for filtering in Loki by environment, team, etc. |

### Opting a service out of log collection

If you want Alloy to skip a specific service's logs, set `logs: false` on the service:

```yaml
service:
  name: my-api
  image: ghcr.io/acme/my-api
  port: 8080
  logs: false
```

### Removing Alloy

To stop collecting logs, remove the `alloy` section from `bondi.yaml` and run `bondi setup` again. Bondi will stop and remove the Alloy container and clean up its configuration on the server.

---

## 5. Status and Troubleshooting

### Checking status

```bash
bondi status
```

This shows all Bondi-managed components across your servers in a table:

```
Server: 203.0.113.10

Service
  NAME                   IMAGE                               TAG          STATUS       RESTARTS   CREATED
  my-api                 ghcr.io/acme/my-api                 v2.0.0       running      0          2025-01-15T10:30:00Z

Infrastructure
  NAME                   IMAGE                               TAG          STATUS       RESTARTS   CREATED
  bondi-orchestrator     mlopez1506/bondi-server              0.0.0        running      0          2025-01-15T10:00:00Z
  bondi-traefik          traefik                              v3.6.8       running      0          2025-01-15T10:00:00Z
  bondi-alloy            grafana/alloy                        v1.8.0       running      0          2025-01-15T10:00:00Z
```

For machine-readable output:

```bash
bondi status --output json
```

### Redeploying Traefik

If you change the Traefik configuration (e.g. update `acme_email` or the domain), redeploy Traefik without redeploying your service:

```bash
bondi deploy my-api:v2.0.0 --redeploy-traefik
```

The `--redeploy-traefik` flag forces Traefik to be stopped and restarted, even if the image version has not changed. Note that you still need to specify a service deploy target.

### Full configuration example

Here is a complete `bondi.yaml` with all features enabled:

```yaml
service:
  name: my-api
  image: ghcr.io/acme/my-api
  port: 8080
  deployment_strategy: blue-green
  health_timeout: 120
  poll_interval: 1
  drain_grace_period: 2
  registry_user: "{{REGISTRY_USER}}"
  registry_pass: "{{REGISTRY_PASS}}"
  env_vars:
    ENV: "production"
    DATABASE_URL: "{{DATABASE_URL}}"
  servers:
    - ip_address: "203.0.113.10"
      ssh:
        user: root
        private_key_contents: "{{SSH_PRIVATE_KEY_CONTENTS}}"
        private_key_pass: "{{SSH_PRIVATE_KEY_PASS}}"

bondi_server:
  version: 0.0.0

traefik:
  domain_name: my-api.example.com
  image: traefik:v3.6.8
  acme_email: ops@example.com

cron_jobs:
  - name: daily-backup
    image: ghcr.io/acme/backup-job
    schedule: "0 2 * * *"
    registry_user: "{{REGISTRY_USER}}"
    registry_pass: "{{REGISTRY_PASS}}"
    env_vars:
      BUCKET: "s3://my-backups"
    server:
      ip_address: "203.0.113.10"
      ssh:
        user: root
        private_key_contents: "{{SSH_PRIVATE_KEY_CONTENTS}}"
        private_key_pass: "{{SSH_PRIVATE_KEY_PASS}}"

alloy:
  grafana_cloud:
    instance_id: "{{GRAFANA_INSTANCE_ID}}"
    api_key: "{{GRAFANA_API_KEY}}"
    endpoint: "https://logs-prod-us-central1.grafana.net/loki/api/v1/push"
  collect: all
  labels:
    env: production
```
