# shellcheck shell=bash
# `work`, `here`, `attempts` and `container` are the sourcing script's, and
# `deploy_arms` is read there.
# shellcheck disable=SC2154,SC2034
#
# The deploy arms of check-server-image.sh, and the fixture they deploy into.
# Sourced by that script once its `work`, `here`, `attempts` and `cleanup` are
# defined. Nothing here runs on being sourced but the derivations below; the
# functions run after its seventh assertion, while its no-cron orchestrator
# container is up.
#
# The fixture is a local registry, workload images pushed into it, the network a
# deploy attaches to and the Traefik a deploy adopts. It is shared, so an arm is
# one function and one entry in `deploy_arms`, and the assertions an arm makes are
# the three below it, not copies of them.

# Containers and the network the fixture makes carry this label, and the workload
# images it builds bake it in, so every container a deploy starts from one of them
# carries it too. Teardown removes by it. The value is this run's pid, so a run
# cannot remove another run's leavings.
fixture_label="check-server-image.fixture=$$"

# Every image this fixture pulls from a public registry is pinned by digest, for
# the reason the run arm's base image is: this script gates a publish, and a third
# party's tag moving under it is not something it can reason about. The digests are
# what `registry:2`, `traefik:v3.6.8` and `busybox:1.37.0` resolved to on
# 2026-11-16 [observed, Docker Engine 29.9.3]. The busybox image is both the
# workload's base and the probe: the run arm's Alpine has no `httpd` applet, and
# busybox's `wget` speaks HTTPS.
registry_image="registry@sha256:a3d8aaa63ed8681a604f1dea0aa03f100d5895b6a58ace528858a7b332415373"
traefik_image="traefik@sha256:90099f8948c828ecf0ababd711a4359a2443eba12261c1df2f548a3b1d815938"
busybox_image="busybox@sha256:a7dbc319b1438115a207e11930dc4bb3e643dcb3ec0bdd694bb36cd8fad289ec"

# The host port the registry is published on. It is 443 and not 80 because a
# reference with no port is pulled over HTTPS on 443: against a plain-HTTP registry
# on 80 the engine dialled 443 and was refused, and it does not fall back to HTTP
# [observed -- 2026-11-16, Docker Engine 29.9.3]. A reference with no port is the
# only kind a deploy can carry, because `Simple.parse_image_and_tag` splits on every
# colon. `localhost` is inside the engine's default insecure range, which is what
# lets the engine accept the registry's self-signed certificate.
registry_port=443

# A name the server spells in one place, taken from that place: the gate's network
# has to be the one a deploy attaches to, and its Traefik the one a deploy adopts,
# so a second spelling here would leave the fixture beside the deploy rather than
# under it. Anchored to the definition, and held to exactly one line, as the marker
# is in check-server-image.sh.
spelling_of() {
    local source binding value
    source="$1"
    binding="$2"
    value="$(sed -n "s/^let $binding = \"\\(.*\\)\"\$/\\1/p" "$source")"
    if [ -z "$value" ] || [ "$(printf '%s\n' "$value" | wc -l)" -ne 1 ]; then
        echo "error: could not derive '$binding' from $source" >&2
        return 1
    fi
    printf '%s\n' "$value"
}

fixture_network="$(spelling_of "$here/../lib/common/defaults.ml" network_name)"
fixture_traefik="$(spelling_of "$here/../lib/common/builtin_container.ml" traefik)"

# The arms, in the order they run. Each is a function taking no arguments that
# deploys on `$container` and asserts with the three `expect_` functions below.
deploy_arms=(arm_simple arm_blue_green)

