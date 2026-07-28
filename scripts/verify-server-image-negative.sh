#!/usr/bin/env bash
#
# Prove that verify-server-image.sh can fail.
#
# A check that cannot fail is not a check. This takes the image that just passed
# verification, deletes one of the shared libraries the binary actually links,
# and asserts that verification then rejects it — reproducing, on purpose, the
# defect that shipped in 0.8.2 through 0.10.1.
#
# The library is read out of the binary rather than named here, so this keeps
# testing something real as the dependency graph moves.
#
# Usage: scripts/verify-server-image-negative.sh IMAGE[:TAG]

set -euo pipefail

if [ "$#" -ne 1 ]; then
    echo "usage: $0 IMAGE[:TAG]" >&2
    exit 2
fi

image="$1"
binary=/usr/local/bin/bondi-server
broken_image="bondi-server-verify-negative:latest"
breaker="bondi-server-break-$$"
here="$(cd "$(dirname "$0")" && pwd)"

cleanup() {
    docker rm --force "$breaker" > /dev/null 2>&1 || true
    docker image rm --force "$broken_image" > /dev/null 2>&1 || true
}
trap cleanup EXIT

library=$(
    docker run --rm --entrypoint /usr/bin/ldd "$image" "$binary" \
        | awk '{ for (i = 1; i <= NF; i++) if ($i == "=>") print $(i + 1) }' \
        | grep -v 'ld-musl' \
        | head -1
)

if [ -z "$library" ]; then
    echo "error: $binary links no shared libraries, so nothing can be removed" >&2
    echo "If the binary is now statically linked, delete this check." >&2
    exit 1
fi

echo "==> building an image identical to $image but without $library"
# Built by commit rather than by a `FROM $image` Dockerfile: under the
# docker-container buildx driver, FROM resolves against a registry and cannot
# see an image that only exists in the local daemon — which is exactly what the
# image under test is at this point in a release.
docker run --user root --entrypoint /bin/sh --name "$breaker" "$image" \
    -c "rm -f $library" > /dev/null
docker commit \
    --change 'USER appuser' \
    --change 'ENTRYPOINT ["/usr/local/bin/bondi-server"]' \
    "$breaker" "$broken_image" > /dev/null

echo "==> asserting that verification rejects it"
if "$here/verify-server-image.sh" "$broken_image"; then
    {
        echo "error: verification passed on an image with $library removed."
        echo "The check cannot fail, so it is not a check. Fix it before publishing."
    } >&2
    exit 1
fi

echo "ok: removing $library made verification fail, as it must"
