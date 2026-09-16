#!/usr/bin/env bash
#
# Prove that the command surface the published image ships answers the way this
# tree says it does, and that the command an unchanged client starts an
# orchestrator with still produces a container that surface can be reached in.
#
# `verify-server-image.sh` is this script's sibling and asks a smaller question:
# does the packaged binary start at all. This one asks what the binary does once
# it has started, and it asks it of the image rather than of the build tree,
# because a subcommand that works under `dune exec` and not in the image is a
# subcommand nobody can call.
#
# Eight assertions. The first seven are reached with `docker exec` into a
# container started from the image passed in by the exact command the client
# produces; the eighth is asked from outside, because stopping a container is
# not a thing the container can be asked to do from within it:
#
#   1. `status` exits 0 and writes a document naming the infrastructure it found
#   2. `check` reports the box ready, as JSON, exits 0, the marker it writes to
#      PID 1's stderr comes back out of `docker logs`, and the cron divergence
#      is not among the probes a deployment without cron is asked about
#   3. `check --cron-configured` fails on a container with no spool, exits the
#      not-ready code, still writes its readiness document to stdout, and does
#      ask about the cron divergence
#   4. a payload that does not decode exits 2 and names what it refused
#   5. a well-formed request Bondi cannot carry out exits 1 and says why
#   6. `run` leaves a job container on the engine, a second `run` of the same job
#      exits 0, and the first container is gone -- both halves asked by container
#      id rather than inferred from an exit code
#   7. a `run` whose severity map routes an alert to an `https` sink completes a
#      TLS handshake against the system trust store. Opt-in: it is the one
#      assertion here that reaches a third party's host, so it runs only when
#      `BONDI_CHECK_TLS_HANDSHAKE` is set, and prints a `skipped:` line naming
#      that variable when it is not. Both release workflows set it at the
#      `just check-server-image` step, so nothing CI asserts is lost.
#
# then the same again with the command the client produces for a deployment that
# configures cron, which carries `--user root` and the spool mount, and where
# `check --cron-configured` must succeed -- and last of all, on that same
# container, once nothing else needs it up:
#
#   8. `docker stop` is answered. The container leaves exit code 0, and leaves
#      it well inside the timeout the daemon was given rather than being killed
#      at it. This is the one arm anywhere that runs the idling binary as a real
#      PID 1 and then asks it to stop: `Cli.wait_forever` installs a SIGTERM
#      disposition of its own precisely because the kernel discards a
#      default-action signal aimed at a PID namespace's init, and a binary run
#      any other way -- which is every process `dune test` can start -- answers
#      the stop whether or not that disposition was installed. `bondi setup`
#      issues this stop on every version bump.
#
# What this enumeration does not cover, named so its completeness is not read as
# wider than it is:
#
#   - `deploy`'s success path. It needs a private registry credential and drives
#     a Let's Encrypt production order for a real hostname; assertion 5 is its
#     failure arm and nothing here is its success arm.
#   - that `status` reports the job assertion 6 ran. It does not and cannot:
#     `status` lists cron jobs from the Bondi section of the crontab, and a job
#     started by `run` writes no crontab entry. Manufacturing one would mean
#     writing the operator's own spool through the cron container's bind mount.
#   - the outbound TLS handshake, on any run that does not set
#     `BONDI_CHECK_TLS_HANDSHAKE`. The arm is worth having -- it is the class of
#     defect that broke images 0.8.2 through 0.10.1 -- but it fails on an
#     unreachable `example.com` and on a proxy that intercepts the handshake,
#     and this script gates a publish. The HTTP bundle these arms were recovered
#     from kept its TLS check out of its own default set for that reason; the
#     gate is carried across with the assertion rather than dropped with the
#     bundle. A run that skips it says so on stdout.
#   - any signal other than SIGTERM reaching the idling PID 1. `wait_forever`
#     resumes a sleep that some other signal's delivery merely cut short, so
#     that a stray signal is not read as a stop; assertion 8 sends the one
#     signal `docker stop` sends, and nothing here sends another.
#   - the registry being reachable. Assertions 6 and 7 need a base image for the
#     job container on the engine before either runs, and this script pulls it:
#     `run` creates a container through the Engine API, which -- unlike the
#     `docker run` CLI -- does not pull a missing image but answers 404 [observed
#     against Docker Engine 29.8.0 on 2026-09-13]. A registry that rate-limits or
#     refuses fails this gate, and nothing here can tell that apart from the
#     image under test being broken.
#
# Assertions 6 and 7 were written from what the HTTP integration bundle this
# repository used to carry asserted, rather than ported from a bundle that could
# still be run. They have since been executed: against Docker Engine 29.8.0 on
# 2026-09-13 [observed] both were reached and both passed, printing the `ok:`
# lines that name `image-gate-run` and `image-gate-alert-tls`, with the same
# container id on the two that name one. On a run with
# `BONDI_CHECK_TLS_HANDSHAKE` unset the `image-gate-alert-tls` lines are absent
# and a `skipped:` line naming the variable stands in their place; a run that
# reaches the end having printed neither exited before it got here.
#
# Assertion 8 has been run both ways [observed -- 2026-09-13, Docker Engine
# 29.8.0]. Against this image it answered in 1s and exited 0. Against a
# stand-in container whose PID 1 ignores SIGTERM it was refused twice over: the
# stop took the full 30s and the container left 137, and each of the two arms
# was shown to refuse on its own with the other disabled. A single arm would
# not have been enough -- a container that was never up satisfies the deadline,
# and the exit code alone does not say the stop was answered rather than waited
# out.
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
here="$(cd "$(dirname "$0")" && pwd)"
fixture="$here/orchestrator-run-command.txt"
# How long `start_container` waits for a container it just started to be up,
# in one-second attempts. The same number `verify-server-image.sh` waits, for
# the same engine behaviour: the two scripts run in the same job against the
# same engine, and a box slow enough to fail one is slow enough to fail both.
attempts=30
# How long the daemon is told to wait between the SIGTERM `docker stop` sends
# and the SIGKILL it falls back to, and how long assertion 8 allows the stop to
# take. The two numbers are far apart on purpose. The defect that arm exists to
# catch is a binary that never answers the signal, and such a binary does not
# fail to stop -- it stops at the timeout, killed -- so a bound set at the
# timeout would be satisfied by exactly the failure. The deadline is the number
# that has to be beaten and the timeout is what makes beating it mean anything:
# a stop that is answered takes about as long as one `exit 0`, and one that is
# not takes the whole 30.
stop_timeout=30
stop_deadline=5
# The line `check` writes to its diagnostic sink, taken from the single place it
# is spelled rather than repeated here. A copy in this script would be a second
# spelling, and a divergence between the two spellings is precisely the defect
# this assertion exists to catch: the server would go on writing its line and
# this gate would go on looking for a different one, silently, from both ends.
#
# It is derived from the source rather than read out of the running binary
# because the binary writes the line to PID 1's stderr and nowhere else -- which
# is the stream asserted against below, so a needle taken from it would be
# matching itself -- and no other output carries it.
#
# The extraction is anchored to the definition, so a comment that happens to
# quote the line cannot supply it, and it must yield exactly one line: an empty
# needle makes `grep -qF` match every line of the log and this gate would then
# pass having asserted nothing.
#
# What this does not cover: the needle comes from the working tree, not from the
# image under test, so an image built from an older tree fails this assertion
# without the two spellings having drifted from each other. That is the same
# assumption the run-command fixture beside this script already makes -- the
# check is of an image built from this tree.
marker_source="$here/../lib/common/check_marker.ml"
marker="$(sed -n 's/^let diagnostic_sink = "\(.*\)"$/\1/p' "$marker_source")"
if [ -z "$marker" ] || [ "$(printf '%s\n' "$marker" | wc -l)" -ne 1 ]; then
    echo "error: could not derive the check marker from $marker_source" >&2
    exit 1