# Refuse, naming what holds it, when the engine already has anything a deploy here
# would adopt or the registry would collide with. A deploy attaches to the network
# by name and adopts any container whose image contains `traefik`, running or not,
# so either would put an operator's own deployment under this gate's deploys. The
# check refuses rather than skips: a gate that skipped would report green having
# asserted nothing.
#
# Every holder is named, not only the first, so one run says everything that has to
# move. Nothing here removes or changes anything.
deploy_fixture_preconditions() {
    local held networks network_id containers traefik_holders listener publisher
    held=()

    # Listed and matched exactly, rather than asked of `docker network inspect`,
    # whose non-zero exit would not say whether the network is absent or the
    # engine did not answer. A listing that fails aborts here under `set -e`.
    networks="$(docker network ls --no-trunc --format '{{.ID}}\t{{.Name}}')"
    network_id="$(printf '%s\n' "$networks" | awk -F '\t' -v name="$fixture_network" '$2 == name { print $1 }')"
    if [ -n "$network_id" ]; then
        held+=("the network $fixture_network exists (id $network_id)")
    fi

    # The image field alone, as the server matches it: a container merely named
    # after Traefik is not one a deploy would adopt. `--no-trunc` is load-bearing.
    # Without it the CLI prints a container created from a digest reference with
    # the image's short id in place of `traefik@sha256:…`, while the Engine API
    # the server reads returns the reference, so the listing would miss exactly
    # the holder the server adopts [observed -- 2026-11-16, Docker Engine 29.9.3].
    containers="$(docker ps --all --no-trunc --format '{{.ID}}\t{{.Names}}\t{{.Image}}')"
    traefik_holders="$(printf '%s\n' "$containers" | awk -F '\t' 'index($3, "traefik") { print $1 " " $2 " (image " $3 ")" }')"
    if [ -n "$traefik_holders" ]; then
        while IFS= read -r line; do
            held+=("a container whose image contains 'traefik': $line")
        done <<< "$traefik_holders"
    fi

    # Two witnesses, because each misses a holder the other sees. `ss` sees any
    # listener in the host's namespace, a host-network container's included, but
    # names no process without root; `docker ps` names a container that publishes
    # the port and does not list a host-network one [both observed -- 2026-11-16,
    # Docker Engine 29.9.3]. An engine that publishes through firewall rules with
    # no userland proxy would leave nothing for `ss` to see [assumed, not observed
    # here], and `docker ps` still names the container then. `ss` exits 0 whether
    # or not anything matched, so its output is the test.
    if ! command -v ss > /dev/null; then
        echo "error: the deploy arms check host port $registry_port with ss, which is not on PATH (install iproute2)" >&2
        return 1
    fi
    listener="$(ss -ltnH "sport = :$registry_port")"
    listener="${listener//$'\n'/; }"
    publisher="$(docker ps --filter "publish=$registry_port" --format '{{.ID}} {{.Names}}')"
    publisher="${publisher//$'\n'/, }"
    if [ -n "$listener" ] || [ -n "$publisher" ]; then
        held+=("host port $registry_port is in use: ${publisher:-no container publishes it}; ss: ${listener:-no listener}")
    fi

    if [ "${#held[@]}" -ne 0 ]; then
        {
            echo "error: the deploy arms cannot run on this engine. They deploy into a network,"
            echo "a Traefik and a registry this check starts itself, and they touch nothing they"
            echo "did not start. On this engine, these are held already:"
            printf '  - %s\n' "${held[@]}"
            echo "Nothing was deployed and nothing was removed. Run this check on an engine"
            echo "without them."
        } >&2
        return 1
    fi
    echo "ok: no $fixture_network, no traefik container and nothing on host port $registry_port"
}

# What the fixture made, recorded as it is made, so that teardown removes those
# and nothing else. On a run the preconditions refused, every one of these is
# empty and teardown touches nothing: the network and Traefik an operator already
# had are never removed by name.
fixture_network_id=""
fixture_pulled=()
fixture_images=()

# The registry's name carries this run's pid, as `$container` does, so it cannot
# be an operator's container. The network and Traefik cannot: their names are the
# server's, which is what the preconditions are for.
fixture_registry="bondi-check-registry-$$"

# The workload: two repositories, each pushed at two tags. The healthcheck
# repository is the blue-green arm's, whose strategy waits for the new
# container's health check. Each tag is a different image, because it bakes
# the tag in as a label, so an assertion that a container runs at one tag cannot be
# satisfied by the other.
#
# They are pulled as `localhost/<name>:<tag>`, a reference with no port, from the
# registry above. Each tag is removed from the engine once pushed, so a deploy that
# runs one pulled it from the registry rather than finding it already here.
workload_repo="localhost/bondi-check-workload"
healthcheck_repo="localhost/bondi-check-workload-healthcheck"
workload_tags=(v1 v2)
workload_port=8080

