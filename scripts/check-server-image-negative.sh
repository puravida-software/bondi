#!/usr/bin/env bash
#
# Prove that check-server-image.sh can fail.
#
# A check that cannot fail is not a check. This takes the image that just passed
# the command-surface check and wraps its binary so that one subcommand reports
# success for a request it did not carry out -- a failure path exiting 0, which
# is the defect the exit codes exist to prevent -- then asserts that the check
# rejects it.
#
# The wrapper leaves every other path alone, and in particular leaves the
# no-argument path serving HTTP. That is deliberate: an image that failed to
# start would be rejected by the first assertion, which the sibling script
# already covers, and would say nothing about whether the per-subcommand
# assertions can fail.
#
# Usage: scripts/check-server-image-negative.sh IMAGE[:TAG]

set -euo pipefail

if [ "$#" -ne 1 ]; then
    echo "usage: $0 IMAGE[:TAG]" >&2
    exit 2
fi

image="$1"
binary=/usr/local/bin/bondi-server
broken_image="bondi-server-check-negative:latest"
breaker="bondi-server-shim-$$"
here="$(cd "$(dirname "$0")" && pwd)"

cleanup() {
    docker rm --force "$breaker" > /dev/null 2>&1 || true
    docker image rm --force "$broken_image" > /dev/null 2>&1 || true
}
trap cleanup EXIT

# Passed in through the environment rather than quoted into the -c script, so
# the shim reads as the shell it is instead of as three levels of escaping.
shim="#!/bin/sh
if [ \"\$1\" = deploy ]; then exit 0; fi
exec $binary.real \"\$@\"
"

echo "==> building an image identical to $image but whose deploy exits 0"
# Built by commit rather than by a `FROM $image` Dockerfile, for the reason the
# sibling negative check gives: under the docker-container buildx driver FROM
# resolves against a registry and cannot see an image that exists only in the
# local daemon, which is what the image under test is at this point.
docker run --user root --entrypoint /bin/sh --name "$breaker" \
    -e SHIM="$shim" "$image" \
    -c "set -e; mv $binary $binary.real; printf '%s' \"\$SHIM\" > $binary; chmod 755 $binary" \
    > /dev/null
docker commit \
    --change 'USER appuser' \
    --change 'ENTRYPOINT ["/usr/local/bin/bondi-server"]' \
    "$breaker" "$broken_image" > /dev/null

# The rejection below is this check succeeding, and it reaches the terminal as a
# failed assertion and the word "error" -- which reads exactly like the run
# having failed, on the one path where nothing is wrong. The banners say so
# either side of it.
echo "==> asserting that the command-surface check rejects it"
echo "--- the diagnostics below are EXPECTED: a deliberately broken image is being rejected ---"
if "$here/check-server-image.sh" "$broken_image"; then
    echo "--- end of expected diagnostics ---"
    {
        echo "error: the command-surface check passed on an image whose deploy exits 0"
        echo "for a payload it refused. The check cannot fail, so it is not a check."
    } >&2
    exit 1
fi
echo "--- end of expected diagnostics: the rejection above is the result this check wanted ---"

echo "ok: a subcommand that exits 0 on a failure made the check fail, as it must"
echo "ok: $image passed the command-surface check, and that check is proven able to fail"
