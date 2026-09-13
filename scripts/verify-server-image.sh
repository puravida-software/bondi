#!/usr/bin/env bash
#
# Prove that a built server image can actually run, not merely that it built.
#
# A `docker build` that succeeds says nothing about whether the binary it
# packaged can start: an unresolved shared library stops the musl loader before
# main and exits 127, and `docker run -d` reports that as a created container.
# Published images were broken this way from 0.8.2 through 0.10.1.
#
# Two assertions, both against the image passed in — which must be the one that
# gets pushed, not a local rebuild of the same Dockerfile:
#
#   1. the binary resolves every shared library it links
#   2. the packaged binary runs: `bondi-server check`, entered into a container
#      started from the image, writes its readiness document to stdout
#
# The second assertion asks liveness and not readiness, and the difference is
# the whole of why it reads the document rather than the exit status. No Docker
# socket is mounted here, so the socket probe fails and `check` exits the
# not-ready code on a perfectly good image. What a broken image cannot do is
# produce the document at all: a binary the musl loader stops before main writes
# nothing, which is the defect this script exists to catch.
#
# Usage: scripts/verify-server-image.sh IMAGE[:TAG]

set -euo pipefail

if [ "$#" -ne 1 ]; then
    echo "usage: $0 IMAGE[:TAG]" >&2
    exit 2
fi

image="$1"
binary=/usr/local/bin/bondi-server
container="bondi-server-verify-$$"
attempts=30
work="$(mktemp -d)"

cleanup() {
    docker rm --force "$container" > /dev/null 2>&1 || true
    rm -rf "$work"
}
trap cleanup EXIT

echo "==> $image: checking that every linked shared library resolves"
if ! ldd_output=$(docker run --rm --entrypoint /usr/bin/ldd "$image" "$binary" 2>&1); then
    echo "$ldd_output"
    echo "error: $binary in $image has unresolved shared libraries" >&2
    exit 1
fi
# ldd exits 127 when a library is missing, but a library that resolves and then
# fails to relocate is reported on stdout, so the text is checked as well.
if echo "$ldd_output" | grep -qE 'not found|Error loading|Error relocating'; then
    echo "$ldd_output"
    echo "error: $binary in $image has unresolved shared libraries" >&2
    exit 1
fi
echo "$ldd_output"

echo "==> $image: starting a container"
# No published port: nothing this script asks of the container is asked over a
# socket, and a port bound on the host is a collision waiting for two releases
# built at once.
docker run -d --name "$container" "$image" > /dev/null

echo "==> $image: running $binary check inside it"
attempt=0
ran=false
while [ "$attempt" -lt "$attempts" ]; do
    # The exit status is not the question -- a passing `check` exits 0 and a
    # socket-less one exits the not-ready code, and both mean the binary ran --
    # so it is discarded here and the document is what is looked at. Retried
    # because `docker run -d` returns before the container is necessarily
    # accepting execs, and only while the container is still up.
    docker exec "$container" "$binary" check \
        > "$work/stdout" 2> "$work/stderr" || true
    if [ -s "$work/stdout" ]; then
        ran=true
        break
    fi
    if [ "$(docker inspect -f '{{.State.Running}}' "$container" 2> /dev/null)" != "true" ]; then
        break
    fi
    attempt=$((attempt + 1))
    sleep 1
done

report_failure() {
    {
        echo "error: $1"
        echo "--- check stdout ---"
        cat "$work/stdout" 2>&1 || true
        echo "--- check stderr ---"
        cat "$work/stderr" 2>&1 || true
        docker inspect \
            --format 'status={{.State.Status}} exit={{.State.ExitCode}} oom={{.State.OOMKilled}} error={{.State.Error}}' \
            "$container" 2>&1 || true
        echo "--- container logs ---"
        docker logs "$container" 2>&1 || true
    } >&2
    exit 1
}

if [ "$ran" != true ]; then
    report_failure "$binary check wrote nothing in a container from $image"
fi

# A non-empty stdout is not on its own the document: the assertion is held to
# naming a probe the binary actually took, so a subcommand reduced to printing
# anything at all does not satisfy it.
if ! grep -qF -- '"probes"' "$work/stdout"; then
    report_failure "$binary check wrote no readiness document in a container from $image"
fi
if ! grep -qF -- '"docker_socket"' "$work/stdout"; then
    report_failure "$binary check took no docker_socket probe in a container from $image"
fi

echo "ok: $image ran $binary check and it reported its probes"