# The reference a pinned image is pulled under is removed at teardown only when
# this run pulled it. An image that was on the engine before is someone else's.
pull_pinned() {
    local reference
    reference="$1"
    if docker image inspect "$reference" > /dev/null 2>&1; then
        echo "ok: $reference was on the engine already, and is left there"
        return 0
    fi
    fixture_pulled+=("$reference")
    if ! docker pull --quiet "$reference" > /dev/null; then
        {
            echo "error: could not pull $reference, which the deploy fixture runs."
            echo "This is a dependency on the registry, not on the image under test."
        } >&2
        return 1
    fi
    echo "ok: pulled $reference"
}

# The registry serves TLS under a certificate made for this run. The engine pulls
# a reference with no port over HTTPS only, and accepts this certificate because
# `localhost` is in its insecure range, which skips verification [observed --
# 2026-11-16, Docker Engine 29.9.3]. The certificate goes in with `docker cp` rather
# than a bind mount, so nothing depends on how the host labels its temporary
# directory. The registry is published on loopback only: it is reached as
# `localhost`, and a registry on every interface of a developer's box would be one
# anybody on the network could push to while this runs.
start_registry() {
    local certs registry_id attempt
    if ! command -v openssl > /dev/null; then
        echo "error: the deploy fixture makes its registry's certificate with openssl, which is not on PATH" >&2
        return 1
    fi
    certs="$work/registry-certs"
    mkdir "$certs"
    if ! openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=localhost \
        -addext subjectAltName=DNS:localhost,IP:127.0.0.1 \
        -keyout "$certs/key.pem" -out "$certs/cert.pem" 2> "$work/openssl-stderr"; then
        echo "error: openssl could not make the registry's certificate:" >&2
        cat "$work/openssl-stderr" >&2
        return 1
    fi
    registry_id="$(docker create --name "$fixture_registry" --label "$fixture_label" \
        --publish "127.0.0.1:$registry_port:5000" \
        --env REGISTRY_HTTP_TLS_CERTIFICATE=/certs/cert.pem \
        --env REGISTRY_HTTP_TLS_KEY=/certs/key.pem \
        "$registry_image")"
    docker cp "$certs" "$registry_id:/certs"
    docker start "$registry_id" > /dev/null
    # Asked from the host's network namespace, which is the one the engine pulls
    # from, rather than inferred from the container being up.
    attempt=0
    while [ "$attempt" -lt "$attempts" ]; do
        if docker run --rm --label "$fixture_label" --network host "$busybox_image" \
            wget -q -T 2 --no-check-certificate -O /dev/null "https://127.0.0.1:$registry_port/v2/" \
            > /dev/null 2>&1; then
            echo "ok: the registry $fixture_registry ($registry_id) answers on https://localhost:$registry_port"
            return 0
        fi
        attempt=$((attempt + 1))
        sleep 1
    done
    echo "error: the registry $fixture_registry did not answer on https://localhost:$registry_port after ${attempts}s" >&2
    docker logs "$registry_id" >&2 2>&1 || true
    return 1
}