fi
# The exit code a Bondi server subcommand leaves behind when the box is not
# ready, taken from the single place it is spelled. A copy here would be a
# second spelling, and the assertions below cannot tell a code that drifted
# from a code that was always wrong: each of them reads a number back out of a
# container and compares it to a number this script supplied.
#
# It is derived from the source for the same reason the marker is -- the number
# the image leaves is the thing under test, so an expectation read back out of it
# would be matching itself -- and the extraction is anchored to the definition so
# that a comment quoting the value cannot supply it. It is checked because a
# derivation that quietly yielded nothing would turn every assertion below into
# one that reports "expected " and names no value.
#
# What this does not cover: as with the marker, the number comes from the working
# tree rather than from the image under test, so an image built from an older
# tree fails these assertions without the two spellings having drifted from each
# other. That is the same assumption the rest of this check already makes.
not_ready_source="$here/../lib/common/readiness_exit_code.ml"
not_ready="$(sed -n 's/^let not_ready = \([0-9][0-9]*\)$/\1/p' "$not_ready_source")"
if [ -z "$not_ready" ] || [ "$(printf '%s\n' "$not_ready" | wc -l)" -ne 1 ]; then
    echo "error: could not derive the not-ready exit code from $not_ready_source" >&2
    exit 1
fi
work="$(mktemp -d)"
# The two jobs the run arms below start, and the image they start. The names are
# not arbitrary: `run` removes the previous container *by job name* before
# renaming the new one into place, so a name shared with a job an operator
# actually schedules would destroy that job's last run record on the box this
# check is run against. These two are named after the check rather than after
# anything a deployment would call a job, for the same reason `$container` is
# named away from `$orchestrator_name` above.
#
# The image is a public base image that starts and exits 0 at once. Any image
# the engine can pull would do; what the arm needs is a container that really
# runs and really ends.
#
# It is named by digest and not by `alpine:latest` because this script gates a
# publish: a third party's tag moving under a release gate turns a push into a
# failure about somebody else's image, and a moving tag is not something a gate
# can be asked to reason about. The digest is what `alpine:latest` resolved to
# on 2026-09-13 [observed, via `docker inspect --format '{{index .RepoDigests 0}}'`];
# bumping it is a deliberate edit, which is the point.
run_job="image-gate-run"
tls_job="image-gate-alert-tls"
run_image="alpine@sha256:28bd5fe8b56d1bd048e5babf5b10710ebe0bae67db86916198a6eec434943f8b"
# RFC 2606 reserves this name and IANA operates a live HTTPS site on it. It is
# the host the HTTP integration bundle's own TLS check posted to, so the arm
# below targets what that check targeted rather than introducing a new
# dependency on some third party's endpoint.
tls_sink_host="example.com"
# Assertion 7 is the only one here that reaches a host this project does not
# control, and this script runs ahead of `Push server image`. It is therefore
# opt-in: the release workflows set the variable at the step that calls this
# script, and an operator running the script by hand gets every other assertion
# without needing the network to cooperate. The skip is printed, not silent -- a
# silently absent arm reads as coverage, which is worse than a named gate.
tls_handshake="${BONDI_CHECK_TLS_HANDSHAKE:-}"

