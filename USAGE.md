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
  - [Persistent data (volumes)](#persistent-data-volumes)
  - [Set up the server](#set-up-the-server)
  - [Deploy](#deploy)
  - [Check the status](#check-the-status)
- [2. Deployment Strategies](#2-deployment-strategies)
  - [Simple (default)](#simple-default)
  - [Blue-Green](#blue-green)
  - [Retried requests](#retried-requests)
- [3. Cron Jobs](#3-cron-jobs)
- [4. Alloy (Grafana Cloud Logs)](#4-alloy-grafana-cloud-logs)
- [5. Managed Containers](#5-managed-containers)
- [6. Status and Troubleshooting](#6-status-and-troubleshooting)
- [7. Upgrading Bondi](#7-upgrading-bondi)

---

## Prerequisites

Before you start, you need:

- **A server** with a public IP address (e.g. a VPS from Hetzner, DigitalOcean, etc.)
- **SSH access** to the server, and an `ssh:` block for every server entry in `bondi.yaml` — Bondi uses SSH to install Docker, to run the orchestrator, and to reach it afterwards. `bondi deploy` and `bondi status` do their work by running a `bondi-server` subcommand inside the orchestrator's container over SSH, so a server entry carrying only an `ip_address` is no longer deployable or readable: `bondi deploy` refuses it by name, and `bondi status` reports its containers as not read. This holds for every server, including a `127.0.0.1` entry for a box Bondi is running on — that case used to bypass SSH and no longer does.
- **`bondi-server` 0.15.0 or later already running on the server** — `bondi deploy` and `bondi status` refuse against an older orchestrator, because the subcommands they run arrived in 0.15.0 and an older image ignores the arguments and starts a second server instead. The refusal names both versions and the fix: set `bondi_server.version` in `bondi.yaml` to `0.15.0` or later, run `bondi setup`, then try again. Cron jobs are held to a higher floor still — see the cron-jobs bullet below.
- **A Docker image** for your service, pushed to a registry (Docker Hub, GHCR, etc.)
- **DNS records** — an `A` (or `AAAA`) record pointing your domain to the server IP
- **Firewall rules** — inbound ports `80/tcp` and `443/tcp` must be open (Traefik handles TLS)
- **If you use [cron jobs](#3-cron-jobs)**, three more things about the server:
  - **`bondi-server` 0.16.0 or later must already be running on it.** The crontab line Bondi writes is a `docker exec` into the orchestrator that runs the server binary's `run` subcommand. That subcommand arrived in 0.15.0, but 0.15.0's own crontab writer still emits the older `curl` line and writes no run file — and the deploy that rewrites a box's crontab runs on the box, so an orchestrator below 0.16.0 answers a cron deploy with success and changes nothing. `bondi deploy` reads the orchestrator's version off the box and refuses a cron-declaring deploy against an older one, naming both versions. Run `bondi setup` first, with the version you want pinned under `bondi_server:`.
  - **`docker` must be on the `PATH` cron runs jobs with** — `/usr/bin:/bin` on Debian and Ubuntu. The line invokes `docker exec` by name, and cron gives a job a minimal environment rather than a login one, so a Docker installed under `/usr/local/bin` answers over SSH and still fails every scheduled run. `bondi setup` asks the server what an empty environment resolves and stops if the answer is nothing. The apt install `get.docker.com` performs — which is what Bondi installs — puts it at `/usr/bin/docker`.
  - **`curl` 7.76 or later**, only if the server still holds cron lines written by an older Bondi. Those lines are `curl` invocations using `--fail-with-body`, which an older curl rejects as an unknown option, and they keep firing on their schedule until each job is deployed again. What they can no longer do is succeed: a current image serves nothing, and no orchestrator `bondi setup` creates publishes a port, so on a box running a current orchestrator every such line fails at the connection whatever curl the host has. `bondi setup` still checks the version and stops with what it found; the fix that actually retires those lines is to deploy each cron job once. Debian 12 and Ubuntu 22.04 or later are fine; Debian 11 and Ubuntu 20.04 are not.
- **If you ship logs with [Alloy](#4-alloy-grafana-cloud-logs)**, the server must run systemd's journald, because cron jobs' lines are read from its journal. `bondi setup` makes the journal persistent if it is not. See [The server's journal must be persistent](#the-servers-journal-must-be-persistent). The server also needs `curl`, and port `12345` on its loopback must be free: after starting Alloy, setup asks it for its health there with the server's `curl`. See [Reading Alloy's counters](#reading-alloys-counters).

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
      ssh:
        user: root

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
| `service.name` | Name for the Docker container on the server. Also used as the deploy target in `bondi deploy my-api:v1.0.0`, and as the name of the service's Traefik router. It must be at least two characters: a lowercase letter or digit, then lowercase letters, digits, `_` or `-`. A `.` is refused, because Traefik reads it as a separator in its label keys and would not serve the service. Uppercase is refused, because Traefik label keys are case-insensitive and `Api` and `api` would collide. `acme-http` is refused too: Bondi's own Traefik container uses it for the ACME challenge. A name outside this rule is refused when `bondi.yaml` is read, before any server is contacted. |
| `service.image` | Base image **without a tag**. The tag is provided at deploy time. A registry port works (`registry.example.com:5000/app`). A value that is not a valid image reference is refused when `bondi.yaml` is read. |
| `service.port` | The port your application listens on inside the container. Traefik routes HTTPS traffic to this port. |
| `service.volumes` | Optional. Host directories to mount into the service's container so that what it writes survives a deploy. Each entry has `host`, `container` and `read_only`. Omit it for no mounts. See [Persistent data (volumes)](#persistent-data-volumes). |
| `traefik.domain_name` | Your domain. Traefik will request a TLS certificate from Let's Encrypt and route traffic for both `my-api.example.com` and `www.my-api.example.com`. |
| `traefik.image` | The Traefik image. An image with no tag pulls `latest`, a moving target, unlike a workload image, which Bondi refuses without a tag or digest. Pin a tag, as in the example above. An empty value is refused, and an image in a private registry is not supported: Traefik is pulled without credentials. |
| `traefik.acme_email` | Email for Let's Encrypt certificate notifications. |
| `traefik.acme_ca_server` | Optional. The ACME directory URL Traefik orders its TLS certificates from. Omit it to use Let's Encrypt production. Set it to use another ACME server, for example Let's Encrypt staging on a test box: `https://acme-staging-v02.api.letsencrypt.org/directory`. It must be an absolute `https://` URL that names a host; any other value is refused when `bondi.yaml` is read. A change takes effect when Traefik is redeployed, under either deployment strategy — see [Redeploying Traefik](#redeploying-traefik). |
| `bondi_server.version` | Version of the bondi-orchestrator image to run on the server. |
| `servers[].port` | Accepted and ignored — setting it changes nothing. Nothing dials the orchestrator any more; `bondi deploy` and `bondi status` run the server's subcommands inside its container over SSH, and `bondi setup` publishes no host port for any orchestrator it creates — a container an older Bondi created may still publish one until a version bump makes `bondi setup` replace it. The field is still accepted so that a `bondi.yaml` written before that change keeps parsing. Not to be confused with `service.port` above. |
| `bondi_server.bind_address` | Accepted and ignored — setting it changes nothing, and `bondi setup` and `bondi deploy` each print a line saying so. The orchestrator serves no HTTP, so there is no socket to bind. The field is still accepted so that a `bondi.yaml` written before that change keeps parsing; removal is planned, so remove it from your `bondi.yaml`. |
| `bondi_server.api_token` | Accepted and ignored — setting it changes nothing, and `bondi setup` and `bondi deploy` each print a line saying so. The orchestrator serves no HTTP, so there is no request to authenticate. The field is still accepted so that a `bondi.yaml` written before that change keeps parsing; removal is planned. Remove it from your `bondi.yaml`, and rotate it if it was ever a real secret — a credential that sat in a configuration file is compromised whether or not anything still reads it. |

### SSH configuration

Every server entry needs an `ssh:` block, and `user` is the only field it must carry. How Bondi authenticates is decided by which of the two key fields you add beside it, and there are three legitimate shapes.

**1. Declare no key — Bondi uses your own SSH configuration.**

```yaml
servers:
  - ip_address: "203.0.113.10"
    ssh:
      user: root
```

Bondi imposes no identity and stages nothing, so whatever authenticates you when you type `ssh root@203.0.113.10` authenticates Bondi: your agent, your `~/.ssh/config`, a `ProxyJump` host, a key held in a hardware token. This is what `bondi init` scaffolds, and it is the right shape for a laptop and for any CI runner that already loads a key into an agent. A hardware-backed key can only be used this way — it cannot be carried as a string.

Bondi passes `BatchMode=yes` and never stops to ask for anything, so the identity you are relying on has to be usable unprompted: an agent that already holds the key, or a key with no passphrase on it. A hardware token that only wants a touch works. One that prompts for a PIN does not — there is nobody here to answer it, and the run fails rather than waiting.

**2. Declare a key that needs no passphrase.**

```yaml
servers:
  - ip_address: "203.0.113.10"
    ssh:
      user: root
      private_key_contents: "{{SSH_PRIVATE_KEY_CONTENTS}}"
```

Bondi writes the key to a mode-600 temporary file for the life of the run, hands it to `ssh`, and removes it afterwards.

**3. Declare an encrypted key and its passphrase.**

```yaml
servers:
  - ip_address: "203.0.113.10"
    ssh:
      user: root
      private_key_contents: "{{SSH_PRIVATE_KEY_CONTENTS}}"
      private_key_pass: "{{SSH_PRIVATE_KEY_PASS}}"
```

Bondi raises an `ssh-agent` of its own for the run, loads the key into it with the passphrase, uses it, and tears the agent down. The key stays encrypted on disk — the decrypted form exists only inside that agent and is never written anywhere. This shape needs `ssh-agent` and `ssh-add` on the machine running Bondi; if either is missing, Bondi says so and runs no command rather than dialling and failing.

`private_key_contents` accepts the key base64-encoded or verbatim, and reads either without being told which. Which of the two you may use depends on how the key reaches the file.

**Through a `{{...}}` template variable, base64-encode it.** The substitution is made over the YAML *text* before it is parsed, so a multi-line PEM dropped into the quoted scalar `private_key_contents: "{{SSH_PRIVATE_KEY_CONTENTS}}"` is folded by YAML onto one line: every newline becomes a space, the armour runs into the body, and what arrives is no longer a key. Base64 is a single line and has nothing to fold.

**Verbatim only as a block scalar written into the manifest itself**, where YAML keeps the newlines:

```yaml
        private_key_contents: |
          -----BEGIN OPENSSH PRIVATE KEY-----
          b3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jdHIAAAAGYmNyeXB0AAAA...
          -----END OPENSSH PRIVATE KEY-----
```

**Where a key is declared, Bondi offers that key and no other.** It passes `IdentitiesOnly=yes`, so a declared key that cannot sign fails as a declared key rather than quietly succeeding through whatever your agent happens to be holding. If you have been declaring a placeholder key while really relying on your own agent, that will now fail: remove both key fields, which is shape 1 above and is what you meant.

**An encrypted key with an empty `private_key_pass` is refused before anything is dialled.** An OpenSSH key file states its own cipher in cleartext, so Bondi can tell that the key cannot sign without a passphrase, and it stops there — naming the server, both fields and the cipher. Left to the connection, `ssh` would offer the key, the host would accept it, and the signature that never arrives would be reported as the *host's* authorization failure, which is someone else's verdict on a fault that is entirely local.

The `{{...}}` syntax in the examples above is a template variable — Bondi replaces it with the value of the corresponding environment variable at runtime. This keeps secrets out of the config file. Export the variables before running any Bondi command:

```bash
export SSH_PRIVATE_KEY_CONTENTS="$(base64 -w0 < ~/.ssh/my_server_key)"
export SSH_PRIVATE_KEY_PASS="my-key-passphrase"
```

Note that the substitution is made over the whole file before it is parsed, commented-out lines included: a `{{VAR}}` you have commented out still has to be exported.

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
```

```bash
export REGISTRY_USER="my-github-username"
export REGISTRY_PASS="ghp_xxxxxxxxxxxxxxxxxxxx"
```

Bondi uses these credentials to `docker pull` the image on the server. For GitHub Container Registry, use a personal access token with `read:packages` scope as the password.

### Persistent data (volumes)

Every deploy replaces the service's container, so anything the service writes inside it is lost at the next deploy. To keep it, mount a host directory into the container with `volumes`:

```yaml
service:
  name: my-api
  image: ghcr.io/acme/my-api
  port: 8080
  env_vars:
    ENV: "production"
  volumes:
    - host: /srv/my-api/uploads
      container: /app/uploads
      read_only: false
    - host: /srv/my-api/reference
      container: /app/reference
      read_only: true
  servers:
    - ip_address: "203.0.113.10"
      ssh:
        user: root
```

| Field | Required | Description |
|---|---|---|
| `host` | yes | Absolute path on the server. It must already exist when you deploy — see [Create the host directory first](#create-the-host-directory-first). |
| `container` | yes | Absolute path inside the container. It may not be `/`, and no two entries may use the same one. |
| `read_only` | yes | `true` to mount it read-only, `false` to let the container write to it. There is no default, because the choice changes what the container can do. |

Both paths must be absolute and normalised: no `.` or `..` segment, no doubled `/`, no trailing `/`, and no control characters. A path that breaks a rule, a missing field, or an unknown field refuses the whole `bondi.yaml` when it is read, before any server is contacted, and the error names the path or entry at fault:

```
Error reading configuration: invalid bondi.yaml: volume host path "srv/my-api/uploads" is not absolute: it must start with /
```

The mounts belong to the service's container only. Every container Bondi starts for the service gets the same mounts under both strategies. Cron job containers and managed containers get none.

#### Create the host directory first

Bondi never creates, chowns or chmods a host path. Before the first deploy that declares a volume, create each `host` directory on every server the service deploys to, owned by the user the container runs as:

```bash
sudo mkdir -p /srv/my-api/uploads && sudo chown 1000:1000 /srv/my-api/uploads
```

Replace `1000:1000` with the uid and gid your application runs as inside the container.

Bondi leaves this to you for three reasons. It cannot know which user the container runs as, because image metadata is often wrong. The owner of a directory is the host's policy, and the server may run other things besides your service. And a directory Bondi created for you would turn a typo such as `/srv/my-api/upload` into a silently empty directory, instead of a refused deploy.

#### A missing host path refuses the deploy

Before it sends a deploy, Bondi checks over SSH that every `host` path exists on each server. It tests each path as the SSH user, and then with `sudo -n`, because Docker checks the path as root. If the SSH user cannot see a path and the server refuses `sudo -n`, the path cannot be checked and the deploy is refused as unchecked, not reported missing. If a path is missing on any server, the deploy is refused before anything changes on any server, so the running container keeps serving. The error names the server and every missing path:

```
Error on server 203.0.113.10: the service mounts host paths that do not exist on the server: "/srv/my-api/uploads". Bondi does not create them: create each one, owned by the user the container runs as, then deploy again.
```

A check that could not run, for example because the server was not reached, refuses the deploy too. The error then says that the paths could not be checked, and why. It is never taken as a pass.

The check runs only when the deploy sends volumes. A deploy that names only cron jobs sends none, so it is not checked.

#### Blue-green: both containers mount the same directory

During a [blue-green](#blue-green) switch, the old container and the new one run side by side from the moment the new one starts until the old one has exited after its stop. For that whole time both mount the same host directory. This is intended. Bondi does no locking, and your application owns concurrent access to the data.

An SQLite database in a mounted directory is the classic hazard. For the length of the switch, two versions of your application have the same database open, and the new version may migrate a schema that the old one is still writing to. If your application cannot tolerate that, use the [simple strategy](#simple-default), which stops the old container before it starts the new one.

#### Removing a volume keeps the data

Removing an entry from `volumes`, or the whole field, unmounts it at the next deploy. The directory and everything in it stay on the server. Bondi does not delete host data when a volume is removed, when a blue-green deploy rolls back, or when a container is replaced. Delete the directory yourself when you no longer need it.

#### When a change takes effect

The mounts are part of the service's container, so a change to `volumes` takes effect at the next `bondi deploy` of the service, which is when the container is replaced. `bondi setup` does not touch the service's container and does not apply it.

Volumes need orchestrator `0.23.0` or later on the server. A deploy that declares volumes to an older orchestrator is refused before anything is sent, naming the version it needs. See [Before the first deploy after an upgrade](#before-the-first-deploy-after-an-upgrade).

### Set up the server

Once your `bondi.yaml` is ready and environment variables are exported, provision the server:

```bash
bondi setup
```

This will:

1. Connect to the server via SSH
2. Install Docker if it is not already installed
3. Create the ACME directory for TLS certificates
4. Copy the directory the server's cron jobs keep their run and secret files in out of the orchestrator onto the host, before that container is replaced — on a server set up before Bondi bind-mounted that directory the files live inside the container, and replacing it takes them with it while the crontab lines that read them keep firing. The copy is skipped when the orchestrator already bind-mounts that directory: the files are then already on the host, so there is nothing to rescue, and copying a bind-mounted path into itself would truncate the very files it was meant to save. Any job whose files did not survive is named in the report the run prints, one sentence per job, without printing the files
5. Pull the bondi-orchestrator image, then run the container unless one with the same image and configuration is already running. A pull that fails leaves the running orchestrator as it was, and the run fails with a message naming the image. An unchanged orchestrator is left running, on a host with cron jobs too, so a job running inside it is not killed. The same holds for Alloy, whose configuration includes its River configuration and credentials file. The first `setup` run by this version of Bondi recreates both once, because containers an older `setup` created carry no record of the configuration they were created with
6. Read back the restart policy the server actually applied to the orchestrator, and correct it in place if it is not `unless-stopped`
7. Wait for every container that declares a healthcheck to pass it
8. Print the same table `bondi status` prints, describing the server as the run left it

You only need to run `bondi setup` once per server, or again when you change the `bondi_server.version` or add features that require server-side changes (like Alloy).

#### What setup reports when it finishes

The table is reached on every exit path, including a run that aborted part-way through. A run that stopped early still prints what it managed on its way there, then the failure, then the state of the box — so "which phases did not run" and "what is actually on the server now" are both answered instead of the second being left to a manual check. See [Checking status](#checking-status) for how to read the table.

Between the failure and the table, the run prints its account of what it corrected on each server: one line per divergence, naming the server, what the server reported and what Bondi applied. A run that corrected nothing says so in a sentence of its own —

```
setup corrected nothing on server 203.0.113.10
```

— so a run whose account was empty and a run whose account was never taken do not read alike. The sentence claims nothing about why it was empty: a run that found a divergence and failed before it could correct it prints the same sentence, beside the failure that says what happened. The account is printed for every server and on every exit path, including a run that stopped part-way — what such a run managed to change is exactly when it matters most — and it changes no exit code, because a correction is a write that succeeded.

Three divergences can appear there today. One is the orchestrator's restart policy, described below. Another is the mode of the Alloy configuration file, which `setup` reads before it changes anything about the file, so that the mode the server had is reported rather than the one `setup` just set. When Alloy is replaced, the file is read and then rewritten. When an unchanged Alloy is left running, the configuration file and the credentials file (`/etc/bondi/alloy/env`, mode `0600`) are left as they are and only their modes are corrected, in place, if they differ. If either file is missing, Alloy is replaced instead:

```
/etc/bondi/alloy/config.alloy on server 203.0.113.10 was mode 0644, applied 0640
```

The third is the server's journal storage, when `setup` had to make it persistent before starting Alloy (see [The server's journal must be persistent](#the-servers-journal-must-be-persistent)). Its "was" is Bondi's own word for what the check found, not text the server returned:

```
/var/log/journal on server 203.0.113.10 was storage volatile, applied persistent
```

A reading `setup` could not take at all is reported in the same block, as a line of its own. It corrects nothing and it claims no value — it says only what could not be read — so a run that was unable to look does not read like a run that looked and found agreement:

```
could not read the mode of /etc/bondi/alloy/config.alloy on server 203.0.113.10, so this run cannot say what it found: the host could not read it and answered BONDI_ALLOY_MODE_UNREADABLE
```

A run whose account holds only lines of that kind still says it corrected nothing, because it did, and it still exits zero: that reading is taken for the account's sake, and the write is what the run is judged on.

The account is meant to be safe to paste into a ticket, and it is worth knowing exactly how far that goes. The file or the container a line names is one of Bondi's own constants, picked from the reading itself — there is no parameter for it, so nothing out of your `bondi.yaml` can arrive there at all. The value reported as what the server had is the server's own answer, flattened onto one line and, if it is long, cut with a note of how many bytes there were. The value reported as what Bondi applied is the value Bondi declares for itself. Beyond those three, nothing is enforced: these lines are built from ordinary strings, and a reading added later could carry a declared value into one. None of the readings above does, which is a fact about them rather than something the format prevents.

#### Restart policy

Docker's default restart policy is `no`: the container is neither started when the daemon starts nor restarted when its process dies. A host reboot, a `docker-ce` upgrade or a daemon crash therefore takes the container down and leaves it down until somebody notices.

Bondi gives every container it starts on its own initiative the `unless-stopped` policy — the orchestrator, the Traefik reverse proxy, the Alloy sidecar and your deployed service under both strategies. `unless-stopped` brings the container back whenever the daemon starts, unless you stopped it yourself with `docker stop`: a container you deliberately stopped stays stopped across a reboot.

Two kinds of container are exempt, both deliberately:

- **Cron job containers get no restart policy at all.** A scheduled run is a one-shot job whose exit code is the result. A policy would restart a finished job forever.
- **Managed containers use the policy you declared.** The `restart` field on a managed container is yours; Bondi neither overrides it nor supplies a fallback you did not ask for.

There is no setting for the policy on the orchestrator, the reverse proxy or your service, and no environment variable for it. The only thing a knob there could do is set it wrong.

`setup` does not treat the flag on a `docker run` as evidence that the flag took. On every run it reads back what the server applied to the orchestrator. If that differs, it corrects it in place with `docker update` — the orchestrator is not stopped, removed or re-run, so no site on the box loses TLS while a flag changes — and says so in the account it prints at the end of the run:

```
bondi-orchestrator on server 203.0.113.10 was restart policy no, applied unless-stopped
```

It then reads the policy a second time, because a server accepting the correction is not the same fact as a server having applied it. If the second read still disagrees, **the run exits non-zero**:

```
Error: bondi-orchestrator restart policy on server 203.0.113.10 is still no after asking for unless-stopped -- refusing to report success on a posture that was not applied
```

This is what converges a server that predates the behaviour: run `bondi setup` again and a container created without a policy is corrected where it stands, with no downtime and nothing to do by hand. The read-back is skipped only when Docker is not yet installed on the server, since in that case `setup` has just installed it and created the orchestrator in the same run.

The Traefik reverse proxy is handled on the server rather than over SSH: every `bondi deploy` of a service reads the policy Traefik is actually running with and corrects it in place if it differs, without redeploying it. The read happens before the service moves and outside the choice of deployment strategy, so a blue-green box converges its proxy exactly as a simple one does.

Two kinds of deploy do not reach it. A cron-only deploy declares no service and leaves the proxy alone, as it always has. A `bondi.yaml` that no longer declares `traefik_image`, `traefik_domain_name` and `traefik_acme_email` converges no proxy either — Bondi corrects the reverse proxy it is asked to run, not one it is told nothing about. Declaring them again corrects the box on the next deploy.

#### Waiting for health

After the plan has converged, `setup` reads the containers the server is running and waits on each one whose image declares a healthcheck. Containers the server says have no check are not waited on.

Each wait is bounded at **120 seconds**, per container, measured against the server's own clock. The loop runs on the server, so the bound costs one round-trip rather than one per attempt. It ends early as soon as the container passes, or as soon as it stops running — a container that has already died will not start passing. Only containers that are running when the report is taken are waited on: a cron job's container sits stopped between its runs, and there is nothing there for a wait to observe.

A container that does not pass inside the bound is named in the `HEALTH` column and **the run exits non-zero**:

```
Service
  NAME                   SOURCE  IMAGE                            TAG          STATUS        RESTARTS  HEALTH
  my-api                 docker  ghcr.io/acme/my-api              v2.0.0       running       0         did not pass its healthcheck within 120s
```

The other cells a wait can produce are `unhealthy: failing streak N`, `stopped before it passed its healthcheck`, and `health could not be read: …`. All of them fail the run; `healthy` and `no healthcheck defined` do not.

The bound is not tunable from `bondi.yaml`. It is a ceiling on how long a slow-but-healthy component is allowed, not an expected wait — `service.health_timeout` is a different setting and bounds a blue-green deployment, not `setup`.

Note that `bondi status` never waits. It reports whatever health state the server holds at the moment it is asked; waiting is `setup`'s behaviour alone.

### Deploy

Deploy your service by specifying the name and tag:

```bash
bondi deploy my-api:v1.0.0
```

The name (`my-api`) must match `service.name` in your config. The tag (`v1.0.0`) is appended to `service.image` to form the full image reference (`ghcr.io/acme/my-api:v1.0.0`).

Bondi sends the deployment to the orchestrator running on the server, which:

1. Pulls the image (a failed pull leaves the old container running)
2. Stops the old container (if any)
3. Starts the new container with Traefik labels for automatic HTTPS routing

### Check the status

After deploying, verify everything is running:

```bash
bondi status
```

This shows a table with your service, cron jobs, infrastructure components (orchestrator, Traefik), and their current state — read from the server over SSH, and from the orchestrator over that same connection by running its own `status` subcommand inside its container, with each source's account kept separate. See [Checking status](#checking-status) for the columns.

---

## 2. Deployment Strategies

### Simple (default)

The simple strategy is the default. It pulls the new image first, so a failed pull leaves the old container running, then stops the old container and starts the new one. There is a brief period of downtime during the switch.

Set `deployment_strategy: simple` to use it whatever the image declares. If you omit `deployment_strategy`, Bondi chooses for you after it pulls the image: blue-green when the image's `HEALTHCHECK` runs a command (`CMD` or `CMD-SHELL`), simple otherwise. An image with no `HEALTHCHECK`, or with `HEALTHCHECK NONE`, is deployed with simple.

### Blue-Green

Blue-green deployments avoid the stop-then-start gap of the simple strategy. Bondi starts the new container alongside the old one and waits for it to pass its health check. It then gives Traefik a moment to route to the new container, and stops the old one while it is still on Traefik's network.

> **Important:** Your Docker image must define a `HEALTHCHECK` instruction. Blue-green deployments rely on Docker's health check to decide when the new container is ready. If you set `deployment_strategy: blue-green` for an image without one, the new container never reports `healthy`, so the deploy fails and rolls back once `health_timeout` has passed. Until then Traefik sends it a share of your traffic, because Traefik routes to a container that reports no health status.

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
```

Deploy exactly the same way:

```bash
bondi deploy my-api:v2.0.0
```

What happens under the hood:

1. A temporary container (`my-api-new`) is started with the new image, on the same network as the old one, so Traefik routes to both
2. Bondi polls Docker's health check until the container reports `healthy` (or the timeout is reached)
3. Bondi waits 3 seconds, so that Traefik, which applies container changes at most every 2 seconds, is routing to the new container before the old one stops
4. The old container is stopped and removed. It stays attached to the network until it exits, so it can still resolve names and reach its database while it shuts down. Traefik stops routing to it when it exits
5. The new container is renamed to `my-api`

Your application should stop accepting new connections when it receives `SIGTERM`, finish the requests it holds, and exit. A request the old container refuses while it shuts down is retried against the new one; see [Retried requests](#retried-requests).

The switch is not lossless. In Bondi's release checks, a steady 50 requests a second through a switch lost 3 to 6 requests in each run of 825 to 875. Those are requests sent to the old container in the moment between its exit and Traefik dropping it.

If the health check fails or the timeout is reached, Bondi **automatically rolls back**: the new container is stopped and removed, the deploy exits non-zero, and the old container continues serving traffic, untouched. On a first deploy, with no old container, the rollback removes the container the deploy started, so a failed first deploy leaves nothing of the service behind. If the rollback itself fails, the error reports both failures.

If a deploy fails after the new container passed its health check, for example while the old one was being stopped, `my-api-new` can be left as the container serving your traffic. The next deploy recognises a running, healthy `my-api-new` on Traefik's network as live. It does not remove it: it first completes the interrupted switch (stops any old `my-api`, renames `my-api-new` to `my-api`), and only after the new image has been pulled. A `my-api-new` that is stopped, unhealthy or off the network is left over from a failed deploy and is removed.

#### Tuning blue-green deployments

Two optional fields let you adjust the behavior:

```yaml
service:
  name: my-api
  image: ghcr.io/acme/my-api
  port: 8080
  deployment_strategy: blue-green
  health_timeout: 120       # seconds to wait for healthy (default: 120)
  poll_interval: 1          # seconds between health checks (default: 1)
```

| Field | Default | Description |
|---|---|---|
| `health_timeout` | `120` | Maximum seconds to wait for the new container to become healthy. If exceeded, Bondi rolls back. |
| `poll_interval` | `1` | Seconds between health check polls. |

> **Retired:** `drain_grace_period` no longer has any effect. Bondi used to detach the old container from the network and wait this many seconds before stopping it. Detaching it did not take it out of Traefik's routing, and it cut the container off from DNS and its database while it was still serving. The old container is now stopped while still attached, after the fixed 3-second wait described above, which is not configurable. A `bondi.yaml` that still sets the field is ignored for now: `bondi deploy` prints a warning saying so. A later release will refuse the field instead, so remove it from your `bondi.yaml`.

### Retried requests

Every service's Traefik router, under either strategy, uses a retry middleware that Bondi declares on the service's container as `<service name>-retry`. It allows up to 4 attempts and retries at once, with no backoff. When the container Traefik picked refuses the connection, as an old container that has stopped listening does during a switch, Traefik retries the request, and the retry reaches the new container when one is serving. Bondi-created Traefik gives up on a backend that does not answer after a 1 second dial timeout, so each attempt is quick.

This reduces the loss during a switch; it does not remove it. Measured with Traefik v3.6.8 on Docker Engine 29.10.0, 0.12% of requests failed during swaps (10 of 8355 over 10 runs). A request that used all its attempts failed after about 4 seconds with a `504`. Requests that a retry rescued were typically answered in about 1 second, and at most about 3 seconds.

Traefik does not resend a request that reached your application. A request your application read, in whole or in part, and then failed to answer is returned to the client as an error (`502`), not delivered a second time. An upload cut off by a switch therefore either completes or fails visibly. It never reaches your application truncated.

Bondi writes the router's labels itself. An image that declares `traefik.http.routers.<service name>.middlewares` among its own labels is refused: the deploy fails before anything is stopped, and the error names the label and the image. Bondi's label would otherwise replace the image's without a word. Remove the label from the image and deploy again. Other router keys an image declares that Bondi also writes (`rule`, `entrypoints`, `tls`, `tls.certresolver`, the service port, and the `-retry` middleware keys) are not refused: Bondi's labels override them.

### Old images

After a deploy, Bondi removes the local images it no longer needs, whichever strategy you use and for cron-only deploys too. It removes an image only when all of these hold:

- it belongs to a repository the deploy declares (your service image or a cron job's image), and
- the deploy does not declare its exact tag, and
- no container, running or stopped, uses it.

Bondi never removes an image from another repository, an image a container still uses, or an image the deploy declares. A removal that Docker refuses does not fail the deploy.

> **Note:** Every unused local image of a declared repository is removed, including one you pulled by hand to roll back to. To keep one, run a container from it, or redeploy that tag with `bondi deploy`.

Cleanup can only warn. Two lines appear in the orchestrator's log, which you read with `docker logs bondi-orchestrator`:

- `image cleanup: kept image <id> because a container uses it` (an image was left in place)
- `image cleanup warning: could not read the host's images and containers, so none were removed: <reason>` (nothing was removed this time; the next deploy tries again)

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
```

Key differences from services:

- Each cron job has exactly **one server** (not a list)
- The `schedule` field is the five time fields of a crontab line, in the narrower form described under [Schedules](#schedules)
- Cron jobs are deployed with the same `bondi deploy` command, by name and tag

The name, the schedule and any secret entries are checked when `bondi.yaml` is read, before any server is contacted, and the server checks them again when the deploy arrives. A refusal names the job, so a manifest declaring several says which one to fix.

### Schedules

A job's `schedule` is written into the server's root crontab, so it is parsed before it is written. It is five fields, separated by one or more spaces or tabs, with nothing before the first or after the last:

| Field | Range |
|---|---|
| minute | 0-59 |
| hour | 0-23 |
| day of month | 1-31 |
| month | 1-12 |
| day of week | 0-7 (0 and 7 are both Sunday) |

Each field is a comma-separated list of one or more items, and an item is one of:

- `*`, every value of the field;
- a number inside the field's range;
- a range `a-b` of two numbers inside the field's range, with `a` no greater than `b`;
- `*` or a range followed by `/step`, every step-th value of it, where the step is from 1 to the field's largest value.

So `0 2 * * *`, `*/15 * * * *`, `1-9/2 * * * *` and `30 4 1,15 * 5` are accepted.

This is narrower than what some cron daemons read. Bondi accepts the forms that both Debian's `cron` and `cronie` document with the same meaning, so a schedule means the same thing whichever one the server runs. Refused, even where your daemon would read them:

- month and day names (`jan`, `mon`);
- `@` nicknames (`@daily`, `@reboot`);
- `~` random ranges (`6~15`);
- a step after a bare number (`0/35`);
- 0 as a day of month or a month.

An empty schedule, one with more or fewer than five fields, and one holding a control character — a newline, which would start a second crontab line, included — are refused too:

```
Error reading configuration: invalid bondi.yaml: cron job "nightly" schedule "0 2 * jan *": the month "jan" is not a number from 1 to 12
```

### Names a cron job cannot take

A job's container is named after the job, in the same namespace as every other container on the server. So a job cannot take a name already in use by:

- the service, or its blue-green candidate, `<service>-new`;
- one of Bondi's own containers: `bondi-orchestrator`, `bondi-traefik` or `bondi-alloy`;
- a managed container, under its container name `bondi-<name>`;
- another cron job.

Every clash among the names is named, with what holds the name, so one edit fixes them all. The checks run in order and the first to refuse reports: a schedule outside the grammar, then a name that is not safe in a file path, then name clashes, then secret entries. A manifest with several kinds of fault may need one edit per kind:

```
Error reading configuration: cron jobs cannot take names already in use (cron job "web" cannot take that name: the service "web" already runs under it, and a cron job's container is named after the job): rename these jobs in bondi.yaml
```

The server checks again when the deploy arrives, against the managed containers already running on it as well as the names in the deploy.

### A container under the job's name when it runs

A job's container takes the job's name when a run finishes, replacing the previous run's. Before each run Bondi reads the name, and again when the run finishes. A container under it that carries both `bondi.type=cron` and `bondi.name=<job>` is the job's own. Anything else, such as a container started by hand, is left alone. Bondi does not remove it, rename it or start over it, and the run fails with exit code 1, is mailed by cron, and alerts the job's failure sinks as a run that never started:

```
refusing to run cron job nightly: the container named nightly was not made by this job: it does not carry both bondi.type=cron and bondi.name=nightly, so it was left untouched
```

If the container appears while a run is in progress, the run has already happened. The refusal then reads `cron job nightly finished, but the container named nightly was not made by this job: ...`, and the run's own container keeps its temporary name, `nightly-` and a timestamp, until you clear the clash. To fix either, rename or remove the other container (`docker rename`), or give the job another name in `bondi.yaml` and deploy again.

### Secrets

Values under a job's `secret_env_vars` are written to a mode-`600` file under `/etc/bondi/cron/<name>/` on the server rather than into the crontab line. That file is one `KEY=VALUE` per line, read back without unquoting, so the rule managed containers' secrets follow applies here too: a key must be non-empty and hold no `=` and no control character, and a value must hold no control character, newline included. A newline in a value would cut it short and turn its tail into a variable nobody wrote. A multi-line credential cannot be passed this way.

A refused entry is named by job and key, never by its value:

```
Error reading configuration: cron job secret entries cannot be written to an env file (job "nightly" has a control character in the value of "API_TOKEN"). A key must be non-empty and hold no "=" and no control character, and a value must hold no control character, newline included: fix these entries in bondi.yaml
```

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
```

### When a run fails

Bondi reports a failed run through two independent channels.

The first is cron itself. The crontab line Bondi writes is a `docker exec` into the orchestrator, and `docker exec` exits with the status of the command it ran — so a run the orchestrator cannot start, or a payload it rejects, is a non-zero line. The failure lands in cron's own record and in the mail cron sends to the account owning the crontab, and the server's explanation goes with it rather than being swallowed:

```
Run failed: invalid run payload: Run.run_payload (keys received: job, imag)
```

This channel needs no configuration and is the only one that works when the failure happens before the server can know which job it was — an orchestrator that is not running, or a payload it cannot decode. A rejected body is reported by the keys that arrived, never by their values, so an environment variable or a sink URL carrying a credential is not echoed into your mail spool.

The second channel is alerting, below, which needs sinks configured and fires once the server knows which job ran.

`bondi deploy` rewrites only the crontab lines of the jobs it names, so a line written by an older Bondi survives untouched until you deploy that job again. If a job still fails silently, its line predates this behaviour — re-deploy that job once to replace it with the current shape.

### Lines in Bondi's crontab section that Bondi did not write

Bondi keeps its cron entries between a `BEGIN`/`END` marker pair in the server's crontab. Everything between those markers is Bondi's, and Bondi does not throw any of it away: a line in there that Bondi did not write is carried through every deploy that rewrites the section, verbatim.

It is also reported, on every `bondi status`. The `Crontab` row counts the entry and locates it — `2 jobs (daily-close, entry 2 could not be read)` — where positions count entries from the first one inside the markers. The line itself is never printed, in the table or in `--output json`: an entry in that section may carry a credential, and status output leaves the box and is shipped off it with the logs.

Nothing clears that report except removing the line. There is no Bondi command that does it, because a line Bondi cannot read is a line Bondi cannot safely decide about — so edit the crontab on the server by hand:

```bash
ssh YOUR_USER@YOUR_SERVER -- crontab -e
```

Delete the offending entry from between the markers and save; the next `bondi status` is clean. Cron entries of your own belong **outside** the markers, where Bondi neither rewrites nor counts them.

That is the remedy for a line Bondi cannot read. If `bondi status` reports `markers malformed: …` instead, the defect is in the markers themselves rather than in what sits between them, deleting entries does not clear it, and a deploy of any job with cron jobs is refused until it is fixed — see the `Crontab` row under `bondi status` below.

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
```

- Only `failure` and `critical` take sinks — `success` never alerts.
- A severity with no configured sink emits nothing; there is no implied fallback target.
- **Sink URLs must use `https://`.** A plaintext `http://` or unparseable URL is rejected when `bondi.yaml` is read, not at deploy time.
- Sink URLs often embed credentials (webhook tokens, routing keys). Treat them like `env_vars` secrets and supply them through `{{...}}` template variables rather than hard-coding them.

Bondi POSTs one generic JSON payload per alert, carrying the job name, severity, exit code, and timestamp — nothing sink-specific and no secret material. A consumer that needs a different shape adapts on its own ingest side.

Delivery is best-effort and runs after the run's outcome is recorded: a sink that is down, slow, or erroring never changes that outcome or crashes the orchestrator. Each attempt is bounded by a short timeout, so a slow sink can at most delay the moment the run's own exit code is reported. Every delivery failure — a transport error, a timeout, or a non-2xx response from the sink — is logged (by host only, so a credential-bearing URL is not written to the logs).

Both fields ride in the job's run payload alongside `env_vars` — the file the crontab line points at, written at deploy time — so run `bondi setup` after adding them (the orchestrator picks up the new config), then deploy the cron job as usual.

---

## 4. Alloy (Grafana Cloud Logs)

Bondi can ship container logs to Grafana Cloud using [Grafana Alloy](https://grafana.com/docs/alloy/latest/). Alloy runs as a sidecar container on the server, discovers Bondi-managed containers via the Docker socket, and forwards their logs to Loki. It lists containers every 5 s, so a container that runs past about 15 s is read even if it's gone within a minute; one that exits sooner may still be missed. Cron job containers are the exception: their lines are read from the server's systemd journal instead, so a run that lasts under a second still ships. See [Cron job logs come from the host journal](#cron-job-logs-come-from-the-host-journal).

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

This writes the Alloy configuration to `/etc/bondi/alloy/config.alloy` on the server and starts the `bondi-alloy` container. Before it starts the container, it makes sure the server's journal is stored persistently under `/var/log/journal`, and provisions that storage if it is not. See [The server's journal must be persistent](#the-servers-journal-must-be-persistent).

### Optional settings

```yaml
alloy:
  grafana_cloud:
    instance_id: "{{GRAFANA_INSTANCE_ID}}"
    api_key: "{{GRAFANA_API_KEY}}"
    endpoint: "https://logs-prod-us-central1.grafana.net/loki/api/v1/push"
    max_backoff_retries: 0        # retries per batch; 0 retries indefinitely (default: Alloy's, 10)
  image: grafana/alloy:v1.8.0    # pin a specific version (default: grafana/alloy:v1.8.0)
  collect: all                    # "all" or "services_only" (default: all)
  labels:                         # extra labels attached to every log line
    env: production
    team: platform
```

| Field | Default | Description |
|---|---|---|
| `grafana_cloud.max_backoff_retries` | _(Alloy's, 10)_ | How many times Alloy retries a batch Loki did not accept before it drops the batch's lines. With Alloy's default of 10, a Loki or network outage longer than about 8.5 minutes loses lines. `0` retries indefinitely. A negative value, or anything that is not a whole number, is refused when `bondi.yaml` is read. Changing it changes Alloy's configuration, so the next `bondi setup` restarts Alloy. |
| `image` | `grafana/alloy:v1.8.0` | Alloy Docker image. Override to pin or upgrade. |
| `collect` | `all` | `all` collects logs from every Bondi-managed container (service, cron, managed containers, infrastructure) that is not opted out. `services_only` restricts to service and cron containers, excluding managed containers and infrastructure like the orchestrator and Traefik. Before `0.24.1`, `services_only` shipped nothing at all; see [Upgrading to 0.24.1](#upgrading-to-0241). From `0.25.0`, cron containers ship from the systemd journal; see [Upgrading to 0.25.0](#upgrading-to-0250). |
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

The service's container is then labelled `bondi.logs=false`, and a container carrying that label ships nothing under either `collect` mode. `bondi setup` also excludes the service by name (any container whose name contains it), so its logs stay out of Loki even before its next deploy has put the label on the container. The `bondi-alloy` sidecar carries the same label, so Alloy does not ship its own logs.

### Finding a container's logs in Loki

Every line Bondi ships carries a `container` label naming the workload it came from:

| Container | `container` value |
|---|---|
| Your service | the service's `name` |
| A cron job | the job's `name` |
| A managed container | its `name` in `managed_containers` (`gateway`, not `bondi-gateway`) |
| Infrastructure | the container's name: `bondi-orchestrator`, `bondi-traefik` |

Query by it in Grafana's Explore view or any LogQL client:

```logql
{container="my-api"}
{container="daily-backup"} |= "error"
```

The value stays the same from one run to the next, so one workload is one stream, provided names differ across services, cron jobs and managed containers: two workloads sharing a name share one stream. A cron job's container runs under a name with a timestamp in it, and a blue-green deploy starts the incoming service under a temporary name; both carry a `bondi.name` label holding the workload's name, and that label is what `container` is read from. A container started before it carried `bondi.name` is labelled with its container name instead, so it is never unlabelled. For a service that is its name already; for a cron job, every run after the upgrade carries the label.

### Cron job logs come from the host journal

A cron job's container can finish in under a second. Alloy's Docker discovery lists only running containers, every 5 s, so a container that runs past about 15 s is read even if it's gone within a minute; one that exits sooner may still be missed, so a short cron run could be missed entirely. So the orchestrator starts every cron job container with Docker's `journald` logging driver, and Alloy reads cron lines from the server's systemd journal. Service, managed and infrastructure containers are still read through the Docker socket, exactly as before.

- **Every line a cron run writes reaches Loki once**, however short the run. Alloy's Docker discovery skips cron containers under both `collect` modes, so a run it happens to list is not shipped a second time.
- **A cron stream carries the same labels as before:** `container` (the job's name, as in the table above), the `service_name` Loki derives from it, and the `labels` you declare. Queries such as `{container="daily-backup"}` keep working.
- **Only cron entries leave the server.** Alloy mounts `/var/log/journal` read-only, and that journal holds the rest of the host's logs too. Alloy reads only the entries that carry both `bondi.managed=true` and `bondi.type=cron`. The name exclusion `bondi setup` adds for a service with `logs: false` applies to cron lines as it always has.
- **Lines logged while Alloy is down are shipped when it returns.** `bondi setup` replaces the Alloy container when its image or configuration has changed, and leaves an unchanged one running. Alloy keeps its place in the journal in `/var/lib/bondi/alloy` on the server, which setup creates and every Alloy container mounts, so the next container picks up where the last one stopped. A line logged in between ships as long as the journal still holds it, and a line already shipped is not sent again.
- **`docker logs` still shows a cron run's output.** Docker keeps a local copy of a container's output whatever its logging driver ([dual logging](https://docs.docker.com/engine/logging/dual-logging/)), unless the daemon's `log-opts` set `"cache-disabled": "true"`. A cron container's name carries a timestamp, so find it with `docker ps -a`.

#### The server's journal must be persistent

journald writes its journal under `/var/log/journal` only when it stores persistently. Otherwise it keeps it in memory, and an Alloy reading `/var/log/journal` would read nothing and say nothing. So whenever an `alloy` block is declared, `bondi setup` checks the server's journal before it touches Alloy. It looks for `/var/log/journal/<machine-id>`, the directory journald writes for this machine. The bare `/var/log/journal` is not enough, because with `Storage=volatile` it can exist and stay empty.

If that directory is missing, setup provisions persistent storage. It creates `/var/log/journal`, runs `systemd-tmpfiles --create --prefix /var/log/journal` to give it journald's ownership and mode, and restarts `systemd-journald`. Then it checks again. The change is listed in the report setup prints at the end, with the other divergences it corrected:

```
/var/log/journal on server 203.0.113.10 was storage volatile, applied persistent
```

If the journal is still missing after that, setup stops before it starts Alloy:

```
Error: journald still stores nothing under /var/log/journal for this machine after setup created the directory and restarted it. Alloy reads cron jobs' lines from that journal, so setup will not start an Alloy that reads nothing. Check Storage= in /etc/systemd/journald.conf and its drop-ins: volatile and none keep the journal out of /var/log/journal. Set it to persistent or auto, then run bondi setup again.
```

The server therefore needs systemd's journald. Debian and Ubuntu have it.

#### Upgrading to 0.25.0

This change has two halves, and they ship in different places. The orchestrator starts each cron container with the `journald` driver. The CLI generates the Alloy configuration that `bondi setup` writes, which reads the journal and drops cron containers from the Docker path. Neither half works without the other, and there is no compatibility mode between them. With a new CLI and an older orchestrator, cron containers never reach the journal, and Alloy no longer ships them from Docker, so cron jobs ship nothing at all. `bondi setup` therefore refuses, while alloy is declared, when `bondi_server.version` is below 0.25.0, and names the version to pin.

Move both to `0.25.0` or later in one go:

1. Upgrade the `bondi` CLI to `0.25.0` or later.
2. Set `bondi_server.version` in `bondi.yaml` to `0.25.0` or later.
3. Run `bondi setup`. It replaces the orchestrator, checks the journal, rewrites `/etc/bondi/alloy/config.alloy` and replaces the `bondi-alloy` container.

No cron job needs a redeploy. Each scheduled run is started by the orchestrator, so the first run after setup already logs to the journal.

### Upgrading to 0.24.1

Before `0.24.1`, the generated Alloy configuration read the `bondi.type` and `bondi.logs` labels under names Alloy's Docker discovery never produces, so neither rule ever matched:

- **`collect: services_only` shipped nothing.** It now ships your service and cron jobs, as documented above.
- **The `bondi.logs=false` label was ignored.** A service with `logs: false` was kept out only by the name exclusion `bondi setup` adds for it. The label is now honoured as well, under either mode, and under `collect: all` the `bondi-alloy` sidecar's own logs stop shipping.
- **Lines carried no `container` label.** They now do, as described above.

The Alloy configuration is written by `bondi setup`, not by `bondi deploy`, so a deploy alone changes none of this. To adopt it:

1. Upgrade the `bondi` CLI to `0.24.1` or later. The CLI generates the configuration that `setup` writes to the server, so this is the step that fixes the filters.
2. Set `bondi_server.version` to `0.24.1` or later. The orchestrator is what puts `bondi.name` on the cron and service containers it starts, so without it every cron run is a stream of its own.
3. Run `bondi setup`. It rewrites `/etc/bondi/alloy/config.alloy` and replaces the `bondi-alloy` container.

Your service needs no redeploy for its logs to start shipping or to carry `container`.

### Reading Alloy's counters

Alloy's HTTP server listens on the server's `127.0.0.1:12345` only. The `bondi-alloy` container shares the host's network, so nothing outside the server reaches that address, and neither do containers on Docker's bridge networks: each one's `127.0.0.1` is its own (a host-networked container shares the box's loopback). Read how many lines Alloy has sent and how many it has dropped from your machine, without entering the container:

```bash
ssh root@203.0.113.10 curl -s 127.0.0.1:12345/metrics | grep -E 'loki_write_(dropped|sent)_entries_total'
```

`loki_write_sent_entries_total` counts the lines Alloy sent to Loki. `loki_write_dropped_entries_total` counts the lines it dropped because they still failed after its last retry; see `max_backoff_retries` under [Optional settings](#optional-settings). Both count from when that Alloy container started, so a restart resets them.

Alloy's HTTP server also serves its reload endpoint and component API. Anyone with a shell on the server can reach them, as they can already reach the Docker socket.

After starting Alloy, `bondi setup` waits up to 30 s for it to answer healthy at that address. If it does not, setup fails:

```
Error: Alloy did not answer healthy at http://127.0.0.1:12345/-/healthy before setup gave up waiting. It may have exited at start: another process on the box may hold port 12345.
```

Alloy exits at start when it cannot listen on its port. Free port `12345` on the server and run `bondi setup` again. A server without `curl` fails the same step with a message that says so, because setup asks with the server's `curl`.

### Removing Alloy

To stop collecting logs, remove the `alloy` section from `bondi.yaml` and run `bondi setup` again. Bondi will stop and remove the Alloy container and clean up its configuration on the server. It leaves `/var/lib/bondi/alloy`, where Alloy kept its place in the journal, and the journal storage it provisioned.

If that run could not list the server's containers, it has nothing to remove the Alloy container *from* and passes over it — so a `bondi-alloy` can outlive the `alloy:` block that created it, still shipping logs with credentials your config no longer declares. It is not silent: the report `setup` prints at the end lists it in the Infrastructure section flagged `[undeclared]`, because the server is running a container nothing asks for. Check that flag after a withdrawal, and run `bondi setup` again to clear it.

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
| `image` | yes | Base image **without a tag**. A registry port works (`registry.example.com:5000/job`). A value that is not a valid image reference is refused when `bondi.yaml` is read. |
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
  NAME                   SOURCE  IMAGE                            TAG          STATUS        RESTARTS  HEALTH
  my-api                 both    ghcr.io/acme/my-api              v2.0.0       running       0         healthy

Cron Jobs
  NAME                   SOURCE  IMAGE                            TAG          STATUS        RESTARTS  HEALTH
  daily-close            docker  example.com/daily-close          1.0.0        exited        0         no healthcheck defined  [disagreement]
                         orch    example.com/daily-close          1.0.0        completed     0         -

Infrastructure
  NAME                   SOURCE  IMAGE                            TAG          STATUS        RESTARTS  HEALTH
  bondi-orchestrator     both    mlopez1506/bondi-server          0.10.3       running       0         no healthcheck defined
  bondi-traefik          both    traefik                          v3.6.8       running       0         no healthcheck defined
  bondi-alloy            both    grafana/alloy                    v1.8.0       running       0         no healthcheck defined
  bondi-gateway          both    ghcr.io/acme/ib-gateway          10.48.1e     running       0         healthy
  legacy-worker          docker  old/worker                       1.2          running       3         no healthcheck defined  [undeclared]

Crontab
  bondi section          docker  1 jobs (daily-close)
```

Managed containers appear in the Infrastructure section, discovered on the server by label. A container you have declared in `bondi.yaml` that neither source reports shows as `not found` — that usually means `bondi setup` has not been run since you added it.

#### The SOURCE column

The table is read from two places and they are never blended into one answer:

- **`docker`** — the containers on the server, read over SSH. This is ground truth about the box.
- **`orch`** — the orchestrator's own report, read over SSH by running its `status` subcommand inside its container. It holds what only the orchestrator knows, such as whether a cron job's last run `completed`.
- **`both`** — the two agree on image, tag and status, so they share one line. The restart count is not compared: a count read a second later legitimately differs.

Where the two disagree, the component gets one line per source and the row is flagged `[disagreement]`. That is the report's finding, not a defect in it — the two sources drifting apart is a state nothing else detects, so nothing is reconciled behind your back. Until `bondi setup` upgrades a server, a digest-pinned image on it can show a disagreement that is not real, because an older orchestrator splits a digest at its colon; the flag clears once the server is upgraded.

A source that could not be consulted says so in its own words rather than reporting an absence:

```
  my-api                 docker  not read: Missing ssh configuration for server 203.0.113.10
                         orch    not reachable: Missing ssh configuration for server 203.0.113.10
```

`not read` and `not reachable` mean the question was never answered — different from `not found`, which is a source answering that it does not have the component. A row where SSH could not be read but the orchestrator could is flagged `[unverified]`: it is the orchestrator's account with nothing to check it against.

`[undeclared]` marks a container one of the sources reports that no `bondi.yaml` entry asks for — a service renamed without the old one being removed, or an Alloy container left behind by a withdrawn `alloy:` block. Nothing removes it for you; the flag exists so it stops being invisible.

#### The HEALTH column

`HEALTH` replaces the old `CREATED` column and reports the container's own Docker healthcheck, never its liveness:

| Cell | Meaning |
| --- | --- |
| `healthy` | the container's healthcheck passed |
| `unhealthy` | it ran and failed |
| `starting` | inside its start period, no verdict yet |
| `no healthcheck defined` | the image declares none, so there is nothing to pass |
| `no health recorded` | it declares one, and Docker has no result yet |
| `could not be read: …` | the inspection failed — no claim about the container either way |

A container that is up is not a container that works, so `running` and `healthy` are separate facts and a run that could not read health never renders as healthy.

Bondi never adds a healthcheck of its own — it reports whichever one the image declares, so `no healthcheck defined` for `bondi-traefik` and `bondi-alloy` above is the upstream images saying nothing about their own health, not Bondi failing to ask. Adding a `HEALTHCHECK` to your service's own image is what makes `setup` wait for it.

#### The Crontab row

`setup` writes the cron entries it manages into a marked section of the server's crontab, and that file is a different fact from the `cron_jobs` you declared. The `Crontab` row reports what is actually in the section: a job count and the job names (`1 jobs (daily-close)`), `0 jobs`, `no Bondi section on the host`, `markers malformed: …` where the `BEGIN`/`END` markers are unbalanced, or `not read: …`.

Only counts, names and positions are ever printed. Crontab lines are never shown, in the table or in the JSON — a line written by an older Bondi carries the job's whole payload, environment variables and all, and status output leaves the box and is shipped off it with the logs.

`markers malformed: …` is not only a status row. A `bondi deploy` of a job that declares cron jobs against that server fails:

```
Deploy succeeded but crontab update failed: the Bondi section of the crontab is malformed: a begin marker opens a section the file never closes
```

The container deploy has already happened and the job's run and secret files are written, but the crontab is left exactly as it was — no line is added, changed or removed. A file whose markers do not balance has no unambiguous section to rewrite, and rewriting it on a guess is how a job ends up firing twice a schedule. The three sentences are distinct, so the message alone says which defect to look for: an end marker closing a section that was never opened, a begin marker opening a section the file never closes, or a begin marker opening a section inside one already open.

No Bondi command repairs it, and deleting entries does not: the defect is in the markers, not in what sits between them. Balance them by hand on the server:

```bash
ssh YOUR_USER@YOUR_SERVER -- crontab -e
```

Each `# BEGIN BONDI CRON` needs exactly one `# END BONDI CRON` after it, with no second `# BEGIN BONDI CRON` in between. Save, confirm with `bondi status` that the `Crontab` row reports a job count again, then re-run the deploy.

For machine-readable output:

```bash
bondi status --output json
```

Each row carries `declaration`, `disagreement`, `unverified`, and a separate `docker` and `orchestrator` object, so the provenance in the table is in the JSON too.

### Redeploying Traefik

If you change the Traefik configuration (e.g. update `acme_email`, `acme_ca_server` or the domain), redeploy Traefik without redeploying your service:

```bash
bondi deploy my-api:v2.0.0 --redeploy-traefik
```

The `--redeploy-traefik` flag forces Traefik to be stopped and restarted, even if the image version has not changed. Note that you still need to specify a service deploy target.

Every deploy of a service converges Traefik the same way, whichever deployment strategy it runs. Bondi's Traefik is the container named `bondi-traefik`; another container running a Traefik image is never taken for it, replaced or removed. A deploy creates Traefik when no `bondi-traefik` exists, and replaces it when `traefik.image` has changed or this flag is given. The new Traefik image is pulled before the running Traefik is stopped, so a pull that fails leaves the running one serving.

A changed `acme_email` or `acme_ca_server` takes effect only with this flag. A deploy without it keeps the running Traefik when the image version has not changed, and that Traefik goes on ordering certificates from the server it was started with.

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
  registry_user: "{{REGISTRY_USER}}"
  registry_pass: "{{REGISTRY_PASS}}"
  env_vars:
    ENV: "production"
    DATABASE_URL: "{{DATABASE_URL}}"
  volumes:
    - host: /srv/my-api/uploads
      container: /app/uploads
      read_only: false
  servers:
    - ip_address: "203.0.113.10"
      ssh:
        user: root

bondi_server:
  version: 0.0.0

traefik:
  domain_name: my-api.example.com
  image: traefik:v3.6.8
  acme_email: ops@example.com
  # Optional: order certificates from another ACME server. Omitted, Traefik
  # uses Let's Encrypt production. Let's Encrypt staging suits a test box:
  # acme_ca_server: https://acme-staging-v02.api.letsencrypt.org/directory

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

- **Volumes need orchestrator `0.23.0` or later, so run `bondi setup` first.** Before the first deploy that declares `service.volumes`, set `bondi_server.version` to `0.23.0` or later and run `bondi setup` on every server the service deploys to. A deploy that declares volumes to an older orchestrator is refused before anything is sent:

  ```
  Error on server 203.0.113.10: the server is running bondi-server 0.22.0, but the service declares volumes, which requires 0.23.0 or later. An older server does not know the field and refuses the whole deploy. Set bondi_server.version in bondi.yaml to 0.23.0 or later, run bondi setup, then deploy again.
  ```

  A deploy that declares no volumes is unaffected by this. Create each host directory before that first deploy too — see [Create the host directory first](#create-the-host-directory-first).

- **A service with no `deployment_strategy` whose image has a `HEALTHCHECK` moves to blue-green on its next deploy.** Two containers of the service run at once during the switch. If they share a volume or an SQLite database, read [Blue-green: both containers mount the same directory](#blue-green-both-containers-mount-the-same-directory) before that deploy, or set `deployment_strategy: simple`.

- **Images that declare `traefik.http.routers.<name>.middlewares` are refused.** Remove the label from the image; see [Retried requests](#retried-requests).

- **Traefik is found by name.** A Traefik container not named `bondi-traefik` is no longer adopted, and the deploy will try to create one, which likely fails on ports 80 and 443. Blue-green deploys also now replace Traefik when `traefik.image` changes.

- **Retries and the dial timeout reach existing setups in two steps.** Bondi-created Traefik now starts with a 1 second dial timeout to backends. An existing Traefik picks it up only through `--redeploy-traefik` or a Traefik image change. Service routers retry up to 4 attempts, applied at each service's next deploy. See [Retried requests](#retried-requests).

- **The first blue-green deploy of each service after upgrading from 0.28.0 or earlier is interrupted once, during the switch.** A service container started by 0.28.0 or earlier declares the service's Traefik router without the [retry middleware](#retried-requests), and the new container declares it with the middleware. While both are running, Traefik sees one router defined two different ways and serves neither, so requests to the service are answered `404` from the moment Traefik adds the healthy new container until the old one exits. Measured with Traefik v3.6.8, that was about 2.3 seconds. The cause goes away with that first deploy: from then on the running container declares the router with the middleware, as each new one does.

- Check that every cron job's `network` is either absent or exactly `bondi-network`, and the same for every managed container's `network`. Any other value now fails before anything is deployed instead of failing at run time — see [Reaching other containers from a cron job](#reaching-other-containers-from-a-cron-job).

- **Re-deploy every cron job once.** A deploy only rewrites the crontab lines for the jobs named in it; lines for other jobs are carried over from the existing crontab untouched. A job that is not re-deployed keeps its old command and stays silent when it fails, however new the orchestrator is. Name them all in one deploy:

  ```bash
  bondi deploy daily-backup:v1.0.0 nightly-report:v1.0.0
  ```

  This is also what applies the failure reporting described in [When a run fails](#when-a-run-fails) to jobs that predate the upgrade.
