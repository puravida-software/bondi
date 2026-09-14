# https://cheatography.com/linux-china/cheat-sheets/justfile/

IMAGE_NAME := "mlopez1506/bondi-server"

# The last thing printed is what the run means. Without it the gate ends on the
# negative image check, whose success is a page of loader errors and the word
# "error" — a passing run that reads as a failed one.
default: build test fmt lint build-server-ci
    @echo ""
    @echo "================================================================"
    @echo "  just: PASSED — build, test, fmt, lint, server image"
    @echo "  Any 'error' lines above came from the negative image check,"
    @echo "  which passes by rejecting an image it broke on purpose."
    @echo "================================================================"

# Verification sits before the push for the same reason it does in the release
# workflow: nothing reaches the registry that has not been shown to run.
# Assumes bondi.yaml has a service named "bondi"
docker-all TAG: (check-version-floor TAG) (build-server TAG) (tag-server TAG) (verify-server-image TAG) (verify-server-image-negative TAG) (check-server-image TAG) (push-server TAG) (update-bondi-version TAG)

# A client refuses to write a cron line for a box whose orchestrator predates
# the [run] subcommand that line invokes, and it decides that against a floor
# compiled into the client. Publishing a tag below that floor is therefore not a
# release with a small mistake in it: it is a release the client rejects on
# every cron deploy in the estate, with a message telling the operator to pin a
# version that does not exist. So the tag is checked against the floor before
# anything is built, and again wherever bondi.yaml is rewritten.
#
# The floor is read out of the OCaml source that enforces it. A second copy of
# the number here would be free to drift from the one that decides, which is the
# whole failure this recipe exists to prevent. Only major and minor are compared,
# matching what Server_version reads, so a suffixed tag such as 0.16.0-rc1 is
# judged on its ordering rather than refused for its shape.
check-version-floor TAG:
    #!/usr/bin/env bash
    set -euo pipefail
    source_file=lib/client/server_version.ml
    floor_major=$(sed -n 's/^let minimum_major = \([0-9][0-9]*\)$/\1/p' "$source_file")
    floor_minor=$(sed -n 's/^let minimum_minor = \([0-9][0-9]*\)$/\1/p' "$source_file")
    case "$floor_major:$floor_minor" in
        *[!0-9:]*|:*|*:|*:*:*)
            echo "error: could not read exactly one minimum_major and one minimum_minor" >&2
            echo "       from $source_file. A release cannot be checked against a floor" >&2
            echo "       that was not read, and a check that cannot justify its answer" >&2
            echo "       fails rather than reporting one." >&2
            exit 1
            ;;
    esac
    tag={{ TAG }}
    tag=${tag#v}
    tag_major=${tag%%.*}
    rest=${tag#*.}
    if [ "$rest" = "$tag" ]; then
        echo "error: cannot read a major.minor ordering from tag '{{ TAG }}'" >&2
        exit 1
    fi
    tag_minor=${rest%%.*}
    tag_minor=${tag_minor%%[!0-9]*}
    case "$tag_major$tag_minor" in
        ''|*[!0-9]*)
            echo "error: cannot read a major.minor ordering from tag '{{ TAG }}'" >&2
            exit 1
            ;;
    esac
    if [ "$tag_major" -gt "$floor_major" ] \
       || { [ "$tag_major" -eq "$floor_major" ] && [ "$tag_minor" -ge "$floor_minor" ]; }; then
        exit 0
    fi
    echo "error: tag {{ TAG }} orders below $floor_major.$floor_minor.0, the floor" >&2
    echo "       $source_file enforces before it will write a cron line." >&2
    echo "       Publishing it makes every cron deploy fail against this release." >&2
    echo "       Either number the release $floor_major.$floor_minor.0 or later, or" >&2
    echo "       lower minimum_major/minimum_minor and re-run the tests." >&2
    exit 1

build-server TAG:
    docker build --load --build-arg VERSION={{ TAG }} -t {{ IMAGE_NAME }} .

# Prove the image can run, not just that it built. Both assertions run against
# the image in the local daemon — the one that gets pushed — so a check can
# never pass on a different artifact from the one published. Requires Docker.
verify-server-image TAG:
    ./scripts/verify-server-image.sh {{ IMAGE_NAME }}:{{ TAG }}

# Prove the verification above can fail, by removing a library the binary
# actually links and asserting it is rejected. A check that cannot fail is not
# a check.
verify-server-image-negative TAG:
    ./scripts/verify-server-image-negative.sh {{ IMAGE_NAME }}:{{ TAG }}

# Every subcommand is exercised inside a container started by the exact command
# an unchanged client uses, with its exit code and its JSON asserted against what
# this tree says each one answers. The negative arm runs in the same recipe
# rather than beside it, so this file and CI each hold one line for the pair and
# cannot come to hold different numbers of them. The script refuses any engine
# that is not Docker Engine: a rootless one reinterprets the two flags it
# exercises.
# One assertion is opt-in: the outbound-TLS handshake reaches a host outside this
# project, so it runs only under BONDI_CHECK_TLS_HANDSHAKE=1, which both release
# workflows set at the step that calls this recipe. A local run without it prints
# a skipped: line naming the variable and asserts everything else.
# Prove the published image ships the command surface this tree describes.
check-server-image TAG:
    ./scripts/check-server-image.sh {{ IMAGE_NAME }}:{{ TAG }}
    ./scripts/check-server-image-negative.sh {{ IMAGE_NAME }}:{{ TAG }}

# Build the server Docker image the way release-dry-run CI does, then prove the
# result runs: verifies the Dockerfile, that every dependency resolves from a
# clean base image, and that the packaged binary starts and answers every one of
# its subcommands — the regression class that plain `dune build` cannot catch.
# Requires Docker.
# Uses the CI-computed version when commitizen (cz) is present; otherwise a dev
# placeholder, since the version is only embedded at runtime and does not affect
# what this step verifies.
build-server-ci:
    #!/usr/bin/env bash
    set -euo pipefail
    if command -v cz >/dev/null 2>&1; then
        VERSION=$(just next-version)
    else
        VERSION=0.0.0-dev
    fi
    if [ -z "$VERSION" ]; then
        echo "error: could not determine a version for the server image build" >&2
        exit 1
    fi
    just build-server "$VERSION"
    just verify-server-image latest
    just verify-server-image-negative latest
    just check-server-image latest

tag-server TAG:
    docker tag {{ IMAGE_NAME }}:latest {{ IMAGE_NAME }}:{{ TAG }}

push-server TAG:
    docker push {{ IMAGE_NAME }}:{{ TAG }}

server-docker:
    docker run --group-add $(stat -c %g /var/run/docker.sock) --name bondi-orchestrator -v /var/run/docker.sock:/var/run/docker.sock --rm {{ IMAGE_NAME }}

# [observed — 2026-09-13, dune 3.20.2, odoc 3.1.0] The `@doc` alias is blind
# here: with an unresolvable {!Reference} deliberately injected into an .mli,
# `dune build @doc` printed nothing and exited 0 — on a cold `_doc` tree, with
# and without ODOC_WARN_ERROR. Only `@doc-new`, the odoc-3 driver, reports the
# reference at all, and it exits 0 too, so the warning has to be grepped for.
# ODOC_WARN_ERROR is deliberately not set: under `@doc-new` it turns the
# dependency set's own warnings (stdlib's `seq.mld`) into errors and the build
# dies before reaching this project's sources. For the same reason the grep is
# restricted to files under this tree. The doc directory is deleted first
# because odoc is not re-run once its outputs are up to date, which would
# otherwise leave the gate quietest exactly when someone re-runs it to confirm
# a fix.
#
# The capture takes three lines after each `File "` header rather than one, so
# that a diagnostic whose message wraps is not truncated, and a header this
# recipe cannot classify as `Warning:` or `Error:` fails on its own rather than
# passing silently. [observed — 2026-09-13: with
# `{!No_Such_Module.no_such_value}` injected into `lib/server/cli.mli` the
# recipe exited 1 on two consecutive runs, and 0 again once removed.]
#
# What the gate cannot see: odoc reports only the modules the doc set renders.
# The same injection in `lib/server/readiness.mli`, which the library does not
# re-export, produced no diagnostic and the recipe exited 0. [observed —
# 2026-09-13, same session.]
lint-doc:
    rm -rf _build/default/_doc_new
    @out="$(opam exec -- dune build @doc-new 2>&1)"; \
      status=$?; \
      [ $status -eq 0 ] || { printf '%s\n' "$out"; exit $status; }; \
      mine="$(printf '%s\n' "$out" | grep -A3 -E '^File "(lib|bin|test|scripts)/' || true)"; \
      if printf '%s\n' "$mine" | grep -qE '^(Warning|Error):'; then \
        printf '%s\n' "$mine"; \
        echo "lint-doc: odoc could not resolve the reference(s) above" >&2; \
        exit 1; \
      fi; \
      if printf '%s\n' "$mine" | grep -qE '^File "'; then \
        printf '%s\n' "$mine"; \
        echo "lint-doc: odoc reported the diagnostic above against this tree in a shape this recipe does not classify" >&2; \
        exit 1; \
      fi

lint-fmt:
    opam exec -- dune build @fmt

lint-opam:
    opam exec -- opam-dune-lint

lint-dep-bounds:
    @awk '/^depends:/,/^\]/' bondi.opam \
      | grep -E '^\s+"[a-z]' \
      | grep -v -e '>=' -e '{= ' -e 'with-doc' \
      | { if read -r line; then echo "Missing lower bound:"; echo "$line"; cat; exit 1; fi; }

lint: lint-doc lint-fmt lint-opam lint-dep-bounds

deps:
    opam install --deps-only --with-test --with-dev-setup -y .

build:
    opam exec -- dune build

test:
    opam exec -- dune runtest

fmt:
    opam exec -- dune fmt

update-bondi-version TAG: (check-version-floor TAG)
    sed -i "s/version: .*/version: {{ TAG }}/g" bondi.yaml

server:
    opam exec -- dune exec bondi-server

cli-init:
    opam exec -- dune exec bondi-client -- init

cli-setup:
    opam exec -- dune exec bondi-client -- setup

# Deploy requires name:tag (e.g. cli-deploy my-service:v1.2.3)
cli-deploy DEPLOYMENTS:
    opam exec -- dune exec bondi-client -- deploy --redeploy-traefik {{ DEPLOYMENTS }}

cli-status:
    opam exec -- dune exec bondi-client -- status

cli-ps:
    opam exec -- dune exec bondi-client -- docker ps

cli-logs CONTAINER_NAME:
    opam exec -- dune exec bondi-client -- docker logs {{ CONTAINER_NAME }}

# Validate generated Alloy River configs with alloy fmt (requires Docker)
lint-alloy:
    opam exec -- dune exec test/common/test_alloy_river.exe -- test "alloy fmt"

# Versioning

version:
	cz version --project

next-version:
	cz bump --dry-run --get-next