# One workload image. At start it writes its own hostname as the page busybox
# `httpd` serves. The engine sets a container's hostname to its short id when the
# create body names none, and a deploy's names none, so a request through Traefik
# names the container that answered it [observed -- 2026-11-16, Docker Engine
# 29.9.3, a container run from this image by hand].
push_workload() {
    local repository tag healthcheck reference dockerfile
    repository="$1"
    tag="$2"
    healthcheck="$3"
    reference="$repository:$tag"
    dockerfile="$work/workload.Dockerfile"
    {
        printf 'FROM %s\n' "$busybox_image"
        printf 'LABEL %s check-server-image.workload-tag=%s\n' "$fixture_label" "$tag"
        case "$healthcheck" in
            healthcheck)
                printf 'HEALTHCHECK --interval=1s --timeout=2s --retries=3 CMD wget -q -O /dev/null http://127.0.0.1:%s/ || exit 1\n' "$workload_port"
                ;;
            no-healthcheck) : ;;
            *)
                echo "error: push_workload: expected healthcheck or no-healthcheck, got '$healthcheck'" >&2
                return 1
                ;;
        esac
        printf 'CMD ["sh", "-c", "mkdir -p /www && hostname > /www/index.html && exec httpd -f -p %s -h /www"]\n' "$workload_port"
    } > "$dockerfile"
    mkdir -p "$work/workload-context"
    # Recorded before it exists, so a build that fails half way is still removed.
    fixture_images+=("$reference")
    docker build --quiet --tag "$reference" --file "$dockerfile" "$work/workload-context" > /dev/null
    docker push --quiet "$reference" > /dev/null
    docker image rm "$reference" > /dev/null
    echo "ok: pushed $reference to the registry, and removed it from the engine"
}

deploy_fixture_up() {
    local tag
    pull_pinned "$registry_image"
    pull_pinned "$traefik_image"
    pull_pinned "$busybox_image"
    start_registry
    for tag in "${workload_tags[@]}"; do
        push_workload "$workload_repo" "$tag" no-healthcheck
        push_workload "$healthcheck_repo" "$tag" healthcheck
    done
    fixture_network_id="$(docker network create --label "$fixture_label" "$fixture_network")"
    echo "ok: created the network $fixture_network ($fixture_network_id)"
    start_traefik
}

# The gate's own Traefik, under the name the server gives the one it creates. It
# defines no certificate resolver and publishes no port. A router naming the
# undefined `bondi_resolver` that every service router carries is served with
# Traefik's default certificate, and nothing orders one [observed -- 2026-11-16,
# Traefik v3.6.8: one ERR line naming the resolver, no ACME activity]. So no Let's
# Encrypt request is made. The version check and the usage report are each turned
# off by name rather than left to Traefik's defaults, the first of which is on
# [observed -- `traefik --help` on this image prints `(Default: "true")`]: the
# gate's only traffic to a third party is the pinned pulls above.
#
# The payload an arm sends must name no `traefik_image` or `traefik_acme_email`,
# or the server would replace this Traefik with one that orders a certificate.
start_traefik() {
    local traefik_id attempt
    traefik_id="$(docker run --detach --name "$fixture_traefik" --label "$fixture_label" \
        --network "$fixture_network" \
        --volume /var/run/docker.sock:/var/run/docker.sock:ro \
        "$traefik_image" \
        --global.checknewversion=false \
        --global.sendanonymoususage=false \
        --providers.docker \
        --providers.docker.exposedbydefault=false \
        --entrypoints.websecure.address=:443)"
    # Up means routing: an unrouted host answered with Traefik's own 404, which is
    # a status only a listening Traefik gives. A refused connection is not up yet.
    attempt=0
    while [ "$attempt" -lt "$attempts" ]; do
        probe_request unrouted.invalid
        if [ "$probe_status" != 0 ] && grep -qF ' 404 ' "$work/probe-stderr"; then
            echo "ok: $fixture_traefik ($traefik_id) answers on $fixture_network: an unrouted host gets 404"
            return 0
        fi
        attempt=$((attempt + 1))
        sleep 1
    done
    {
        echo "error: $fixture_traefik did not answer on $fixture_network after ${attempts}s"
        echo "--- probe stderr ---"
        cat "$work/probe-stderr"
        echo "--- traefik logs ---"
        docker logs "$traefik_id" 2>&1 || true
    } >&2
    return 1
}

# The exit status of the last probe, kept here for the reason `subcommand_status`
# is: a function cannot both return it and be used under `set -e`.
probe_status=0

