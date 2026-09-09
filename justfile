# https://cheatography.com/linux-china/cheat-sheets/justfile/

import "hurl_tests/hurl.just"

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
# an unchanged client uses, with its exit code and its JSON asserted against the
# corresponding route's. The negative arm runs in the same recipe rather than
# beside it, so this file and CI each hold one line for the pair and cannot come
# to hold different numbers of them. The script refuses any engine that is not
# Docker Engine: a rootless one reinterprets the two flags it exercises.
# Prove the image answers on the command line what it answers over HTTP.
check-server-image TAG:
    ./scripts/check-server-image.sh {{ IMAGE_NAME }}:{{ TAG }}
    ./scripts/check-server-image-negative.sh {{ IMAGE_NAME }}:{{ TAG }}

# Build the server Docker image the way release-dry-run CI does, then prove the
# result runs: verifies the Dockerfile, that every dependency resolves from a
# clean base image, and that the packaged binary starts and serves — the
# regression class that plain `dune build` cannot catch. Requires Docker.
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
    docker run --group-add $(stat -c %g /var/run/docker.sock) --name bondi-orchestrator -p 3030:3030 -v /var/run/docker.sock:/var/run/docker.sock --rm {{ IMAGE_NAME }}

# ODOC_WARN_ERROR matches what CI's lint-doc action sets. Without it odoc
# reports an unresolvable {!Reference} as a warning and exits 0, so the local
# gate passes and CI fails on the same tree — which is how a broken cross-library
# reference reaches a pull request.
lint-doc:
    ODOC_WARN_ERROR=true opam exec -- dune build @doc

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
