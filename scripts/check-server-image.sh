#!/usr/bin/env bash
#
# Prove that the command surface the published image ships answers the way the
# HTTP routes do, and that the command an unchanged client starts an
# orchestrator with still serves against it.
#
# `verify-server-image.sh` is this script's sibling and asks a smaller question:
# does the packaged binary start at all. This one asks what the binary does once
# it has started, and it asks it of the image rather than of the build tree,
# because a subcommand that works under `dune exec` and not in the image is a
# subcommand nobody can call.
#
# Six assertions, all against a container started from the image passed in by
# the exact command the client produces:
#
#   1. that command, with only its image reference and container name
#      substituted, serves HTTP
#   2. `status` writes the same bytes the status route writes
#   3. `check` reports the box ready, as JSON, exits 0, and the marker it
#      writes to PID 1's stderr comes back out of `docker logs`
#   4. `check --cron-configured` fails on a container with no spool, exits 3,
#      and still writes its readiness document to stdout
#   5. a payload that does not decode exits 2, and the route answers 400
#   6. a well-formed request Bondi cannot carry out exits 1, and the route 500
#
# then the same again with the command the client produces for a deployment that
# configures cron, which carries `--user root` and the spool mount, and where
# `check --cron-configured` must succeed.
#
# Usage: scripts/check-server-image.sh IMAGE[:TAG]

set -euo pipefail

if [ "$#" -ne 1 ]; then
    echo "usage: $0 IMAGE[:TAG]" >&2
    exit 2
fi

image="$1"
binary=/usr/local/bin/bondi-server
# The name the client's command carries, and the name this check actually runs
# under. They differ on purpose: `cleanup` and `start_container` force-remove
# the container they work on, and `just check-server-image` is documented as a
# recipe to run locally -- on a box with a real orchestrator up, which is the
# ordinary case for anyone testing bondi against their own deployment, running
# under the client's name would destroy it before a single assertion ran.
orchestrator_name=bondi-orchestrator
container="bondi-check-$$"
base_url="http://127.0.0.1:3030/api/v1"
here="$(cd "$(dirname "$0")" && pwd)"
fixture="$here/orchestrator-run-command.txt"
attempts=30
work="$(mktemp -d)"

cleanup() {
    docker rm --force "$container" > /dev/null 2>&1 || true
    rm -rf "$work"
}
trap cleanup EXIT

# Docker Engine or nothing. The two flags this check exists to exercise --
# `--group-add` against the socket's group and `--user root` -- are exactly the
# two a rootless engine reinterprets, so an engine that is not Docker Engine
# answers a different question and answers it green. Podman serves the docker
# CLI through a compatibility socket and names itself here: it reports its first
# server component as "Podman Engine" where Docker Engine reports "Engine"
# (measured against Podman 5.8.4). Refusing loudly is the point -- a check that
# degraded to whatever engine it found would be evidence about the wrong one.
engine="$(docker version --format '{{(index .Server.Components 0).Name}}' 2> /dev/null || true)"
if [ "$engine" != "Engine" ]; then
    {
        echo "error: this check requires Docker Engine."
        echo "The docker command here is answered by: ${engine:-(no server reachable)}"
        echo "DOCKER_HOST=${DOCKER_HOST:-(unset)}"
        echo "A rootless engine reinterprets --group-add and --user root, which are the"
        echo "two flags this check exists to exercise, so a pass here would be a pass"
        echo "about a different engine than the one the image is published for."
    } >&2
    exit 1
fi
echo "==> engine: Docker Engine $(docker version --format '{{.Server.Version}}')"

# The command is read from the fixture the client itself generates rather than
# written out here. A command typed into this script would assert that its
# author remembered the flags, which is not the claim being made.
run_command_for() {
    local label line declared renamed
    label="$1"
    line="$(sed -n "s/^$label //p" "$fixture")"
    if [ -z "$line" ]; then
        {
            echo "error: $fixture carries no '$label' command."
            echo "Regenerate it with: dune runtest && dune promote"
        } >&2
        return 1
    fi
    # Two things are substituted, the image reference and the container name,
    # and each substitution refuses rather than proceeds if the command is not
    # the shape it expected -- a silent no-op here is the failure mode that
    # matters. A client that stopped putting the image last would otherwise
    # leave this checking the published image instead of the one just built; a
    # client that renamed the container would leave this running, and
    # force-removing, whatever the operator's real orchestrator is called.
    declared="${line##* }"
    case "$declared" in
        mlopez1506/bondi-server:*) : ;;
        *)
            echo "error: the '$label' command does not end in a bondi-server image reference (found: $declared)" >&2
            return 1
            ;;
    esac
    case "$line" in
        *" --name $orchestrator_name "*) : ;;
        *)
            echo "error: the '$label' command does not name a container '$orchestrator_name', so this check cannot rename it away from the operator's own" >&2
            return 1
            ;;
    esac
    renamed="${line/ --name $orchestrator_name / --name $container }"
    printf '%s %s\n' "${renamed% *}" "$image"
}