# A request through the gate's Traefik for one host, from a container on the
# gate's network, which is where a deploy's router serves. The certificate is not
# verified: it is Traefik's default one. The body lands in `$work/probe-body` and
# the diagnostics in `$work/probe-stderr`.
probe_request() {
    local host
    host="$1"
    probe_status=0
    docker run --rm --label "$fixture_label" --network "$fixture_network" "$busybox_image" \
        wget -q -T 5 --no-check-certificate -O - --header "Host: $host" "https://$fixture_traefik/" \
        > "$work/probe-body" 2> "$work/probe-stderr" || probe_status=$?
}

# The three assertions every arm makes, each by container id and never by exit
# code. Each takes the full id `container_id_of` returns, and refuses anything else:
# an empty or shortened id would let `expect_gone` pass for a container that was
# never named. Each caller returns on the refusal itself rather than leaving it to
# `set -e`, which does not fire inside a function called as a condition: an
# assertion run that way printed `ok:` for an empty id [observed -- 2026-11-16].
require_full_id() {
    case "$1" in
        "" | *[!0-9a-f]*)
            echo "error: $2: '$1' is not a container id" >&2
            return 1
            ;;
    esac
    if [ "${#1}" -ne 64 ]; then
        echo "error: $2: '$1' is not a full container id" >&2
        return 1
    fi
}

# The container runs, was created from the reference, and runs the image that
# reference names now. The last half is what tells two tags apart.
expect_running_at() {
    local id reference state running created_from image_id reference_id
    id="$1"
    reference="$2"
    require_full_id "$id" expect_running_at || return 1
    if ! state="$(docker container inspect --format '{{.State.Running}} {{.Config.Image}} {{.Image}}' "$id")"; then
        echo "error: expected $id running at $reference, and the engine has no such container" >&2
        return 1
    fi
    read -r running created_from image_id <<< "$state"
    if ! reference_id="$(docker image inspect --format '{{.Id}}' "$reference")"; then
        echo "error: expected $id running at $reference, and the engine has no image $reference" >&2
        return 1
    fi
    if [ "$running" != true ] || [ "$created_from" != "$reference" ] || [ "$image_id" != "$reference_id" ]; then
        {
            echo "error: expected $id running at $reference ($reference_id)"
            echo "  running: $running, created from: $created_from, image: $image_id"
        } >&2
        return 1
    fi
    echo "ok: $id is running $reference ($image_id)"
}

# The container is not on the engine, asked of a listing that succeeds on a
# healthy engine, so an engine that did not answer fails here rather than reading
# as an absence. The affirmative half is the caller's: the id must be one the arm
# saw running, through `expect_running_at`, before the deploy that should remove it.
expect_gone() {
    local id containers
    id="$1"
    require_full_id "$id" expect_gone || return 1
    containers="$(docker ps --all --quiet --no-trunc)"
    if printf '%s\n' "$containers" | grep -qxF -- "$id"; then
        echo "error: expected $id gone, and it is still on the engine" >&2
        docker ps --all --no-trunc --filter "id=$id" >&2 || true
        return 1
    fi
    echo "ok: $id is gone"
}

# A request for the host through the gate's Traefik is answered by the container,
# which serves its own short id. Retried, because Traefik learns of a new container
# from the engine's events on its own schedule, and only while the answer is not
# yet the one asked for.
expect_served_by() {
    local host id short body attempt
    host="$1"
    id="$2"
    require_full_id "$id" expect_served_by || return 1
    short="${id:0:12}"
    body=""
    attempt=0
    while [ "$attempt" -lt 10 ]; do
        probe_request "$host"
        body="$(cat "$work/probe-body")"
        if [ "$probe_status" = 0 ] && [ "$body" = "$short" ]; then
            echo "ok: a request for $host through $fixture_traefik was answered by $id"
            return 0
        fi
        attempt=$((attempt + 1))
        sleep 1
    done
    {
        echo "error: expected a request for $host through $fixture_traefik to be answered by $short"
        echo "  last answer: exit $probe_status, body '$body'"
        echo "--- probe stderr ---"
        cat "$work/probe-stderr"
    } >&2
    return 1
}

