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
- [5. Managed Containers](#5-managed-containers)
- [6. Status and Troubleshooting](#6-status-and-troubleshooting)
- [7. Upgrading Bondi](#7-upgrading-bondi)

---

## Prerequisites

Before you start, you need:

- **A server** with a public IP address (e.g. a VPS from Hetzner, DigitalOcean, etc.)
- **SSH access** to the server — Bondi uses SSH to install Docker and run the orchestrator
- **A Docker image** for your service, pushed to a registry (Docker Hub, GHCR, etc.)
- **DNS records** — an `A` (or `AAAA`) record pointing your domain to the server IP
- **Firewall rules** — inbound ports `80/tcp` and `443/tcp` must be open (Traefik handles TLS)
- **`curl` 7.76 or later on the server**, if you use [cron jobs](#3-cron-jobs) — the crontab line Bondi writes uses `--fail-with-body`, so that a failed run both exits non-zero and carries the reason into cron's mail. `bondi setup` checks this and stops with the version it found if the server's curl is older. Debian 12 and Ubuntu 22.04 or later are fine; Debian 11 and Ubuntu 20.04 are not.

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

### Reaching other containers from a cron job

By default a cron job's container runs on Docker's default bridge network and cannot reach other Bondi containers by name. Add `network: bondi-network` to attach it to Bondi's shared network:

```yaml
cron_jobs:
  - name: daily-backup
    image: ghcr.io/acme/backup-job
    schedule: "0 2 * * *"
    network: bondi-network
    server:
      ip_address: "203.0.113.10"
      ssh:
        user: root
        private_key_contents: "{{SSH_PRIVATE_KEY_CONTENTS}}"
        private_key_pass: "{{SSH_PRIVATE_KEY_PASS}}"
```

`bondi-network` is created by `bondi setup`, and `bondi deploy` also ensures it exists before writing the crontab — so a job on the shared network works even on a server that has only ever been deployed to. A cron job attached to it can reach any other container on that network by container name — for example a [managed container](#5-managed-containers) at `bondi-gateway:4002`.

The field is optional. Omitting it leaves the container on the default bridge, which is the previous behaviour.

`bondi-network` is the only value the field accepts. Bondi creates that network and no other, so a cron job declaring a different name is rejected when you deploy, rather than failing later at container-creation time:

```
Non-OK response from server 203.0.113.10: Error deploying: cron jobs declare networks bondi does not manage (daily-backup declares my-other-network). bondi manages only bondi-network: declare that instead, and attach the containers these jobs must reach to bondi-network too
```

Every offending job is named in one message, so a config with several mistakes takes one deploy to find them all rather than one each.

The check is on the declared name alone — Bondi never asks the server which networks exist — so creating `my-other-network` on the server yourself does not clear the error. Change the declaration instead.

The check runs before anything is deployed. A combined `bondi deploy my-api:v2.0.0 daily-backup:v1.0.0` that fails this way leaves both the service and the crontab exactly as they were, so correcting the network and re-running is the whole remedy.

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

### When a run fails

Bondi reports a failed run through two independent channels.

The first is cron itself. The crontab line Bondi writes exits non-zero when the run cannot be started or the server rejects the request, so the failure lands in cron's own record and in the mail cron sends to the account owning the crontab. The server's explanation is included rather than swallowed:

```
curl: (22) The requested URL returned error: 400
Run failed: invalid run payload: Run.run_payload (keys received: job, imag)
```

This channel needs no configuration and is the only one that works when the failure happens before the server can know which job it was — a refused connection, or a request the server cannot decode. A rejected body is reported by the keys that arrived, never by their values, so an environment variable or a sink URL carrying a credential is not echoed into your mail spool.

The second channel is alerting, below, which needs sinks configured and fires once the server knows which job ran.

If a cron job you deployed before upgrading Bondi still fails silently, its crontab line predates this behaviour — re-deploy that job once to replace it.

### Alerting on job outcomes

When a cron job run finishes, Bondi classifies it into one of three severities — `success`, `failure`, or `critical` — and POSTs an alert to the sink URLs you configured for that severity. A run that never started (image pull failed, container never came up) is treated as a `failure` so a job that never ran is never silent.

Classification is driven entirely by the container's exit code, through two optional per-cron-job fields.

#### `exit_code_severities` — mapping exit codes to severities

By default `0` is `success` and every non-zero code is `failure`. To raise specific codes to `critical` (or otherwise override the defaults), list them under the severity they should map to:

```yaml
cron_jobs:
  - name: daily-backup
    image: ghcr.io/acme/backup-job
    schedule: "0 2 * * *"
    exit_code_severities:
      critical: [2, 3]
    server:
      ip_address: "203.0.113.10"
      ssh:
        user: root
        private_key_contents: "{{SSH_PRIVATE_KEY_CONTENTS}}"
        private_key_pass: "{{SSH_PRIVATE_KEY_PASS}}"
```

- The keys are limited to `success`, `failure`, and `critical` — any other key is a config error.
- Codes you do not list keep the defaults (`0` → `success`, non-zero → `failure`).
- Listing the same exit code under two severities is a config error rather than a silent precedence rule.
- Bondi assigns no meaning to any exit code — what a given code signifies is entirely up to the job that produces it.

The whole map is optional; omit it and the defaults apply.

#### `alert_sinks` — where each severity is delivered

Each alerting severity routes to a set of sink URLs. Bondi POSTs to every URL in the matched severity's set independently:

```yaml
cron_jobs:
  - name: daily-backup
    image: ghcr.io/acme/backup-job
    schedule: "0 2 * * *"
    exit_code_severities:
      critical: [2, 3]
    alert_sinks:
      critical:
        - "https://events.pagerduty.com/{{PAGERDUTY_ROUTING_KEY}}"
        - "https://alerts.example.com/record"
      failure:
        - "https://alerts.example.com/record"
    server:
      ip_address: "203.0.113.10"
      ssh:
        user: root
        private_key_contents: "{{SSH_PRIVATE_KEY_CONTENTS}}"
        private_key_pass: "{{SSH_PRIVATE_KEY_PASS}}"
```

- Only `failure` and `critical` take sinks — `success` never alerts.
- A severity with no configured sink emits nothing; there is no implied fallback target.
- **Sink URLs must use `https://`.** A plaintext `http://` or unparseable URL is rejected when `bondi.yaml` is read, not at deploy time.
- Sink URLs often embed credentials (webhook tokens, routing keys). Treat them like `env_vars` secrets and supply them through `{{...}}` template variables rather than hard-coding them.

Bondi POSTs one generic JSON payload per alert, carrying the job name, severity, exit code, and timestamp — nothing sink-specific and no secret material. A consumer that needs a different shape adapts on its own ingest side.

Delivery is best-effort and runs after the run's outcome is recorded: a sink that is down, slow, or erroring never changes that outcome or crashes the orchestrator. Each attempt is bounded by a short timeout, so a slow sink can at most delay the run's HTTP acknowledgement. Every delivery failure — a transport error, a timeout, or a non-2xx response from the sink — is logged (by host only, so a credential-bearing URL is not written to the logs).

Both fields ride in the crontab payload alongside `env_vars`, so run `bondi setup` after adding them (the orchestrator picks up the new config), then deploy the cron job as usual.

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

## 5. Managed Containers

Some deployments need a long-running supporting container that is not your service and is not a scheduled job — a broker gateway, a message queue, a cache. Declare these as **managed containers** and Bondi keeps them converged: started at the tag you pinned when they are declared, recreated when the declaration changes, stopped and removed when you delete them from `bondi.yaml`.

Unlike a service, a managed container is never routed by Traefik — no domain, no TLS, no automatic public route. Reach it from your service and cron jobs over the shared network by container name (for example `bondi-gateway:4002`). Publishing a host port with `ports:` is a separate, explicit choice: it binds on the host like any `docker run -p`, so on a public-facing server that port is reachable from the internet unless you firewall it. Prefer the shared network, and publish a port only when something off that network must reach the container.

Add a `managed_containers` list to your `bondi.yaml`:

```yaml
managed_containers:
  - name: gateway
    image: ghcr.io/acme/ib-gateway
    tag: "10.48.1e"
    restart: unless-stopped
    network: bondi-network
    ports:
      - "4002:4002"
    env_vars:
      TRADING_MODE: paper
    secret_env_vars:
      TWS_PASSWORD: "{{TWS_PASSWORD}}"
```

| Field | Required | Description |
|---|---|---|
| `name` | yes | Identifies the container. Bondi runs it as `bondi-<name>` and keeps its state under `/etc/bondi/<name>` on the server. May contain only letters, digits, `_`, `.` and `-`, and must start with a letter or digit. |
| `image` | yes | Base image **without a tag**. |
| `tag` | yes | The exact tag to run. There is no default and no floating tag — you pin the version, and changing it is what triggers a recreate. |
| `restart` | yes | Docker restart policy: `no`, `on-failure`, `always` or `unless-stopped`. There is no default. |
| `network` | no | Docker network to join. `bondi-network` is the only value the field accepts — use it to be reachable from your service and cron jobs by container name. Bondi creates that network and no other, so any other name is rejected when `bondi.yaml` is read, before any server is contacted. Omit the field to leave the container on the default bridge. |
| `ports` | no | Published port mappings, each written `"<host>:<container>"`. Each binds on all host interfaces (`0.0.0.0`), so on a public-facing server a published port is internet-reachable unless firewalled — omit this and use the shared network for container-to-container access. |
| `env_vars` | no | Environment variables passed inline. Visible in `docker inspect`. |
| `secret_env_vars` | no | Environment variables passed by file reference. Not visible in `docker inspect` or in any process listing. |

Managed containers are provisioned by `bondi setup`, not by `bondi deploy`:

```bash
bondi setup
```

Managed containers are provisioned on every server Bondi knows about, and a
server is only known if it is named by a service or by a cron job. A server that
would host managed containers and nothing else is never contacted — give it a
service or a cron job for now.

### Secrets

A key listed under `secret_env_vars` is written to `/etc/bondi/<name>/env` on the server — a root-owned file created mode `600` — and passed to Docker as `--env-file`. The value never appears on a command line, so it stays out of `docker inspect`, `ps` output and Bondi's own logs. Values under `env_vars` are passed with `-e` and are visible to anyone who can run `docker inspect`.

Declaring the same key in both maps is rejected rather than resolved by precedence — which value won would not be visible in your config.

Environment keys and values must not contain control characters, and a key must not contain `=`. The env file is one `KEY=VALUE` per line and Docker does not unquote it, so a newline in either half would silently declare variables you never wrote. This means a multi-line credential — a PEM key, for example — cannot be passed this way; mount it as a file instead. A rejected value is reported by its key, never by its content, so a bad credential is not echoed to your terminal.

Rotating a secret is a config change like any other: update the value, run `bondi setup`, and the container is recreated with the new credential.

### Changing a declaration

Bondi stamps each container with a digest of its full declaration. On every `bondi setup` it compares that digest against your config:

- **Declared, not running** — the env file is written and the container is started.
- **Running, declaration unchanged** — nothing happens. Setup is safe to re-run.
- **Declaration changed** — including a changed tag, port, env var or secret value — the container is stopped, removed and started again at the new spec.

Because the comparison is against the declaration and not against running status, a managed container that has exited is left alone if its declaration still matches. Restarting it is the restart policy's job, not setup's.

### Removing a managed container

Delete the entry from `managed_containers` and run `bondi setup` again. Bondi stops the container, removes it, and deletes `/etc/bondi/<name>` — so its secrets do not outlive the declaration that created them.

The `bondi-network` Docker network is not removed, by Bondi or by anything else. Other containers may still be attached to it, so tearing it down is left to you: `docker network rm bondi-network` on the server, once nothing needs it.

---

## 6. Status and Troubleshooting

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
  bondi-gateway          ghcr.io/acme/ib-gateway              10.48.1e     running      0          2025-01-15T10:05:00Z
```

Managed containers appear in the Infrastructure section, discovered on the server by label. A container you have declared in `bondi.yaml` that the server did not report shows as `not found` — that usually means `bondi setup` has not been run since you added it.

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
    network: bondi-network
    registry_user: "{{REGISTRY_USER}}"
    registry_pass: "{{REGISTRY_PASS}}"
    env_vars:
      BUCKET: "s3://my-backups"
    exit_code_severities:
      critical: [2, 3]
    alert_sinks:
      critical:
        - "https://events.pagerduty.com/{{PAGERDUTY_ROUTING_KEY}}"
      failure:
        - "https://alerts.example.com/record"
    server:
      ip_address: "203.0.113.10"
      ssh:
        user: root
        private_key_contents: "{{SSH_PRIVATE_KEY_CONTENTS}}"
        private_key_pass: "{{SSH_PRIVATE_KEY_PASS}}"

managed_containers:
  - name: gateway
    image: ghcr.io/acme/ib-gateway
    tag: "10.48.1e"
    restart: unless-stopped
    network: bondi-network
    ports:
      - "4002:4002"
    env_vars:
      TRADING_MODE: paper
    secret_env_vars:
      TWS_PASSWORD: "{{TWS_PASSWORD}}"

alloy:
  grafana_cloud:
    instance_id: "{{GRAFANA_INSTANCE_ID}}"
    api_key: "{{GRAFANA_API_KEY}}"
    endpoint: "https://logs-prod-us-central1.grafana.net/loki/api/v1/push"
  collect: all
  labels:
    env: production
```

---

## 7. Upgrading Bondi

Bondi rejects any configuration or deploy payload carrying a field it does not recognise. That makes the upgrade order a requirement rather than a recommendation, and the hazard runs in both directions:

- **Old CLI, new config.** A `bondi.yaml` using a field your installed CLI predates is rejected when the file is read, before any server is contacted:

  ```
  Error reading configuration: invalid bondi.yaml: Config_file.cron_job
  ```

- **New CLI, old orchestrator.** A CLI that sends a field the orchestrator on the server predates has the deploy rejected with a 400:

  ```
  Non-OK response from server 203.0.113.10: Bad request: invalid deploy payload: Simple.cron_job
  ```

Neither case half-applies your change, but neither message names the offending field either, so an upgrade taken out of order costs you a puzzle. A misspelled field is rejected the same way and reads identically: strictness is deliberate, because a tolerated `alertSinks` would ship the job with alerting silently disabled.

Upgrade in this order:

1. **Release and tag** the Bondi version you intend to run, so both the CLI and the orchestrator image exist at that version.

2. **Update the installed CLI:**

   ```bash
   brew upgrade bondi
   ```

3. **Update the orchestrator on every server.** Set `bondi_server.version` in `bondi.yaml` to the new version, then:

   ```bash
   bondi setup
   ```

   `bondi setup` is what replaces the orchestrator container, so this step is what makes the server able to accept the new fields. `bondi deploy` never upgrades the orchestrator.

4. **Only now add configuration using the new fields**, and deploy:

   ```bash
   bondi deploy my-api:v2.0.0 daily-backup:v1.0.0
   ```

Step 3 before step 4 is the part that is easy to get wrong, because step 3 looks like it only bumps a version string.

### Before the first deploy after an upgrade

- Check that every cron job's `network` is either absent or exactly `bondi-network`, and the same for every managed container's `network`. Any other value now fails before anything is deployed instead of failing at run time — see [Reaching other containers from a cron job](#reaching-other-containers-from-a-cron-job).

- **Re-deploy every cron job once.** A deploy only rewrites the crontab lines for the jobs named in it; lines for other jobs are carried over from the existing crontab untouched. A job that is not re-deployed keeps its old command and stays silent when it fails, however new the orchestrator is. Name them all in one deploy:

  ```bash
  bondi deploy daily-backup:v1.0.0 nightly-report:v1.0.0
  ```

  This is also what applies the failure reporting described in [When a run fails](#when-a-run-fails) to jobs that predate the upgrade.