cleanup() {
    docker rm --force "$container" > /dev/null 2>&1 || true
    # The job containers are the run arms' leavings, and they are on the engine
    # rather than inside `$container`: the orchestrator starts them through the
    # socket, so removing the orchestrator does not remove them.
    docker rm --force "$run_job" > /dev/null 2>&1 || true
    docker rm --force "$tls_job" > /dev/null 2>&1 || true
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
    local command attempt running state
    command="$1"
    docker rm --force "$container" > /dev/null 2>&1 || true
    echo "==> starting: $command"
    eval "$command" > /dev/null
    # `docker run -d` returns once the engine has accepted the container, which
    # is before it is necessarily accepting execs, and every caller's next move
    # is a `docker exec`. The barrier lives here rather than around each first
    # exec because the precondition belongs to starting a container, not to the
    # first thing asked of one: an assertion added later inherits it instead of
    # re-deriving it.
    #
    # A container that has already exited will never become running, so "not up
    # yet" and "already dead" are told apart rather than both waited out -- the
    # second is a failure this script should report now, with the container's
    # logs, not in thirty seconds' time.
    attempt=0
    while [ "$attempt" -lt "$attempts" ]; do
        running="$(docker inspect --format '{{.State.Running}}' "$container" 2> /dev/null || true)"
        if [ "$running" = "true" ]; then
            echo "ok: $container is running"
            return 0
        fi
        state="$(docker inspect --format '{{.State.Status}}' "$container" 2> /dev/null || true)"
        case "$state" in
            created | restarting) : ;;
            "")
                echo "error: $container is not on the engine, though the command that starts it returned" >&2
                report_container
                return 1
                ;;
            *)
                echo "error: $container is '$state' and will not become running" >&2
                report_container
                return 1
                ;;
        esac
        attempt=$((attempt + 1))
        sleep 1
    done
    echo "error: $container was still not running after ${attempts}s" >&2
    report_container
    return 1
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