# One deploy of a service through `$container`, whose status and streams land
# where `run_subcommand` leaves them. The payload names the strategy, rather than
# leaving the server to choose one from whether the image has a health check.
# It names no `traefik_image` and no `traefik_acme_email`, so the server
# adopts the gate's Traefik rather than replacing it, and no registry credential,
# because the gate's registry takes none. Any arguments after the strategy are
# further payload members, each a JSON `"key": value` written as given, for the
# settings only one strategy reads.
deploy_service() {
    local service reference host strategy payload member
    service="$1"
    reference="$2"
    host="$3"
    strategy="$4"
    shift 4
    # The payload is written with printf, not a JSON encoder (the gate depends on
    # no jq), so a value that needed escaping would make invalid JSON the server
    # refuses far from the cause. Refuse it here, naming the value.
    for member in "$service" "$reference" "$host" "$strategy"; do
        case "$member" in
            *\"* | *\\*)
                echo "error: deploy_service was given a value containing a quote or backslash: $member" >&2
                return 1
                ;;
        esac
    done
    payload="$work/deploy-$service-${reference##*:}.json"
    {
        printf '{"service_name": "%s", "image": "%s", "port": %s, "traefik_domain_name": "%s", "deployment_strategy": "%s"' \
            "$service" "$reference" "$workload_port" "$host" "$strategy"
        for member in "$@"; do
            printf ', %s' "$member"
        done
        printf '}'
    } > "$payload"
    run_subcommand "$payload" deploy
}

# The service the `simple` arm deploys. Its name carries this run's pid, as the
# registry's does, because a deploy stops and removes whatever container already
# has the service's name: a name an operator might use would have this check
# remove their container. The host is under `.invalid`, which resolves nowhere,
# so the router it makes can only be reached through the gate's Traefik.
simple_service="bondi-check-simple-$$"
simple_host="simple.check-server-image.invalid"

# The `simple` strategy moves a service from one tag to the next by replacing its
# container, and a deploy of a tag the registry does not have leaves the running
# container serving. The v1 container is seen running before the deploy that
# should remove it, so its absence afterwards is a removal and not a container
# that never was.
arm_simple() {
    local v1 v2 missing v1_id v2_id
    v1="$workload_repo:v1"
    v2="$workload_repo:v2"
    # A tag of the same repository the registry holds two tags of, and never
    # pushed, so the pull reaches the registry and is refused by it.
    missing="$workload_repo:never-pushed"

    echo "==> $image: a simple deploy of $v1, then of $v2"
    deploy_service "$simple_service" "$v1" "$simple_host" simple
    expect_code "deploy $v1" 0
    v1_id="$(container_id_of "$simple_service")"
    expect_running_at "$v1_id" "$v1"
    deploy_service "$simple_service" "$v2" "$simple_host" simple
    expect_code "deploy $v2" 0
    v2_id="$(container_id_of "$simple_service")"
    expect_running_at "$v2_id" "$v2"
    expect_gone "$v1_id"
    expect_served_by "$simple_host" "$v2_id"

    echo "==> $image: a simple deploy of $missing, a tag the registry does not have"
    deploy_service "$simple_service" "$missing" "$simple_host" simple
    # Exactly the failure to carry out a well-formed request. A refusal of the
    # request as written exits 2 before any pull, and the container would then be
    # left serving because nothing was attempted, not because a failed pull leaves
    # it in place. The tag on stderr ties the failure to that pull, rather than to
    # some earlier step that also fails this way and also leaves it serving. It is
    # the engine's refusal that names the tag, so the tag alone is asserted and
    # the engine's wording around it is not.
    expect_code "deploy $missing" 1
    expect_stream_contains "deploy $missing" stderr never-pushed
    expect_running_at "$v2_id" "$v2"
    expect_served_by "$simple_host" "$v2_id"
}

# The service the `blue-green` arm deploys, named and hosted apart from the
# `simple` arm's for the same reasons, so that neither arm's container is the
# other's current workload.
blue_green_service="bondi-check-blue-green-$$"
blue_green_host="blue-green.check-server-image.invalid"

