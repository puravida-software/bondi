# https://cheatography.com/linux-china/cheat-sheets/justfile/

import "hurl_tests/hurl.just"

IMAGE_NAME := "mlopez1506/bondi-server"

default: build test fmt lint

# Assumes bondi.yaml has a service named "bondi"
docker-all TAG: (build-server TAG) (tag-server TAG) (push-server TAG) (update-bondi-version TAG)

build-server TAG:
    docker build --build-arg VERSION={{ TAG }} -t {{ IMAGE_NAME }} .

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

lint: lint-doc lint-fmt lint-opam

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

# Versioning

version:
	cz version --project

next-version:
	cz bump --dry-run --get-next