# The id of a container by name, and the empty string when there is none.
# `docker inspect` exits non-zero on a container that is not there, which under
# `set -e` would abort the script on the very arm whose question is whether the
# container is there, so the absence is carried as a value instead.
container_id_of() {
    docker inspect --format '{{.Id}}' "$1" 2> /dev/null || true
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

# The absence half. It is only worth anything beside an affirmative arm on the
# same container, which is why the two `check` runs below are a pair: the same
# box, the same paths, and only the flag different. Without that, a probe that
# had stopped being taken at all would satisfy the absence and nothing here
# would notice.
expect_stream_lacks() {
    local what stream needle
    what="$1"
    stream="$2"
    needle="$3"
    if grep -qF -- "$needle" "$work/$stream"; then
        echo "error: $what: did not expect '$needle' on $stream" >&2
        show_subcommand
        return 1
    fi
    echo "ok: $what: $stream does not name '$needle'"
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

# The regex sibling of `expect_stream_contains`, for the one assertion whose
# passing evidence has two legitimate spellings and no common fixed substring
# that a failing spelling does not also carry. Fixed-string matching is the
# default everywhere else in this file on purpose -- a pattern can pass by
# matching less than its author meant -- so this exists for that single arm and
# its use is argued at the call site.
expect_stream_matches() {
    local what stream pattern
    what="$1"
    stream="$2"
    pattern="$3"
    if ! grep -qE -- "$pattern" "$work/$stream"; then
        echo "error: $what: expected /$pattern/ on $stream" >&2
        show_subcommand
        return 1
    fi
    echo "ok: $what: $stream matches /$pattern/"
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

echo "==> $image: status reports what it found"
run_subcommand /dev/null status
expect_code "status" 0
# The exit code alone is reachable by a subcommand that wrote nothing, which is
# why the document is held to naming something. There is no second writer of
# these bytes left to compare against: the byte-for-byte comparison this arm
# used to make was against `GET /status`, and that route is gone.
expect_stream_contains "status" stdout '"infrastructure"'

echo "==> $image: check reports the box ready"
run_subcommand /dev/null check
expect_code "check" 0
expect_stream_contains "check" stdout '"ready":true'
expect_stream_contains "check" stdout '"docker_socket"'
expect_container_log_contains "check" "$marker"
# A deployment that configures no cron is not asked about the cron divergence,
# and a probe that was not taken is absent from the document rather than
# recorded as having passed. The container cannot answer that question about
# itself, so a pass here would be a claim about two sources nobody compared.
# The affirmative arm is the very next run, on this same container.
expect_stream_lacks "check" stdout '"cron_divergence"'

echo "==> $image: check --cron-configured fails where there is no spool"
run_subcommand /dev/null check --cron-configured
expect_code "check --cron-configured" "$not_ready"
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
# The affirmative arm for the absence asserted above: the same container, the
# same paths, the flag the only difference, and the probe is in the document.
#
# It passes here, and the code above stays the not-ready one because of the
# spool alone. This container has no crontab and no payload directory, so both
# sources answer and they agree -- a host that fires none of Bondi's jobs and
# holds no job's files is not in disagreement with itself. That is what keeps
# this arm a pin on the readiness class rather than on whichever probe happened
# to fail: a deployment declaring cron against an image with no spool must still
# fail, and it still does.
expect_stream_contains "check --cron-configured" stdout '"cron_divergence"'

echo "==> $image: a payload that does not decode"
cp "$work/invalid-deploy.json" "$work/payload.json"
run_subcommand "$work/payload.json" deploy
expect_code "deploy" 2
expect_stream_contains "deploy" stderr 'invalid deploy payload'

echo "==> $image: a well-formed request Bondi cannot carry out"
cp "$work/unrunnable-run.json" "$work/payload.json"
run_subcommand "$work/payload.json" run
expect_code "run" 1
# The text is the engine's own report of a pull it could not make, so it is
# asserted to exist rather than transcribed: pinning its wording here would make
# this check fail on a Docker version that rephrased it.
expect_stream_nonempty "run" stderr

echo "==> $image: the run path"
# The base image is put on the engine here rather than assumed to be there.
# `run` creates its container through the Engine API, and `POST
# /containers/create` answers 404 "No such image" for an image that is not
# already local -- it does not pull, whatever the `docker run` CLI does on top
# of it [observed against Docker Engine 29.8.0 on 2026-09-13]. An arm that
# relied on the image being cached would pass on a box that had run this check
# before and fail on a fresh runner, which is the worse of the two orders.
if ! docker pull "$run_image" > /dev/null; then
    {
        echo "error: could not pull $run_image, which assertions 6 and 7 run as their job."
        echo "This is a dependency on the registry, not on the image under test."
        echo "Retry it on its own with:"
        echo "    docker pull $run_image"
    } >&2
    exit 1
fi
echo "ok: $run_image is on the engine"
printf '{"job": "%s", "image": "%s"}' "$run_job" "$run_image" \
    > "$work/run-job.json"
run_subcommand "$work/run-job.json" run
expect_code "run $run_job" 0
expect_stream_contains "run $run_job" stdout '"exit_code":0'
# The affirmative arm for the absence asserted below, on the same container and
# the same job. Without it a `run` that had stopped starting anything at all
# would satisfy the absence and nothing here would notice: there would be no
# predecessor, which is what the absence asks for.
first_run_id="$(container_id_of "$run_job")"
if [ -z "$first_run_id" ]; then
    {
        echo "error: run $run_job exited 0 but left no container named $run_job"
        echo "A run that completes renames its container into the job's name; a"
        echo "job with no container there did not run."
    } >&2
    show_subcommand
    exit 1
fi
echo "ok: run $run_job left the container $first_run_id"

run_subcommand "$work/run-job.json" run
expect_code "second run $run_job" 0
expect_stream_contains "second run $run_job" stdout '"exit_code":0'
second_run_id="$(container_id_of "$run_job")"
if [ -z "$second_run_id" ]; then
    echo "error: the second run of $run_job left no container named $run_job" >&2
    show_subcommand
    exit 1
fi
if [ "$second_run_id" = "$first_run_id" ]; then
    {
        echo "error: the second run of $run_job left the first run's container"
        echo "$first_run_id still holding the job's name, so the second run"
        echo "started nothing of its own."
    } >&2
    show_subcommand
    exit 1
fi
# The predecessor's absence, asked of the id the first run actually left rather
# than inferred from the second run's exit code. The cleanup is best effort and
# reports its failures in the response's `warning` field, which the exit code
# does not carry, so a run whose cleanup silently stopped happening still exits
# 0. This is the half `test_run.ml` cannot make: it pins the decision to clean
# up, and the engine having reaped the container is not a decision.
if docker inspect --format '{{.Id}}' "$first_run_id" > /dev/null 2>&1; then
    {
        echo "error: the first run's container $first_run_id is still on the engine"
        echo "after a second run of $run_job, which must have removed it."
    } >&2
    exit 1
fi
echo "ok: the second run of $run_job removed its predecessor $first_run_id"

case "$tls_handshake" in
    1 | true | yes | on)
        echo "==> $image: an outbound TLS handshake from inside the image"
        # `exit_code_severities` forces exit 0 into the failure severity, so the run
        # always routes an alert however the job ends, and the failure sink is a real
        # https endpoint, so the attempt performs a genuine handshake against the
        # system trust store. This is the class of defect that broke images 0.8.2
        # through 0.10.1 -- a runtime image missing something the binary needs at run
        # time -- which is why it is worth an arm rather than a unit test: the routing
        # is already pinned by `test_run.ml`, and the trust store is not routing.
        printf '{"job": "%s", "image": "%s", "exit_code_severities": {"failure": [0]}, "alert_sinks": {"critical": [], "failure": ["https://%s/alert"]}}' \
            "$tls_job" "$run_image" "$tls_sink_host" > "$work/run-tls.json"
        run_subcommand "$work/run-tls.json" run
        expect_code "run $tls_job" 0
        # Delivery is best effort and never changes the run's outcome, so the response
        # cannot carry this. The witness is the line `Alert_delivery` writes with
        # `Eio.traceln`, and traceln writes to the calling process's own stderr -- this
        # exec's, which `run_subcommand` captured -- not to PID 1's. It is therefore not
        # in `docker logs`: nothing on this path goes through `Diagnostics.write`, which
        # is the module that exists to put a line in the container log stream.
        #
        # Both accepted spellings require a status code to have come back, and a status
        # code comes back only over a completed TLS connection. Every way the handshake
        # can fail -- a trust store that would not load, a certificate that would not
        # verify, a connection that never opened, a sink that timed out -- writes a line
        # naming the host and carrying no status code, so matching the host alone would
        # be green on exactly the image this arm exists to reject. The host's dots are
        # escaped so the pattern cannot be satisfied by a look-alike host.
        #
        # Which of the two spellings appears is the sink's to decide and not this tree's,
        # which is why both are accepted rather than one pinned.
        #
        # Unanchored on purpose: `Eio.traceln` prefixes every line it writes with `+`,
        # and that prefix is not this arm's to pin. Anchoring the pattern at the start
        # of the line would fail the moment the prefix changed, or the moment these four
        # delivery sites moved onto `Diagnostics.write` -- which is an open question,
        # because they are the diagnostics that do not reach the container log.
        tls_sink_pattern="${tls_sink_host//./\\.}"
        expect_stream_matches "run $tls_job" stderr \
            "alert delivered to $tls_sink_pattern \(HTTP [0-9]+\)|alert delivery to $tls_sink_pattern failed: sink returned HTTP [0-9]+"
        ;;
    *)
        # Named, and named with the variable, so a run that skipped it cannot be
        # read as a run that made the handshake.
        echo "skipped: the outbound TLS handshake arm (BONDI_CHECK_TLS_HANDSHAKE=${tls_handshake:-unset})."
        echo "         It reaches $tls_sink_host over the network; set BONDI_CHECK_TLS_HANDSHAKE=1 to run it."
        ;;
esac

echo "==> $image: the command a client with cron jobs starts an orchestrator with"
start_container "$cron_command"

echo "==> $image: check --cron-configured succeeds where the spool is mounted"
run_subcommand /dev/null check --cron-configured
expect_code "check --cron-configured" 0
expect_stream_contains "check --cron-configured" stdout '"ready":true'
expect_stream_contains "check --cron-configured" stdout '"crontab_spool"'
# On the box that mounts the spool the divergence probe is taken and passes:
# the mounted crontab holds no Bondi section and no job has been deployed, so
# both sources answer and agree. A ready verdict that had simply dropped the
# probe would fail the line above it.
expect_stream_contains "check --cron-configured" stdout '"cron_divergence"'

echo "==> $image: the idling PID 1 answers the stop it is sent"
# Last, because it ends the container every assertion above ran in -- and it has
# to be this container rather than one started for the purpose, since what makes
# the arm worth anything is that PID 1 here is the idling binary itself, started
# by the client's own command.
#
# The event is induced rather than waited for: `docker stop` is the trigger, and
# it is the same trigger `bondi setup` pulls on every version bump. The
# affirmative half of the duration claim is the exit code beside it -- "it did
# not take too long" is satisfied by a container that was never up, and "it left
# 0" is satisfied by a container the daemon killed only if the daemon's kill
# leaves 0, which it does not. So the state before the stop is read, and the
# state, the code and the elapsed time after it.
running_before="$(docker inspect --format '{{.State.Running}}' "$container" 2> /dev/null || true)"
if [ "$running_before" != "true" ]; then
    {
        echo "error: $container was not running before the stop, so stopping it"
        echo "asserts nothing about whether a stop is answered."
    } >&2
    report_container
    exit 1
fi
# `SECONDS` rather than a timestamp pair: the two numbers being told apart are 0
# and 30, and a resolution of one second separates those with room to spare.
stop_started=$SECONDS
# `docker stop` exits 0 whether the container answered the signal or was killed
# at the timeout, so its own status is not the assertion; what it leaves behind
# is.
docker stop -t "$stop_timeout" "$container" > /dev/null
stop_elapsed=$((SECONDS - stop_started))
stop_state="$(docker inspect --format '{{.State.Status}}' "$container" 2> /dev/null || true)"
stop_code="$(docker inspect --format '{{.State.ExitCode}}' "$container" 2> /dev/null || true)"
if [ "$stop_state" != "exited" ]; then
    echo "error: $container is '$stop_state' after a stop, expected 'exited'" >&2
    report_container
    exit 1
fi
if [ "$stop_elapsed" -gt "$stop_deadline" ]; then
    {
        echo "error: $container took ${stop_elapsed}s to stop, past the ${stop_deadline}s"
        echo "this allows and at or near the ${stop_timeout}s the daemon waits before"
        echo "it gives up and sends SIGKILL. A PID 1 with no SIGTERM disposition of"
        echo "its own has the kernel discard the signal, which looks exactly like"
        echo "this: the stop succeeds, slowly, by being a kill."
    } >&2
    report_container
    exit 1
fi
if [ "$stop_code" != "0" ]; then
    {
        echo "error: $container left exit code $stop_code after being stopped,"
        echo "expected 0. 143 is death by SIGTERM's default action -- the handler"
        echo "was not installed -- and 137 is the daemon's SIGKILL, which is the"
        echo "signal being discarded."
    } >&2
    report_container
    exit 1
fi
echo "ok: $container answered docker stop in ${stop_elapsed}s and exited $stop_code"

echo "ok: $image answers on the command line what this tree says it answers"