start_container() {
    local command
    command="$1"
    docker rm --force "$container" > /dev/null 2>&1 || true
    echo "==> starting: $command"
    eval "$command" > /dev/null
}

report_container() {
    {
        docker inspect \
            --format 'status={{.State.Status}} exit={{.State.ExitCode}} oom={{.State.OOMKilled}} error={{.State.Error}}' \
            "$container" 2>&1 || true
        echo "--- container logs ---"
        docker logs "$container" 2>&1 || true
    } >&2
}

wait_for_health() {
    local attempt=0
    while [ "$attempt" -lt "$attempts" ]; do
        if curl -fsS -o /dev/null "$base_url/health"; then
            echo "ok: the container answers GET $base_url/health"
            return 0
        fi
        # A container that has already exited will not start answering.
        if [ "$(docker inspect -f '{{.State.Running}}' "$container" 2> /dev/null)" != "true" ]; then
            break
        fi
        attempt=$((attempt + 1))
        sleep 1
    done
    echo "error: the container did not answer GET $base_url/health" >&2
    report_container
    return 1
}

# The exit status of the last subcommand run, kept here because a function
# cannot both return it and be used under `set -e`.
subcommand_status=0

run_subcommand() {
    local stdin_file
    stdin_file="$1"
    shift
    subcommand_status=0
    docker exec -i "$container" "$binary" "$@" \
        < "$stdin_file" > "$work/stdout" 2> "$work/stderr" || subcommand_status=$?
}

show_subcommand() {
    {
        echo "--- stdout ---"
        cat "$work/stdout"
        echo "--- stderr ---"
        cat "$work/stderr"
    } >&2
}

expect_code() {
    local what expected
    what="$1"
    expected="$2"
    if [ "$subcommand_status" != "$expected" ]; then
        echo "error: $what exited $subcommand_status, expected $expected" >&2
        show_subcommand
        return 1
    fi
    echo "ok: $what exited $expected"
}

# Every exit-code assertion is paired with one of these. An exit code on its own
# is reachable by accident -- a missing binary, a container that died, an empty
# answer -- so each one is held to naming what it refused as well.
expect_stream_contains() {
    local what stream needle
    what="$1"
    stream="$2"
    needle="$3"
    if ! grep -qF -- "$needle" "$work/$stream"; then
        echo "error: $what: expected '$needle' on $stream" >&2
        show_subcommand
        return 1
    fi
    echo "ok: $what: $stream names '$needle'"
}

expect_stream_nonempty() {
    local what stream
    what="$1"
    stream="$2"
    if [ ! -s "$work/$stream" ]; then
        echo "error: $what: expected something on $stream, and it was empty" >&2
        show_subcommand
        return 1
    fi
    echo "ok: $what: $stream is not empty"
}

# The one claim `readiness.mli` says cannot be made from inside the container:
# that the line the sink probe writes to PID 1's stderr reaches the container's
# log stream. Seeing it needs the container runtime, so this -- an observer
# outside the container -- is the only place it can be asserted.
#
# The log is captured to a file rather than piped into grep: under `pipefail` a
# `grep -q` that matches exits at once, and the SIGPIPE it hands `docker logs`
# would fail the pipeline on the very run that found the line. Retried because
# the engine's log driver drains the container's pipe on its own schedule, so a
# read taken in the same instant as the write can legitimately miss it.
expect_container_log_contains() {
    local what needle attempt
    what="$1"
    needle="$2"
    attempt=0
    while [ "$attempt" -lt 10 ]; do
        docker logs "$container" > "$work/container-log" 2>&1 || true
        if grep -qF -- "$needle" "$work/container-log"; then
            echo "ok: $what: the container log carries '$needle'"
            return 0
        fi
        attempt=$((attempt + 1))
        sleep 1
    done
    echo "error: $what: expected '$needle' in the container log" >&2
    report_container
    return 1
}

expect_route_code() {
    local what expected got
    what="$1"
    expected="$2"
    got="$3"
    if [ "$got" != "$expected" ]; then
        echo "error: $what: the route answered $got, expected $expected" >&2
        echo "--- route body ---" >&2
        cat "$work/route-body" >&2
        return 1
    fi
    echo "ok: $what: the route answered $expected"
}

post_payload() {
    local path
    path="$1"
    curl -s -o "$work/route-body" -w '%{http_code}' \
        -X POST -H 'Content-Type: application/json' \
        --data-binary @"$work/payload.json" "$base_url/$path"
}

