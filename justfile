# https://cheatography.com/linux-china/cheat-sheets/justfile/

import "hurl_tests/hurl.just"

IMAGE_NAME := "mlopez1506/bondi-server"

docker-all TAG: (build-server TAG) (tag-server TAG) (push-server TAG) (update-bondi-version TAG) cli-setup cli-deploy cli-status

build-server TAG:
    docker build --build-arg VERSION={{ TAG }} -t {{ IMAGE_NAME }} .

tag-server TAG:
    docker tag {{ IMAGE_NAME }}:latest {{ IMAGE_NAME }}:{{ TAG }}

push-server TAG:
    docker push {{ IMAGE_NAME }}:{{ TAG }}

server-docker:
    docker run --group-add $(stat -c %g /var/run/docker.sock) --name bondi-server -p 3030:3030 -v /var/run/docker.sock:/var/run/docker.sock --rm {{ IMAGE_NAME }}

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

update-bondi-version TAG:
    sed -i "s/version: .*/version: {{ TAG }}/g" bondi.yaml

server:
    opam exec -- dune exec bondi-server

cli-setup:
    go run ./cli/main.go setup

cli-deploy VERSION='0.0.0':
    go run ./cli/main.go deploy {{ VERSION }}

cli-status:
    go run ./cli/main.go status