# The `blue-green` strategy starts the next tag beside the running container, waits
# for its health check, moves traffic to it and only then removes the old one, so
# its image is the repository that declares a `HEALTHCHECK`. The settings the wait
# and the switch read are stated rather than left to the server: a health check
# that never passes fails here in half a minute, not in the server's two.
#
# The new container is started under a temporary name and renamed once the old one
# is gone, so the v2 id is read under the service's own name, after the deploy: an
# id that only the temporary name held would mean the switch never finished.
arm_blue_green() {
    local v1 v2 v1_id v2_id settings
    v1="$healthcheck_repo:v1"
    v2="$healthcheck_repo:v2"
    settings=('"health_timeout": 30.0' '"poll_interval": 1.0' '"drain_grace_period": 2.0')

    echo "==> $image: a blue-green deploy of $v1, then of $v2"
    deploy_service "$blue_green_service" "$v1" "$blue_green_host" blue-green "${settings[@]}"
    expect_code "deploy $v1" 0
    v1_id="$(container_id_of "$blue_green_service")"
    expect_running_at "$v1_id" "$v1"
    deploy_service "$blue_green_service" "$v2" "$blue_green_host" blue-green "${settings[@]}"
    expect_code "deploy $v2" 0
    v2_id="$(container_id_of "$blue_green_service")"
    expect_running_at "$v2_id" "$v2"
    expect_gone "$v1_id"
    expect_served_by "$blue_green_host" "$v2_id"
}

# Remove every container an arm's deploys started, between one arm and the next.
# They are the containers carrying both this run's label and the tag label the
# workload images bake in, so the registry, the Traefik and the probes are left.
# Every service router is named `bondi`, whatever the service, so a container left
# from one arm puts a second definition of that router beside the next arm's, under
# a different rule, and Traefik then serves neither: with the `simple` arm's v2
# left up, the `blue-green` arm's host got 404 [observed -- 2026-11-16, Traefik
# v3.6.8]. The removal is asserted by listing, so a container that survived it
# fails here rather than as an unrouted request in the arm after.
remove_arm_workloads() {
    local containers id
    containers="$(docker ps --all --quiet --no-trunc --filter "label=$fixture_label" --filter label=check-server-image.workload-tag)"
    for id in $containers; do
        docker rm --force --volumes "$id" > /dev/null
        echo "ok: removed the arm's container $id"
    done
    containers="$(docker ps --all --quiet --no-trunc --filter "label=$fixture_label" --filter label=check-server-image.workload-tag)"
    if [ -n "$containers" ]; then
        echo "error: the arm's containers are still on the engine after their removal: $containers" >&2
        return 1
    fi
}

# Remove what the fixture made: every container carrying this run's label (the
# fixture's own and every container a deploy started from its images, with their
# anonymous volumes, which the registry declares), then the network it created,
# then the images it pushed or pulled. It reports and fails on what it could not
# remove; `cleanup` calls it again, silenced, as the backstop on any exit.
deploy_fixture_down() {
    local containers id reference failed
    failed=0
    containers="$(docker ps --all --quiet --no-trunc --filter "label=$fixture_label")"
    for id in $containers; do
        if docker rm --force --volumes "$id" > /dev/null; then
            echo "ok: removed the container $id"
        else
            failed=1
        fi
    done
    if [ -n "$fixture_network_id" ]; then
        if docker network rm "$fixture_network_id" > /dev/null; then
            echo "ok: removed the network $fixture_network ($fixture_network_id)"
            fixture_network_id=""
        else
            failed=1
        fi
    fi
    for reference in ${fixture_images[@]+"${fixture_images[@]}"} ${fixture_pulled[@]+"${fixture_pulled[@]}"}; do
        if docker image inspect "$reference" > /dev/null 2>&1; then
            if docker image rm "$reference" > /dev/null; then
                echo "ok: removed the image $reference"
            else
                failed=1
            fi
        fi
    done
    fixture_images=()
    fixture_pulled=()
    containers="$(docker ps --all --quiet --no-trunc --filter "label=$fixture_label")"
    if [ "$failed" != 0 ] || [ -n "$containers" ]; then
        echo "error: the deploy fixture could not remove everything it made" >&2
        return 1
    fi
    echo "ok: the deploy fixture is torn down"
}
