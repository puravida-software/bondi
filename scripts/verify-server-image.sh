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
#   2. a container from it answers its health endpoint
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
host_port="${BONDI_VERIFY_PORT:-33030}"
container_port=3030
health_path=/api/v1/health
attempts=30

cleanup() {
    docker rm --force "$container" > /dev/null 2>&1 || true
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
docker run -d --name "$container" -p "127.0.0.1:$host_port:$container_port" \
    "$image" > /dev/null

echo "==> $image: waiting for GET $health_path"
attempt=0
while [ "$attempt" -lt "$attempts" ]; do
    if curl -fsS -o /dev/null "http://127.0.0.1:$host_port$health_path"; then
        echo "ok: $image answered $health_path"
        exit 0
    fi
    # A container that has already exited will not start answering. Reporting
    # that in a second beats waiting out the full timeout to say the same thing.
    if [ "$(docker inspect -f '{{.State.Running}}' "$container" 2> /dev/null)" != "true" ]; then
        break
    fi
    attempt=$((attempt + 1))
    sleep 1
done

{
    echo "error: a container from $image did not answer $health_path"
    docker inspect \
        --format 'status={{.State.Status}} exit={{.State.ExitCode}} oom={{.State.OOMKilled}} error={{.State.Error}}' \
        "$container" 2>&1 || true
    echo "--- container logs ---"
    docker logs "$container" 2>&1 || true
} >&2
exit 1
