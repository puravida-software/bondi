# https://cheatography.com/linux-china/cheat-sheets/justfile/

import "hurl_tests/hurl.just"

IMAGE_NAME := "mlopez1506/bondi-server"

default: build test fmt lint build-server-ci

# Verification sits before the push for the same reason it does in the release
# workflow: nothing reaches the registry that has not been shown to run.
# Assumes bondi.yaml has a service named "bondi"
docker-all TAG: (build-server TAG) (tag-server TAG) (verify-server-image TAG) (verify-server-image-negative TAG) (push-server TAG) (update-bondi-version TAG)

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

tag-server TAG:
    docker tag {{ IMAGE_NAME }}:latest {{ IMAGE_NAME }}:{{ TAG }}

push-server TAG:
    docker push {{ IMAGE_NAME }}:{{ TAG }}

server-docker:
    docker run --group-add $(stat -c %g /var/run/docker.sock) --name bondi-orchestrator -p 3030:3030 -v /var/run/docker.sock:/var/run/docker.sock --rm {{ IMAGE_NAME }}

lint-doc:
    opam exec -- dune build @doc

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

update-bondi-version TAG:
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