# Both commands are resolved before anything is started. A command
# substitution that failed inside an argument would leave `eval` running an
# empty string, which starts nothing and reports nothing; an assignment lets
# `set -e` see the failure.
no_cron_command="$(run_command_for no-cron)"
cron_command="$(run_command_for cron)"

printf '{"image": 5}' > "$work/invalid-deploy.json"
# Well formed, and Bondi cannot carry it out: `.invalid` is reserved by RFC 2606
# and resolves nowhere, so the pull fails at once rather than being waited out.
#
# It does not name a registry port, though a port is the more direct way to make
# a pull fail fast, because `Simple.parse_image_and_tag` splits on every colon
# and rejects any reference carrying one, which is a known defect. A payload
# written that way is refused as `Invalid_request` before a pull is attempted,
# which exits 2 and answers 400: this assertion would then be pinning the
# decode arm it has already pinned above, and the orchestrator-failure arm
# would go unasserted while the check reported green.
printf '{"job": "image-gate-probe", "image": "absent.invalid/absent:0.0.1"}' \
    > "$work/unrunnable-run.json"

echo "==> $image: the command a client with no cron jobs starts an orchestrator with"
start_container "$no_cron_command"
wait_for_health

echo "==> $image: status writes what the status route writes"
run_subcommand /dev/null status
expect_code "status" 0
# Non-emptiness is asserted before the comparison: two empty files compare equal,
# and a subcommand that wrote nothing would otherwise pass this.
expect_stream_contains "status" stdout '"infrastructure"'
if ! curl -fsS -o "$work/route-status.json" "$base_url/status"; then
    echo "error: GET $base_url/status did not answer, though the status subcommand exited 0" >&2
    report_container
    exit 1
fi
if ! cmp -s "$work/stdout" "$work/route-status.json"; then
    {
        echo "error: status wrote different bytes than GET $base_url/status"
        echo "--- subcommand ---"
        cat "$work/stdout"
        echo ""
        echo "--- route ---"
        cat "$work/route-status.json"
        echo ""
    } >&2
    exit 1
fi
echo "ok: status and GET $base_url/status wrote the same bytes"

echo "==> $image: check reports the box ready"
run_subcommand /dev/null check
expect_code "check" 0
expect_stream_contains "check" stdout '"ready":true'
expect_stream_contains "check" stdout '"docker_socket"'
expect_container_log_contains "check" 'bondi check: diagnostic sink is writable'

echo "==> $image: check --cron-configured fails where there is no spool"
run_subcommand /dev/null check --cron-configured
expect_code "check --cron-configured" 3
expect_stream_contains "check --cron-configured" stderr 'crontab spool'
# The document goes to stdout on the failing arm as well, which is the whole
# reason `check` writes through `Cmd_io.diagnostic_of` rather than
# `Cmd_io.status_of`: the state a caller acts on is the not-ready one, and a
# machine-readable form of it that only appeared when every probe passed would be
# reachable from nobody. Asserted here rather than from cram because this is the
# only place the failure is manufactured instead of ambient -- a developer box
# fails these probes too, but for reasons that belong to the box.
#
# The flag and the probe's key, never the reason: the spool reason names the file
# `Filename.temp_file` just made, whose suffix is fresh on every run. The key is
# also not the wording asserted on stderr above -- `readiness.ml` keeps
# `probe_key` and `probe_name` apart on purpose, and this is the arm that shows
# both reached their own stream.
expect_stream_contains "check --cron-configured" stdout '"ready":false'
expect_stream_contains "check --cron-configured" stdout '"crontab_spool"'

echo "==> $image: a payload that does not decode"
cp "$work/invalid-deploy.json" "$work/payload.json"
run_subcommand "$work/payload.json" deploy
expect_code "deploy" 2
expect_stream_contains "deploy" stderr 'invalid deploy payload'
expect_route_code "deploy" 400 "$(post_payload deploy)"

echo "==> $image: a well-formed request Bondi cannot carry out"
cp "$work/unrunnable-run.json" "$work/payload.json"
run_subcommand "$work/payload.json" run
expect_code "run" 1
# The text is the engine's own report of a pull it could not make, so it is
# asserted to exist rather than transcribed: pinning its wording here would make
# this check fail on a Docker version that rephrased it.
expect_stream_nonempty "run" stderr
expect_route_code "run" 500 "$(post_payload run)"

echo "==> $image: the command a client with cron jobs starts an orchestrator with"
start_container "$cron_command"
wait_for_health

echo "==> $image: check --cron-configured succeeds where the spool is mounted"
run_subcommand /dev/null check --cron-configured
expect_code "check --cron-configured" 0
expect_stream_contains "check --cron-configured" stdout '"ready":true'
expect_stream_contains "check --cron-configured" stdout '"crontab_spool"'

echo "ok: $image answers on the command line what it answers over HTTP"
