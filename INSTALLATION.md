# Installing and upgrading Bondi

Written for a reader in a *consuming* repository who has none of this repo's
context. If you are about to run `bondi setup` or `bondi deploy`, or you are
waiting on a Bondi fix, read this first.

## A Bondi version lives in four places, and a release updates none of them automatically

| Where | What it is | How it updates |
|---|---|---|
| **The tap formula** | `puravida-software/homebrew-bondi`, `Formula/bondi.rb` | published with the release |
| **The workstation CLI** | the binary that actually runs `setup` / `deploy` | **manual** — see below |
| **The orchestrator image** | `mlopez1506/bondi-server:<version>` running on the host | applied by a `bondi setup` run |
| **`bondi_server.version`** | a field in each consuming repo's `bondi.yaml` | edited per repo, by hand |

Cutting a release moves the *tag*. It does not move any of the four. **A release
that updates only the tag is not deployed.**

## Which artifact does a given fix need?

This is the question that decides whether you need a CLI upgrade, a `setup` run,
or both — and getting it wrong wastes a convergence on a production host.

```bash
git show <sha> --stat -- lib/client/   # touched? -> the CLI needs upgrading
git show <sha> --stat -- lib/server/   # touched? -> the orchestrator image needs a setup run
```

- **`lib/client/` only** — upgrade the CLI. The orchestrator image is unaffected
  and needs no bump; do not bump `bondi_server.version` for it, because that is a
  spec change that will recreate containers for no reason.
- **`lib/server/`** — the fix is in the image. Bump `bondi_server.version` in the
  consuming `bondi.yaml` and run `setup`.
- **Both** — upgrade the CLI *first*, then run `setup` with the bumped version, so
  the run that touches the host is the fixed client.

Worked example, `v0.10.3` (the probe-failure fix): `git show 321580f
--name-only` touches `lib/client/cmd/setup.ml` and tests, and **zero** files
under `lib/server/`. So it is a CLI upgrade and nothing else.

## Installing the CLI

**Where Homebrew is unavailable**, the README's `brew install bondi` does not
apply — including the common case of a container or minimal image where
`/home/linuxbrew/.linuxbrew/bin` is on `PATH` but `brew` was never installed
there. Install the binary manually instead:

```bash
VERSION=v0.10.3
curl -fsSL "https://github.com/puravida-software/bondi/releases/download/${VERSION}/bondi-linux-x86_64.tar.gz" \
  | tar -xz -C ~/.local/bin
```

Where Homebrew *is* available, `brew tap puravida-software/homebrew-bondi && brew
install bondi` works — but see the known defect below if you are on a Mac.

## Verify by digest, always

`bondi --version` is a self-report. A stale binary states its own version
confidently, and that has already been believed instead of checked.

```bash
# what is installed
sha256sum "$(readlink -f "$(which bondi)")"

# what should be installed
VERSION=v0.10.3
curl -fsSL "https://github.com/puravida-software/bondi/releases/download/${VERSION}/bondi-linux-x86_64.tar.gz" \
  -o /tmp/bondi.tgz
sha256sum /tmp/bondi.tgz                      # compare against the FORMULA's sha256
tar -xzf /tmp/bondi.tgz -C /tmp && sha256sum /tmp/bondi   # compare against the INSTALLED binary
```

**The two digests are different things and comparing the wrong pair produces a
confident mismatch.** For `v0.10.3`:

- tarball `99d92297f8577172713f0f27b6d8afc5757fa79a853a52722e0062fc10d0da96` — this
  is what `Formula/bondi.rb` pins
- extracted binary `82d23352c260a2e1f9a74b5f7358be7eafc9a91173b21b754b4e35f9ef5d8256`
  — this is what an installed `~/.local/bin/bondi` must match

## Establishing what is released — from the remote, not a local clone

An unfetched clone reports the last time it was fetched, and reports it as
silence. Fetch, and cross-check the forge:

```bash
git fetch --tags --prune
git tag --contains <sha>
git tag --sort=-v:refname | head -5        # never `| tail` — tag output is lexicographic,
                                           # so v0.10.x sorts near v0.1.x

gh release list --repo puravida-software/bondi --limit 5
gh api repos/puravida-software/bondi/releases/latest --jq .tag_name
gh api repos/puravida-software/bondi/git/ref/tags/<tag> --jq .object.sha
```

If the fetched clone and the API disagree, the API wins and the disagreement is
worth reporting.

## Known defect — the tap is broken on macOS

`Formula/bondi.rb`'s `on_macos` / `Hardware::CPU.arm?` branch points at
`bondi-macos-arm64.tar.gz` with a pinned sha256, but **no recent release publishes
that asset**. `v0.10.1`, `v0.10.2` and `v0.10.3` each publish exactly one:
`bondi-linux-x86_64.tar.gz`.

Consequence: `brew install bondi` on an Apple-silicon Mac fails on a 404. The
macOS x86_64 branch is an explicit `odie`, so it fails cleanly. Harmless for Linux
CI and for Linux containers; a hard failure for anyone running `setup` from a
Mac. Either publish the asset or make the arm64 branch `odie` like its sibling.

## Release checklist

After cutting a release, state explicitly which of the four locations this release
needs, and update them.

- [ ] **Tag and release published**, with the Linux asset attached.
- [ ] **Tap formula bumped** — `version`, and the sha256 for each published asset.
      Verify the sha256 is of the tarball.
- [ ] **Which half changed?** `git show <sha> --stat` against `lib/client/` and
      `lib/server/`. Write the answer into the release notes — consumers need it
      to know whether they owe a CLI upgrade, a `setup` run, or both.
- [ ] **Installed CLIs upgraded** where a `lib/client/` fix matters, and
      **verified by digest**, not by `--version`.
- [ ] **Consuming repos' `bondi_server.version`** bumped where a `lib/server/` fix
      matters. Note this is a spec change: it will recreate the orchestrator, and
      on hosts with managed containers it is a convergence, not a no-op.
- [ ] **Does any consumer have a gate waiting on this fix?** Tell them the release
      exists. "Merged" is not "released" and "released" is not "installed"; a
      consumer blocked on the first will not notice the second.

## Before running `setup` on a host

`setup` converges the whole box against whatever config it is run with, restarts
the orchestrator on every run when the config has cron jobs, and is the only
command that touches managed containers. Treat it as a manual operator step
rather than something a pipeline runs unattended, and record that expectation
wherever your own repo documents its deployment procedure. At minimum, finish
every run with:

```bash
curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:3030/api/v1/health   # 204
```

Not `/health`, which is 404 — routes live under `Dream.scope "api"` / `"v1"`, and
the obvious probe reads a live server as dead.
