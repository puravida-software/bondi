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
# deploy attaches to and the Traefik a deploy adopts. Beside those it holds what a
# deploy that replaces Traefik needs: a copy of the pinned Traefik that trusts
# Pebble, an ACME test server on the network, and the host's acme.json, which a
# Traefik the server creates binds. It is shared, so an arm is
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
# Pebble, the ACME test server, whose certificates the gate's Traefik copy below is
# built to trust, so that a Traefik a deploy creates from it can be pointed at a
# certificate server that is not Let's Encrypt. The digest is what
# `ghcr.io/letsencrypt/pebble:latest` resolved to on 2026-11-19 [observed, Docker
# Engine 29.10.0].
pebble_image="ghcr.io/letsencrypt/pebble@sha256:0c81f05db371f436c97fb894bd6d2ab8fc9c8e2ce40f8bef8a8e15941bcd75ef"
# Python, the base of the drain workload and of the clients the swap and upload
# arms send their requests from, because those need a listener closed on
# SIGTERM, threads and a digest over a body, which busybox cannot give. The
# digest is the index Docker Hub served for `python:3-alpine` (Python 3.14.7) on
# 2026-11-22 [observed, Docker Engine 29.10.0].
python_image="python@sha256:c6ead215bfd31f1e433d968853b7a769989117115b728874824e6c0a27cb96fc"
# Loki, which the failed-candidate logs arm reads to see what its Alloy delivered.
# The digest is the index Docker Hub served for `grafana/loki:3.7.9`, the Loki the
# real-Alloy suite runs, on 2026-11-24 [observed, Docker Engine 29.10.0].
loki_image="grafana/loki@sha256:0db216b630ae1f348a1584c67f3cead8b4c1fc839169a39501db664744158e28"

# The host port the registry is published on, and so the port every workload
# reference names: a deploy carries `localhost:<port>/<name>:<tag>`, which is the
# `host:port` form of a registry reference. It is neither 80 nor 443, because a
# Traefik the server creates publishes both, and a registry on either would collide
# with it. The engine pulled a reference to this registry on this port over HTTPS
# and accepted its self-signed certificate, because `localhost` is inside its
# default insecure range [observed -- 2026-11-19, a registry run as this fixture
# runs it, published on 127.0.0.1:5443].
registry_port=5443

# A second registry, behind htpasswd, for the one arm that deploys with registry
# credentials. Its own port, because the first registry takes none and every other
# arm pulls from it. The credentials are fixed and mean nothing outside this
# gate's loopback listener. They are chosen so that the base64url encoding of the
# auth JSON a deploy sends the Engine holds both `-` and `_`, the two characters
# that differ from standard base64, and ends in padding: only a `>` or `~` and a
# `?` in the password, each as the third byte of a group, can put them there, since
# an ASCII byte's high bit is 0. The arm asserts that, rather than trusting this
# comment. The hash is bcrypt, the only scheme the registry reads, of the password
# below at cost 4 [observed -- 2026-11-21: `htpasswd -nbB -C 4`, Apache 2.4].
auth_registry_port=5444
auth_registry_user=gate
auth_registry_pass='gate~aa?aa'
# shellcheck disable=SC2016
auth_registry_htpasswd='gate:$2y$04$ZldgGQWJPe1Mh3p/T5ywm.xCCqj75y0eI0.ZtJFp6zbcgDKZR9yri'

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
# The Alloy setup runs on a box, by the tag setup names it with. It is the one
# public image here not pinned by digest, because it is not the fixture's: it is
# half of what the failed-candidate logs arm checks, with the config below, and a
# digest here would be a second spelling of the version setup ships.
alloy_image="$(spelling_of "$here/../lib/common/defaults.ml" alloy_image)"
# The config that Alloy runs over: the generator's output, committed beside this
# script and kept equal to the generator by a dune diff, because the gate runs
# where there is no OCaml toolchain. Its endpoint is `127.0.0.1:3100`, the Loki
# whose network namespace the arm runs Alloy in.
alloy_config="$here/alloy-config.alloy"

# The host path a Traefik the server creates binds its certificate store from,
# taken from the server's bind list for the reason the names above are: a file the
# gate made anywhere else would leave the deploy's bind to make a directory in its
# place. It must be a file two directories below /etc, because the gate reads and
# removes it through /etc bound into a container, and removes at most those two
# directories after it.
acme_path_of() {
    local source value
    source="$1"
    value="$(sed -n 's|^ *"\(/[^:"]*\):/acme/acme\.json";$|\1|p' "$source")"
    if [ -z "$value" ] || [ "$(printf '%s\n' "$value" | wc -l)" -ne 1 ]; then
        echo "error: could not derive the acme.json bind's host path from $source" >&2
        return 1
    fi
    case "$value" in
        /etc/*/*/*/*) ;;
        /etc/*/*/*)
            printf '%s\n' "$value"
            return 0
            ;;
    esac
    echo "error: the acme.json bind's host path $value, from $source, is not a file two directories below /etc" >&2
    return 1
}

# The flag a Traefik the server creates is given for how long it dials a backend
# before it resends the request, taken from the server's source for the reason the
# names above are: the swap arm measures what a deploy does behind that Traefik,
# and a second spelling here would measure it behind another. The fixture's own
# Traefik adds this flag to its command and no other of the server's, since the
# others (certificates, the redirect, the published ports) do not change how a
# request reaches a backend.
dial_timeout_flag="$(spelling_of "$here/../lib/server/docker/traefik.ml" dial_timeout_flag)"

acme_host_path="$(acme_path_of "$here/../lib/server/docker/traefik.ml")"
# The same three paths relative to /etc, as the probe below is given them: the
# file, then its directory, then that directory's, so the directories are deepest
# first, the order they are removed in.
acme_rel="${acme_host_path#/etc/}"
acme_rel_dirs=("${acme_rel%/*}" "${acme_rel%/*/*}")

# The arms, in the order they run. Each is a function taking no arguments that
# deploys on `$container` and asserts with the three `expect_` functions below.
#
# An arm's containers are left serving while the arms after it run, and are
# removed only at teardown. Each service's router and load-balancer service are
# named after the service, so the services already deployed sit beside the next
# arm's on one Traefik rather than competing with it for one router.
# `arm_two_services` asserts that directly; every later arm depends on it.
#
# `arm_traefik_replaced` runs second to last, because it has a deploy replace the
# gate's Traefik with one the server creates: every arm before it asserts through
# the gate's own. `arm_blue_green_traefik_replaced` runs after it, because it
# asks for a Traefik image other than the one that arm left running.
#
# The swap and upload arms run before both, through the gate's Traefik, which
# defines its routers from container labels alone: the retry middleware they
# depend on is the one every deploy labels its router with.
deploy_arms=(arm_simple arm_blue_green arm_blue_green_first_fails
    arm_blue_green_new_fails arm_blue_green_new_fails_logs arm_two_services
    arm_pull_stream_fails
    arm_registry_credentials arm_traefik_pull_fails arm_blue_green_swap
    arm_blue_green_upload arm_traefik_replaced arm_blue_green_traefik_replaced)

# The arms that run on an engine with neither the network a deploy attaches to
# nor a Traefik, before the fixture makes either: the registry, the workload
# images and Pebble are up, and nothing a deploy would adopt is. Each tears down
# what its deploys created before the fixture's network and Traefik come up.
fresh_box_arms=(arm_blue_green_fresh)

# The host ports the fixture needs free: 80 and 443, which a Traefik the server
# creates publishes on every interface, and the two registries'.
fixture_host_ports=(80 443 "$registry_port" "$auth_registry_port")

# The id of the network of that name, and the empty string when there is none.
# Listed and matched exactly, rather than asked of `docker network inspect`,
# whose non-zero exit would not say whether the network is absent or the engine
# did not answer. A listing that fails is returned explicitly, because this runs
# inside a command substitution, where `set -e` does not reach, and an empty
# answer from it would read as an absence.
network_id_of() {
    local networks
    if ! networks="$(docker network ls --no-trunc --format '{{.ID}}\t{{.Name}}')"; then
        echo "error: the engine did not list its networks" >&2
        return 1
    fi
    printf '%s\n' "$networks" | awk -F '\t' -v name="$1" '$2 == name { print $1 }'
}

# Refuse, naming what holds it, when the engine already has anything a deploy here
# would adopt or the registry or a Traefik the server creates would collide with,
# its host's acme.json included.
# A deploy attaches to the network by name and takes the container under
# Traefik's name for its proxy, running or not, whatever its image, so either
# would put an operator's own deployment under this gate's deploys. A container
# whose image contains `traefik` is refused as well: a deploy does not take it
# for the proxy, but it is an operator's proxy all the same, and refusing it
# removes nothing. The check refuses rather than skips: a gate that skipped would
# report green having asserted nothing.
#
# Every holder is named, not only the first, so one run says everything that has to
# move. Nothing here removes or changes anything, and no docker call it makes has
# an effect that outlives the run: the one image it may pull is recorded for
# teardown, and the one container it runs removes itself.
deploy_fixture_preconditions() {
    local held network_id containers traefik_holders port listener publisher
    local acme_state dir tool
    held=()

    # Every tool the arms call outside docker, refused before anything is pulled,
    # made or written: a tool found missing half way would leave the host as the
    # run had changed it.
    for tool in curl openssl timeout sha256sum base64; do
        if ! command -v "$tool" > /dev/null; then
            echo "error: the deploy arms need $tool, which is not on PATH" >&2
            return 1
        fi
    done

    network_id="$(network_id_of "$fixture_network")"
    if [ -n "$network_id" ]; then
        held+=("the network $fixture_network exists (id $network_id)")
    fi

    # The name exactly, as the server finds its proxy: a container whose name
    # merely contains Traefik's is not one a deploy would take.
    # `--no-trunc` is load-bearing for the image match below. Without it the CLI
    # prints a container created from a digest reference with the image's short
    # id in place of `traefik@sha256:…`, while the Engine API returns the
    # reference [observed -- 2026-11-16, Docker Engine 29.9.3].
    containers="$(docker ps --all --no-trunc --format '{{.ID}}\t{{.Names}}\t{{.Image}}')"
    traefik_holders="$(printf '%s\n' "$containers" | awk -F '\t' -v name="$fixture_traefik" '$2 == name { print $1 " (image " $3 ")" }')"
    if [ -n "$traefik_holders" ]; then
        while IFS= read -r line; do
            held+=("a container named '$fixture_traefik': $line")
        done <<< "$traefik_holders"
    fi
    traefik_holders="$(printf '%s\n' "$containers" | awk -F '\t' 'index($3, "traefik") { print $1 " " $2 " (image " $3 ")" }')"
    if [ -n "$traefik_holders" ]; then
        while IFS= read -r line; do
            held+=("a container whose image contains 'traefik': $line")
        done <<< "$traefik_holders"
    fi

    # A Traefik the server creates binds the host's acme.json, so one already
    # there is a certificate store some other Traefik owns: a deploy here would
    # bind it, and this fixture's teardown would remove it. Anything at the path
    # is refused, a directory included, which is what the engine leaves when the
    # bind is made before the file. The host is the engine's, so it is read
    # through a container, never from this shell, which need not share its
    # filesystem. That container runs the pinned busybox, pulled first if the
    # engine lacks it and then recorded like every pinned pull, so teardown
    # removes it and a refused run leaves the engine as it found it. Which
    # directories already stand is recorded here too, before anything could
    # create them: teardown removes only the ones this run made.
    pull_pinned "$busybox_image"
    acme_before="$(host_etc_state "$acme_rel" "${acme_rel_dirs[@]}")"
    acme_state="$(state_in "$acme_before" "$acme_rel")"
    if [ "$acme_state" != absent ]; then
        held+=("$acme_host_path exists on the engine's host ($(described "$acme_state"))")
    fi
    acme_absent_dirs=()
    for dir in "${acme_rel_dirs[@]}"; do
        if [ "$(state_in "$acme_before" "$dir")" = absent ]; then
            acme_absent_dirs+=("$dir")
        fi
    done

    # Two witnesses, because each misses a holder the other sees. `ss` sees any
    # listener in the host's namespace, a host-network container's included, but
    # names no process without root; `docker ps` names a container that publishes
    # the port and does not list a host-network one [both observed -- 2026-11-16,
    # Docker Engine 29.9.3]. An engine that publishes through firewall rules with
    # no userland proxy would leave nothing for `ss` to see [assumed, not observed
    # here], and `docker ps` still names the container then. `ss` exits 0 whether
    # or not anything matched, so its output is the test.
    if ! command -v ss > /dev/null; then
        echo "error: the deploy arms check host ports ${fixture_host_ports[*]} with ss, which is not on PATH (install iproute2)" >&2
        return 1
    fi
    for port in "${fixture_host_ports[@]}"; do
        listener="$(ss -ltnH "sport = :$port")"
        listener="${listener//$'\n'/; }"
        publisher="$(docker ps --filter "publish=$port" --format '{{.ID}} {{.Names}}')"
        publisher="${publisher//$'\n'/, }"
        if [ -n "$listener" ] || [ -n "$publisher" ]; then
            held+=("host port $port is in use: ${publisher:-no container publishes it}; ss: ${listener:-no listener}")
        fi
    done

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
    echo "ok: no $fixture_network, no traefik container, nothing on host ports ${fixture_host_ports[*]} and no $acme_host_path"
}

# What the fixture made, recorded as it is made, so that teardown removes those
# and nothing else. On a run the preconditions refused, every one of these is
# empty and teardown touches nothing: the network and Traefik an operator already
# had are never removed by name.
fixture_network_id=""
fixture_pulled=()
fixture_images=()
# The host's acme.json and its two directories, as the preconditions read them
# before anything was made: the probe's answer, and the directories it found
# absent, deepest first. `acme_created` is set from the moment the create is
# issued, so a create that made the directories and failed before the file is
# still undone; a refused run never sets it, and its teardown touches nothing on
# the host.
acme_before=""
acme_absent_dirs=()
acme_created=""

# The registry's name carries this run's pid, as `$container` does, so it cannot
# be an operator's container. The network and Traefik cannot: their names are the
# server's, which is what the preconditions are for.
fixture_registry="bondi-check-registry-$$"
# The directory the registry's certificate is made in, and so what a request made
# to it from this shell trusts. Set by `start_registry`, because `work` is not
# defined until the sourcing script runs.
registry_certs=""

# The workload: two repositories, each pushed at two tags. The healthcheck
# repository is the blue-green arm's, whose strategy waits for the new
# container's health check. Each tag is a different image, because it bakes
# the tag in as a label, so an assertion that a container runs at one tag cannot be
# satisfied by the other.
#
# They are pulled as `localhost:<port>/<name>:<tag>` from the registry above, so
# every deploy here carries a reference with a registry port. Each tag is removed
# from the engine once pushed, so a deploy that runs one pulled it from the
# registry rather than finding it already here.
workload_repo="localhost:$registry_port/bondi-check-workload"
healthcheck_repo="localhost:$registry_port/bondi-check-workload-healthcheck"
# A third repository, pushed at one tag, whose health check never passes though
# it serves as the others do: the failed blue-green arms deploy it. It prints the
# marker below as its first line, which no other workload prints, so a line
# carrying it in Loki came from a container of this image. The pid makes it this
# run's.
unhealthy_repo="localhost:$registry_port/bondi-check-workload-unhealthy"
unhealthy_marker="bondi-check-unhealthy-started-$$"
workload_tags=(v1 v2)
workload_port=8080
# The drain workload, pushed at the same two tags, which the swap and upload arms
# deploy blue-green: `drain/app.py` beside this script, which says what it
# serves and what it does on SIGTERM. Its health check is a production one
# rather than the other workloads' one-second check: probed every ten seconds
# once healthy, and unhealthy only after three failures, so a container that is
# stopped leaves Traefik on its `die` event, before its health check could fail
# [observed for this order in a hand-run swap -- 2026-11-22, Traefik v3.6.8: the
# one event Traefik took for the old container was `die`]. During its start
# period it is probed every second, so a new one passes within about a second.
drain_repo="localhost:$registry_port/bondi-check-drain"
drain_source="$here/drain"
# The image the clients run from: the echo, the request stream and the uploads,
# built on the engine and never pushed, because no deploy names it.
drain_client_image="bondi-check-drain-client:$$"

# The reference a pinned image is pulled under is removed at teardown only when
# this run pulled it. An image that was on the engine before is someone else's.
pull_pinned() {
    local reference pulled
    reference="$1"
    for pulled in ${fixture_pulled[@]+"${fixture_pulled[@]}"}; do
        if [ "$pulled" = "$reference" ]; then
            echo "ok: $reference was pulled by this run already"
            return 0
        fi
    done
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

# What stands at each path given, relative to the engine host's /etc, one line per
# path: the path, then `absent`, or its type, mode, owner and size as busybox
# `stat` prints them (`traefik/acme/acme.json|regular empty file|600|root:root|0`).
# Read through /etc bound read-only into a container that removes itself, because
# the host is the engine's and this shell need not share its filesystem. A
# dangling link counts as present: the create would write through it. The answer
# must hold exactly one line for each path asked, so a probe that printed nothing
# cannot read as everything absent. Every failure is returned explicitly, because
# teardown calls this as a condition, where `set -e` does not reach.
host_etc_state() {
    local answer path lines
    if ! answer="$(docker run --rm --pull never --label "$fixture_label" \
        --mount type=bind,src=/etc,dst=/host-etc,readonly "$busybox_image" \
        sh -c 'for p in "$@"; do if [ -e "/host-etc/$p" ] || [ -L "/host-etc/$p" ]; then printf "%s|%s\n" "$p" "$(stat -c "%F|%a|%U:%G|%s" "/host-etc/$p")"; else printf "%s|absent\n" "$p"; fi; done' \
        _ "$@")"; then
        echo "error: could not read $* under the engine host's /etc" >&2
        return 1
    fi
    if [ "$(printf '%s\n' "$answer" | wc -l)" -ne "$#" ]; then
        echo "error: reading $* under the engine host's /etc answered $(printf '%s\n' "$answer" | wc -l) lines, not $#: $answer" >&2
        return 1
    fi
    for path in "$@"; do
        lines="$(printf '%s\n' "$answer" | awk -F '|' -v p="$path" '$1 == p { n++ } END { print n + 0 }')"
        if [ "$lines" -ne 1 ]; then
            echo "error: reading $path under the engine host's /etc answered no single line for it: $answer" >&2
            return 1
        fi
    done
    printf '%s\n' "$answer"
}

# The state one path has in an answer of `host_etc_state`: `absent`, or its type,
# mode, owner and size joined by `|`.
state_in() {
    printf '%s\n' "$1" | awk -F '|' -v p="$2" '$1 == p { sub(/^[^|]*\|/, ""); print }'
}

# A state of `state_in`, as a refusal or a report words it.
described() {
    printf '%s\n' "$1" | awk -F '|' '$1 == "absent" { print "absent"; next } { print $1 ", mode " $2 ", " $4 " bytes, owned by " $3 }'
}

# Type and mode alone: what teardown compares a directory that stood before the run
# against, since a directory's size can move with entries made and removed in it.
kind_of() {
    printf '%s\n' "$1" | awk -F '|' '{ print $1 "|" $2 }'
}

# The host's acme.json, made empty and of mode 600 before any Traefik binds it. A
# bind of a missing file makes a directory in its place, and Traefik refuses a
# store more open than 600 and does not create a missing one [observed --
# 2026-11-19, Traefik v3.6.8]. It is made through a throwaway container that binds
# its directory, which the engine creates as needed, so nothing here needs `sudo`.
# What it made is then read back and asserted, not inferred from the exit code.
create_acme_json() {
    local file after state dir
    file="${acme_host_path##*/}"
    # Recorded before it exists, as a pushed image is.
    acme_created=yes
    docker run --rm --pull never --label "$fixture_label" \
        --volume "${acme_host_path%/*}:/acme" "$busybox_image" \
        sh -c 'touch "/acme/$1" && chmod 600 "/acme/$1"' _ "$file"
    after="$(host_etc_state "$acme_rel" "${acme_rel_dirs[@]}")"
    state="$(state_in "$after" "$acme_rel")"
    case "$state" in
        "regular empty file|600|"*"|0") ;;
        *)
            echo "error: expected $acme_host_path an empty regular file of mode 600, and it is $(described "$state")" >&2
            return 1
            ;;
    esac
    echo "ok: created $acme_host_path through a throwaway container: $(described "$state")"
    for dir in ${acme_absent_dirs[@]+"${acme_absent_dirs[@]}"}; do
        echo "ok: the create made /etc/$dir: $(described "$(state_in "$after" "$dir")")"
    done
}

# Teardown's half for acme.json: remove the file and then, deepest first, only the
# directories that were absent before the run, then read the host back and assert
# every path is as the preconditions found it. `rmdir` removes nothing that is not
# an empty directory, so a directory something else wrote into is reported, not
# emptied. Returns 1 on any difference, having said what it is; it is called as a
# condition, so every failure is returned explicitly.
remove_acme_json() {
    local after path before_state after_state differs
    if ! docker run --rm --pull never --label "$fixture_label" \
        --mount type=bind,src=/etc,dst=/host-etc "$busybox_image" \
        sh -c 'rm -f "/host-etc/$1" && shift && for dir in "$@"; do rmdir "/host-etc/$dir" || exit 1; done' \
        _ "$acme_rel" ${acme_absent_dirs[@]+"${acme_absent_dirs[@]}"}; then
        echo "error: could not remove $acme_host_path and the directories this run made for it" >&2
        return 1
    fi
    if ! after="$(host_etc_state "$acme_rel" "${acme_rel_dirs[@]}")"; then
        return 1
    fi
    differs=0
    for path in "$acme_rel" "${acme_rel_dirs[@]}"; do
        before_state="$(state_in "$acme_before" "$path")"
        after_state="$(state_in "$after" "$path")"
        if [ "$(kind_of "$before_state")" != "$(kind_of "$after_state")" ]; then
            echo "error: /etc/$path was $(described "$before_state") before the run, and is $(described "$after_state") after it" >&2
            differs=1
        fi
    done
    if [ "$differs" != 0 ]; then
        return 1
    fi
    echo "ok: $acme_host_path is gone, and the host's /etc is as it was before the run"
}

# Pebble, started on the engine's default bridge before the network a deploy
# attaches to exists, because the fresh-box arms need it while that network is
# absent. It joins that network under the alias its own TLS certificate names,
# through `join_pebble`, each time the network is made, so a container there
# reaches its directory at `pebble_directory`. It is told to treat every
# challenge as valid, because nothing outside that network can reach a host the
# arms name. Up means its directory answers, asked inside Pebble's own network
# namespace rather than inferred from the container running; that it answers
# under the alias is what the issuance assertions show.
fixture_pebble="bondi-check-pebble-$$"
pebble_directory="https://pebble:14000/dir"
start_pebble() {
    local pebble_id attempt
    pebble_id="$(docker run --detach --name "$fixture_pebble" --label "$fixture_label" \
        --env PEBBLE_VA_ALWAYS_VALID=1 \
        "$pebble_image")"
    attempt=0
    while [ "$attempt" -lt "$attempts" ]; do
        if docker run --rm --label "$fixture_label" --network "container:$fixture_pebble" "$busybox_image" \
            wget -q -T 2 --no-check-certificate -O - "https://localhost:14000/dir" \
            > "$work/pebble-directory" 2> /dev/null \
            && grep -qF '"newOrder"' "$work/pebble-directory"; then
            echo "ok: $fixture_pebble ($pebble_id) serves its ACME directory"
            return 0
        fi
        attempt=$((attempt + 1))
        sleep 1
    done
    {
        echo "error: $fixture_pebble did not serve its ACME directory after ${attempts}s"
        echo "--- pebble logs ---"
        docker logs "$pebble_id" 2>&1 || true
    } >&2
    return 1
}

# Pebble joins the network a deploy attaches to, under the alias its directory
# is named by.
join_pebble() {
    docker network connect --alias pebble "$fixture_network" "$fixture_pebble"
    echo "ok: $fixture_pebble joined $fixture_network as pebble"
}

# The gate's copy of the pinned Traefik image, which trusts Pebble's CA: Pebble's
# image carries the CA that signs its TLS certificate, and the copy appends it to
# the bundle Traefik verifies a certificate server against [observed --
# 2026-11-19: the unmodified image refused Pebble's directory as signed by an
# unknown authority, and this copy registered and was issued a certificate]. It
# bakes in this run's label, so a Traefik a deploy creates from it is removed at
# teardown. It is pushed at two tags, because a deploy replaces a running Traefik
# when the version it asks for differs. Both tags are removed from the engine
# once pushed, so a deploy of either pulls it.
#
# The copy also logs at DEBUG, so that the ACME directory it contacts is in its
# log and `expect_log_lacks_host` has something to read: at the default level,
# error, a Traefik that ordered without error logs nothing, and the assertion
# could not fail. It turns off Traefik's version check and usage report, by name,
# as the gate's own Traefik does. A deploy runs Traefik with the server's command,
# which sets neither, and the version check is on by default, so a Traefik a
# deploy created from the unmodified image would ask a third party's host on
# every run. The copy's entrypoint carries these flags ahead of the command a
# deploy gives it, because the image's entrypoint script runs Traefik with
# whatever arguments follow when the first one is a flag [observed --
# 2026-11-20, Docker Engine 29.10.0: a container from such a copy, given the
# command's first flags, ran `traefik` with the flags ahead of them].
traefik_copy_repo="localhost:$registry_port/bondi-check-traefik"
traefik_copy_tags=(v1 v2)
pebble_ca=/test/certs/pebble.minica.pem
build_traefik_copy() {
    local dockerfile context tag references tag_arguments reference
    dockerfile="$work/traefik-copy.Dockerfile"
    context="$work/traefik-copy-context"
    {
        printf 'FROM %s AS pebble\n' "$pebble_image"
        printf 'FROM %s\n' "$traefik_image"
        printf 'COPY --from=pebble %s /usr/local/share/ca-certificates/pebble-minica.crt\n' "$pebble_ca"
        printf 'RUN cat /usr/local/share/ca-certificates/pebble-minica.crt >> /etc/ssl/certs/ca-certificates.crt\n'
        printf 'ENTRYPOINT ["/entrypoint.sh", "--global.checknewversion=false", "--global.sendanonymoususage=false", "--log.level=DEBUG"]\n'
        printf 'LABEL %s\n' "$fixture_label"
    } > "$dockerfile"
    mkdir -p "$context"
    references=()
    tag_arguments=()
    for tag in "${traefik_copy_tags[@]}"; do
        references+=("$traefik_copy_repo:$tag")
        tag_arguments+=(--tag "$traefik_copy_repo:$tag")
        # Recorded before it exists, so a build that fails half way is still removed.
        fixture_images+=("$traefik_copy_repo:$tag")
    done
    docker build --quiet "${tag_arguments[@]}" --file "$dockerfile" "$context" > /dev/null
    for reference in "${references[@]}"; do
        docker push --quiet "$reference" > /dev/null
    done
    docker image rm "${references[@]}" > /dev/null
    echo "ok: pushed ${references[*]}, a copy of $traefik_image that trusts Pebble's CA, and removed them from the engine"
}

# The registry serves TLS under a certificate made for this run. The engine
# accepts this certificate because `localhost` is in its insecure range, which
# skips verification [observed -- 2026-11-16, Docker Engine 29.9.3, on port 443;
# and 2026-11-19 on port 5443]. The certificate goes in with `docker cp` rather
# than a bind mount, so nothing depends on how the host labels its temporary
# directory. The registry is published on loopback only: it is reached as
# `localhost`, and a registry on every interface of a developer's box would be one
# anybody on the network could push to while this runs.
start_registry() {
    local certs
    certs="$work/registry-certs"
    registry_certs="$certs"
    mkdir "$certs"
    if ! openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=localhost \
        -addext subjectAltName=DNS:localhost,IP:127.0.0.1 \
        -keyout "$certs/key.pem" -out "$certs/cert.pem" 2> "$work/openssl-stderr"; then
        echo "error: openssl could not make the registry's certificate:" >&2
        cat "$work/openssl-stderr" >&2
        return 1
    fi
    create_registry "$fixture_registry" "$registry_port" ""
}

# The second registry, with the same certificate and a password file of one user.
# It answers 401 to anything without that user's credentials, which is asserted
# before any arm relies on it: an arm that deploys with credentials proves
# nothing against a registry that would have served it without.
fixture_auth_registry="bondi-check-auth-registry-$$"
start_auth_registry() {
    local auth_dir status
    auth_dir="$work/auth-registry"
    mkdir "$auth_dir"
    printf '%s\n' "$auth_registry_htpasswd" > "$auth_dir/htpasswd"
    create_registry "$fixture_auth_registry" "$auth_registry_port" "$auth_dir"
    status="$(curl --silent --cacert "$registry_certs/cert.pem" --output /dev/null \
        --write-out '%{http_code}' "https://localhost:$auth_registry_port/v2/")"
    if [ "$status" != 401 ]; then
        echo "error: expected $fixture_auth_registry to refuse a request with no credentials with HTTP 401, and it answered $status" >&2
        return 1
    fi
    status="$(curl --silent --cacert "$registry_certs/cert.pem" --output /dev/null \
        --user "$auth_registry_user:$auth_registry_pass" \
        --write-out '%{http_code}' "https://localhost:$auth_registry_port/v2/")"
    if [ "$status" != 200 ]; then
        echo "error: expected $fixture_auth_registry to accept $auth_registry_user's credentials with HTTP 200, and it answered $status" >&2
        return 1
    fi
    echo "ok: $fixture_auth_registry answers 401 with no credentials and 200 with $auth_registry_user's"
}

# A registry container from the pinned image, published on loopback at the port
# given and serving the run's certificate. A third argument names a directory
# holding an `htpasswd` file, which puts the registry behind it.
create_registry() {
    local name port auth_dir registry_id auth_arguments
    name="$1"
    port="$2"
    auth_dir="$3"
    auth_arguments=()
    if [ -n "$auth_dir" ]; then
        auth_arguments=(--env REGISTRY_AUTH=htpasswd --env REGISTRY_AUTH_HTPASSWD_REALM=bondi-check
            --env REGISTRY_AUTH_HTPASSWD_PATH=/auth/htpasswd)
    fi
    registry_id="$(docker create --name "$name" --label "$fixture_label" \
        --publish "127.0.0.1:$port:5000" \
        --env REGISTRY_HTTP_TLS_CERTIFICATE=/certs/cert.pem \
        --env REGISTRY_HTTP_TLS_KEY=/certs/key.pem \
        ${auth_arguments[@]+"${auth_arguments[@]}"} \
        "$registry_image")"
    docker cp "$registry_certs" "$registry_id:/certs"
    if [ -n "$auth_dir" ]; then
        docker cp "$auth_dir" "$registry_id:/auth"
    fi
    docker start "$registry_id" > /dev/null
    await_registry "$name" "$port" "$auth_dir"
}

# Asked from the host's network namespace, which is the one the engine pulls
# from, rather than inferred from the container being up. A registry behind
# htpasswd is asked with its credentials, so that up also means it accepts them.
await_registry() {
    local name port auth_dir attempt header
    name="$1"
    port="$2"
    auth_dir="$3"
    header="X-Check: none"
    if [ -n "$auth_dir" ]; then
        header="Authorization: Basic $(printf '%s:%s' "$auth_registry_user" "$auth_registry_pass" | base64)"
    fi
    attempt=0
    while [ "$attempt" -lt "$attempts" ]; do
        if docker run --rm --label "$fixture_label" --network host "$busybox_image" \
            wget -q -T 2 --no-check-certificate --header "$header" -O /dev/null "https://127.0.0.1:$port/v2/" \
            > /dev/null 2>&1; then
            echo "ok: the registry $name answers on https://localhost:$port"
            return 0
        fi
        attempt=$((attempt + 1))
        sleep 1
    done
    echo "error: the registry $name did not answer on https://localhost:$port after ${attempts}s" >&2
    docker logs "$name" >&2 2>&1 || true
    return 1
}

# One workload image. At start it writes its own hostname as the page busybox
# `httpd` serves. The engine sets a container's hostname to its short id when the
# create body names none, and a deploy's names none, so a request through Traefik
# names the container that answered it [observed -- 2026-11-16, Docker Engine
# 29.9.3, a container run from this image by hand].
push_workload() {
    local repository tag healthcheck docker_config reference dockerfile push_command
    local first_line
    repository="$1"
    tag="$2"
    healthcheck="$3"
    docker_config="${4:-}"
    first_line=""
    push_command=(docker)
    if [ -n "$docker_config" ]; then
        push_command+=(--config "$docker_config")
    fi
    reference="$repository:$tag"
    dockerfile="$work/workload.Dockerfile"
    {
        printf 'FROM %s\n' "$busybox_image"
        printf 'LABEL %s check-server-image.workload-tag=%s\n' "$fixture_label" "$tag"
        case "$healthcheck" in
            healthcheck)
                printf 'HEALTHCHECK --interval=1s --timeout=2s --retries=3 CMD wget -q -O /dev/null http://127.0.0.1:%s/ || exit 1\n' "$workload_port"
                ;;
            unhealthy)
                # Failures in the start period do not count, so the server
                # reads it unhealthy about 18 s after it starts, inside the 30 s
                # the failed arms wait. That keeps it running long enough for
                # Alloy to tail it: see `arm_blue_green_new_fails_logs`.
                # The cost is that every arm deploying this workload waits the
                # start period out: arm_blue_green_first_fails,
                # arm_blue_green_new_fails and the logs arm each take roughly
                # 15 s longer. That leaves about 12 s of the 30 s
                # health_timeout as margin.
                printf 'HEALTHCHECK --interval=1s --timeout=2s --retries=3 --start-period=15s CMD false\n'
                first_line="echo $unhealthy_marker && "
                ;;
            no-healthcheck) : ;;
            *)
                echo "error: push_workload: expected healthcheck, unhealthy or no-healthcheck, got '$healthcheck'" >&2
                return 1
                ;;
        esac
        printf 'CMD ["sh", "-c", "%smkdir -p /www && hostname > /www/index.html && exec httpd -f -p %s -h /www"]\n' "$first_line" "$workload_port"
    } > "$dockerfile"
    mkdir -p "$work/workload-context"
    # Recorded before it exists, so a build that fails half way is still removed.
    fixture_images+=("$reference")
    docker build --quiet --tag "$reference" --file "$dockerfile" "$work/workload-context" > /dev/null
    "${push_command[@]}" push --quiet "$reference" > /dev/null
    docker image rm "$reference" > /dev/null
    echo "ok: pushed $reference to the registry, and removed it from the engine"
}

# One tag of the drain workload, built from `drain/app.py` and pushed as
# `push_workload` pushes the others. The port it listens on and the one its
# health check asks are both `workload_port`, the port every deploy names.
push_drain_workload() {
    local tag reference dockerfile
    tag="$1"
    reference="$drain_repo:$tag"
    dockerfile="$work/drain-workload.Dockerfile"
    {
        printf 'FROM %s\n' "$python_image"
        printf 'LABEL %s check-server-image.workload-tag=%s\n' "$fixture_label" "$tag"
        printf 'ENV PORT=%s\n' "$workload_port"
        printf 'COPY app.py /app.py\n'
        printf 'HEALTHCHECK --interval=10s --timeout=3s --retries=3 --start-period=30s --start-interval=1s CMD wget -q -O /dev/null http://127.0.0.1:%s/health || exit 1\n' "$workload_port"
        printf 'CMD ["python", "-u", "/app.py"]\n'
    } > "$dockerfile"
    fixture_images+=("$reference")
    docker build --quiet --tag "$reference" --file "$dockerfile" "$drain_source" > /dev/null
    docker push --quiet "$reference" > /dev/null
    docker image rm "$reference" > /dev/null
    echo "ok: pushed $reference to the registry, and removed it from the engine"
}

# The clients' image, left on the engine for the arms to run and removed at
# teardown. It carries the fixture's label, so every container run from it does.
build_drain_client() {
    local dockerfile
    dockerfile="$work/drain-client.Dockerfile"
    {
        printf 'FROM %s\n' "$python_image"
        printf 'LABEL %s\n' "$fixture_label"
        printf 'COPY echo.py stream.py upload.py /\n'
    } > "$dockerfile"
    fixture_images+=("$drain_client_image")
    docker build --quiet --tag "$drain_client_image" --file "$dockerfile" "$drain_source" > /dev/null
    echo "ok: built $drain_client_image"
}

# A request to the registry's HTTP API from this shell, trusting only the
# certificate made for it, and failing on any status of 400 or above.
registry_api="https://localhost:$registry_port/v2"
registry_request() {
    curl --silent --show-error --fail --cacert "$registry_certs/cert.pem" "$@"
}

# One blob into a repository, by the registry API's two-step upload: a POST that
# opens the upload and answers its location, then a PUT of the whole blob to that
# location under its digest.
upload_blob() {
    local repository file digest location separator
    repository="$1"
    file="$2"
    digest="$3"
    registry_request --request POST --output /dev/null --dump-header "$work/upload-headers" \
        "$registry_api/$repository/blobs/uploads/"
    location="$(sed -n 's/^[Ll]ocation: *//p' "$work/upload-headers" | tr -d '\r')"
    case "$location" in
        "")
            echo "error: the registry opened an upload to $repository and named no location for it" >&2
            return 1
            ;;
        /*) location="https://localhost:$registry_port$location" ;;
    esac
    case "$location" in
        *\?*) separator='&' ;;
        *) separator='?' ;;
    esac
    registry_request --request PUT --output /dev/null \
        --header 'Content-Type: application/octet-stream' \
        --data-binary "@$file" "$location${separator}digest=$digest"
}

# The image the failed-pull arm deploys: a tag of the workload's repository whose
# manifest and config the registry serves and whose one layer it does not. It is
# pushed blob by blob over the registry's API rather than built and pushed with
# docker, because the engine keeps a layer it built after the image is removed,
# and a pull then reports that layer `Already exists` and succeeds without
# fetching it [observed -- 2026-11-19, Docker Engine 29.10.0]. The layer is
# random bytes, so no other image shares its digest and deleting its blob breaks
# this image alone; the engine fails the pull at fetching it, before it would
# unpack it, so the bytes need not be a tar and the config's diff id is never
# checked against them [observed -- 2026-11-20, Docker Engine 29.10.0: this
# function's image, deployed by the arm, failed at its pull]. The config names the
# engine's own platform, so a refusal for the platform cannot stand in for the
# missing layer.
#
# The registry answered 200 for a deleted blob from its cache until it was
# restarted [observed -- 2026-11-19], so it is restarted. It is then asked that
# the manifest is still there and the layer is not: a failed deploy of a tag with
# no manifest is the HTTP refusal the `simple` arm's missing tag covers, not a
# pull that fails inside the stream an engine answers 200 for.
missing_layer_reference="$workload_repo:missing-layer"
push_missing_layer() {
    local repository tag dir platform os architecture layer_digest layer_hex layer_size
    local config_digest config_size manifest_status blob_status
    repository="${missing_layer_reference#*/}"
    repository="${repository%:*}"
    tag="${missing_layer_reference##*:}"
    dir="$work/missing-layer"
    mkdir "$dir"
    platform="$(docker version --format '{{.Server.Os}} {{.Server.Arch}}')"
    read -r os architecture <<< "$platform"

    head -c 4096 /dev/urandom > "$dir/layer"
    layer_digest="sha256:$(sha256sum "$dir/layer" | cut -d ' ' -f 1)"
    layer_hex="${layer_digest#sha256:}"
    layer_size="$(wc -c < "$dir/layer")"
    printf '{"architecture":"%s","os":"%s","config":{},"rootfs":{"type":"layers","diff_ids":["%s"]}}' \
        "$architecture" "$os" "$layer_digest" > "$dir/config"
    config_digest="sha256:$(sha256sum "$dir/config" | cut -d ' ' -f 1)"
    config_size="$(wc -c < "$dir/config")"
    printf '{"schemaVersion":2,"mediaType":"application/vnd.oci.image.manifest.v1+json","config":{"mediaType":"application/vnd.oci.image.config.v1+json","digest":"%s","size":%d},"layers":[{"mediaType":"application/vnd.oci.image.layer.v1.tar+gzip","digest":"%s","size":%d}]}' \
        "$config_digest" "$config_size" "$layer_digest" "$layer_size" > "$dir/manifest"

    upload_blob "$repository" "$dir/layer" "$layer_digest"
    upload_blob "$repository" "$dir/config" "$config_digest"
    registry_request --request PUT --output /dev/null \
        --header 'Content-Type: application/vnd.oci.image.manifest.v1+json' \
        --data-binary "@$dir/manifest" "$registry_api/$repository/manifests/$tag"
    echo "ok: pushed $missing_layer_reference to the registry over its API, layer $layer_digest"

    docker exec "$fixture_registry" \
        rm "/var/lib/registry/docker/registry/v2/blobs/sha256/${layer_hex:0:2}/$layer_hex/data"
    docker restart "$fixture_registry" > /dev/null
    await_registry "$fixture_registry" "$registry_port" ""

    manifest_status="$(curl --silent --cacert "$registry_certs/cert.pem" --head --output /dev/null \
        --write-out '%{http_code}' \
        --header 'Accept: application/vnd.oci.image.manifest.v1+json' \
        "$registry_api/$repository/manifests/$tag")"
    blob_status="$(curl --silent --cacert "$registry_certs/cert.pem" --head --output /dev/null \
        --write-out '%{http_code}' "$registry_api/$repository/blobs/$layer_digest")"
    if [ "$manifest_status" != 200 ] || [ "$blob_status" != 404 ]; then
        {
            echo "error: expected the registry to serve $missing_layer_reference's manifest and not its layer"
            echo "  manifest: HTTP $manifest_status (expected 200), layer $layer_digest: HTTP $blob_status (expected 404)"
        } >&2
        return 1
    fi
    echo "ok: the registry serves $missing_layer_reference's manifest (HTTP 200) and not its layer (HTTP 404)"
}

# The credentialed workload. The CLI's credentials are kept in a directory of this
# run's, not the operator's `~/.docker`, which a push here must not write to.
auth_repo="localhost:$auth_registry_port/bondi-check-workload-credentials"
auth_docker_config=""
login_auth_registry() {
    auth_docker_config="$work/docker-config"
    mkdir -p "$auth_docker_config"
    printf '%s' "$auth_registry_pass" | docker --config "$auth_docker_config" login \
        --username "$auth_registry_user" --password-stdin "localhost:$auth_registry_port" > /dev/null
    echo "ok: logged in to localhost:$auth_registry_port as $auth_registry_user, in a configuration of this run's"
}

deploy_fixture_up() {
    local tag
    pull_pinned "$registry_image"
    pull_pinned "$traefik_image"
    pull_pinned "$busybox_image"
    pull_pinned "$pebble_image"
    pull_pinned "$python_image"
    pull_pinned "$loki_image"
    pull_pinned "$alloy_image"
    create_acme_json
    start_registry
    start_auth_registry
    login_auth_registry
    push_workload "$auth_repo" v1 no-healthcheck "$auth_docker_config"
    for tag in "${workload_tags[@]}"; do
        push_workload "$workload_repo" "$tag" no-healthcheck
        push_workload "$healthcheck_repo" "$tag" healthcheck
        push_drain_workload "$tag"
    done
    build_drain_client
    push_workload "$unhealthy_repo" v1 unhealthy
    push_missing_layer
    build_traefik_copy
    start_pebble
}

# The rest of the fixture, once the fresh-box arms have run and torn down what
# their deploys created: the network, the gate's Traefik, and Pebble on that
# network.
deploy_fixture_proxy_up() {
    fixture_network_id="$(docker network create --label "$fixture_label" "$fixture_network")"
    echo "ok: created the network $fixture_network ($fixture_network_id)"
    require_network_on_its_bridge "$fixture_network_id" || return 1
    start_traefik
    join_pebble
}

# The network's subnet has to be routed to the network's own bridge. A host VPN
# client that claims the subnet (GlobalProtect's gpd0 took 172.19.0.0/16 here
# [observed -- 2026-11-23]) sends the gate's traffic into the VPN: dials to a
# container on the network then fail or stall for reasons that have nothing to do
# with the code under check, and the swap arm's request counts are meaningless.
# One address of the subnet that no container holds (the gateway's next one) is
# asked of the host's routing table, and the interface it names must be the
# bridge. Refused before the gate's Traefik starts, naming the subnet and the
# interface. The fresh-box arms before it create their own network by a deploy,
# and their requests come from the host's namespace only to the published ports.
require_network_on_its_bridge() {
    local id inspected subnet gateway bridge probe route via
    id="$1"
    if ! inspected="$(docker network inspect --format '{{(index .IPAM.Config 0).Subnet}} {{(index .IPAM.Config 0).Gateway}} {{index .Options "com.docker.network.bridge.name"}}' "$id")"; then
        echo "error: the engine did not describe the network $fixture_network ($id)" >&2
        return 1
    fi
    read -r subnet gateway bridge <<< "$inspected"
    bridge="${bridge:-br-${id:0:12}}"
    probe="${gateway%.*}.$((${gateway##*.} + 1))"
    if ! command -v ip > /dev/null; then
        echo "error: the deploy arms check the route to $subnet with ip, which is not on PATH (install iproute2)" >&2
        return 1
    fi
    if ! route="$(ip route get "$probe")"; then
        echo "error: ip route get $probe failed, so the route to $fixture_network's subnet $subnet is unknown" >&2
        return 1
    fi
    via="$(sed -n 's/.* dev \([^ ]*\).*/\1/p' <<< "$route" | head -n 1)"
    if [ "$via" != "$bridge" ]; then
        {
            echo "error: the subnet $subnet of $fixture_network is routed through ${via:-no interface}, not through its own bridge $bridge."
            echo "A VPN or another network owns that range on this host, so a request to a container on it would not reach it."
            echo "ip route get $probe: $route"
            echo "Nothing was deployed. Disconnect the VPN, or run on a host where $subnet is free."
        } >&2
        return 1
    fi
    echo "ok: $subnet is routed through $bridge"
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
# A payload that names a `traefik_image` and a `traefik_acme_email` has the server
# replace this Traefik with one that orders certificates. Only the two Traefik
# arms send them, and they name Pebble as the certificate server too, so the
# Traefik a deploy creates orders from Pebble and never from Let's Encrypt.
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
        --entrypoints.websecure.address=:443 \
        "$dial_timeout_flag")"
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
    if grep -qxF -- "$id" <<< "$containers"; then
        echo "error: expected $id gone, and it is still on the engine" >&2
        docker ps --all --no-trunc --filter "id=$id" >&2 || true
        return 1
    fi
    echo "ok: $id is gone"
}

# No container on the engine has any of the names given, asked of a listing that
# succeeds on a healthy engine, for the reason `expect_gone` asks one. Names are
# matched exactly, so a container whose name merely contains one is not taken
# for it. The affirmative half is the caller's: a witness that the same deploy
# did, or could, put a container under the name.
expect_no_container_named() {
    local containers name holder
    containers="$(docker ps --all --no-trunc --format '{{.ID}}\t{{.Names}}')"
    for name in "$@"; do
        holder="$(printf '%s\n' "$containers" | awk -F '\t' -v name="$name" '$2 == name { print $1 }')"
        if [ -n "$holder" ]; then
            echo "error: expected no container named $name, and $holder is" >&2
            return 1
        fi
        echo "ok: no container is named $name"
    done
}

# No network of that name is on the engine. Its affirmative half is the caller's,
# as `expect_no_container_named`'s is.
expect_no_network() {
    local network_id
    network_id="$(network_id_of "$1")"
    if [ -n "$network_id" ]; then
        echo "error: expected no network named $1, and $network_id is" >&2
        return 1
    fi
    echo "ok: no network is named $1"
}

# What the engine holds under a reference, asked of the listing the way cleanup's
# own filter reads it: `docker image ls` names each tag as repository and tag,
# registry port included. `expect_image_listed` is the affirmative half of
# `expect_image_absent`, so a listing that came back empty, or in another shape,
# cannot read as an absence.
expect_image_listed() {
    local reference listing
    reference="$1"
    listing="$(docker image ls --format '{{.Repository}}:{{.Tag}}')"
    if ! grep -qxF -- "$reference" <<< "$listing"; then
        echo "error: expected the engine to hold $reference, and its listing does not name it" >&2
        return 1
    fi
    echo "ok: the engine holds $reference"
}

expect_image_absent() {
    local reference listing
    reference="$1"
    listing="$(docker image ls --format '{{.Repository}}:{{.Tag}}')"
    if grep -qxF -- "$reference" <<< "$listing"; then
        echo "error: expected the engine not to hold $reference, and it does" >&2
        return 1
    fi
    echo "ok: the engine holds no $reference"
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
# leaving the server to choose one from whether the image has a health check,
# except for a strategy of `auto`, which names none, as a manifest that sets no
# `deployment_strategy` sends none.
# Of itself it names no `traefik_image` and no `traefik_acme_email`, so the
# server adopts the gate's Traefik rather than replacing it, and no registry
# credential, which only `arm_registry_credentials` sends. Any arguments after the
# strategy are further payload members, each a JSON `"key": value` written as
# given, for the settings only one strategy reads and for the Traefik settings
# only the Traefik arms send.
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
        printf '{"service_name": "%s", "image": "%s", "port": %s, "traefik_domain_name": "%s"' \
            "$service" "$reference" "$workload_port" "$host"
        case "$strategy" in
            auto) ;;
            *) printf ', "deployment_strategy": "%s"' "$strategy" ;;
        esac
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
    # The retention policy: the image a deploy replaced goes once no container uses
    # it, and the one the deploy declares stays. Asked of an image under a
    # `localhost:<port>/` repository, so that cleanup's `reference=` filter is seen
    # to match a name with a registry port.
    expect_image_listed "$v2"
    expect_image_absent "$v1"
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

# The settings the blue-green wait reads, stated rather than left to the server:
# a health check that never passes fails here in half a minute, not in the
# server's two.
blue_green_settings=('"health_timeout": 30.0' '"poll_interval": 1.0')

# The `blue-green` strategy starts the next tag beside the running container, waits
# for its health check, moves traffic to it and only then removes the old one, so
# its image is the repository that declares a `HEALTHCHECK`.
#
# The new container is started under a temporary name and renamed once the old one
# is gone, so the v2 id is read under the service's own name, after the deploy: an
# id that only the temporary name held would mean the switch never finished.
arm_blue_green() {
    local v1 v2 v1_id v2_id
    v1="$healthcheck_repo:v1"
    v2="$healthcheck_repo:v2"

    echo "==> $image: a blue-green deploy of $v1, then of $v2"
    deploy_service "$blue_green_service" "$v1" "$blue_green_host" blue-green "${blue_green_settings[@]}"
    expect_code "deploy $v1" 0
    v1_id="$(container_id_of "$blue_green_service")"
    expect_running_at "$v1_id" "$v1"
    deploy_service "$blue_green_service" "$v2" "$blue_green_host" blue-green "${blue_green_settings[@]}"
    expect_code "deploy $v2" 0
    v2_id="$(container_id_of "$blue_green_service")"
    expect_running_at "$v2_id" "$v2"
    expect_gone "$v1_id"
    expect_served_by "$blue_green_host" "$v2_id"
}

# The service the failed first deploy arm deploys, named and hosted apart from
# the other arms' for the reasons the `simple` arm's are.
first_fails_service="bondi-check-first-fails-$$"
first_fails_host="first-fails.check-server-image.invalid"

# A first blue-green deploy whose container never passes its health check exits
# 1 and leaves no container of the service behind, under its own name or the
# temporary one. With nothing serving, the deploy starts the container under the
# service's own name, so that is the one its rollback has to remove. The stream
# naming that container unhealthy is the affirmative half of the absence: the
# deploy did start it, and the server read its health, so its absence afterwards
# is a removal and not a container that never was. Exactly exit 1, for the
# reason the `simple` arm's missing tag is.
arm_blue_green_first_fails() {
    local reference
    reference="$unhealthy_repo:v1"

    echo "==> $image: a first blue-green deploy of $reference, whose health check never passes"
    expect_no_container_named "$first_fails_service" "$first_fails_service-new"
    deploy_service "$first_fails_service" "$reference" "$first_fails_host" blue-green "${blue_green_settings[@]}"
    expect_code "deploy $reference" 1
    expect_stream_contains "deploy $reference" stderr "container $first_fails_service is unhealthy"
    expect_no_container_named "$first_fails_service" "$first_fails_service-new"
}

# The service the failed replacement arm deploys, named and hosted apart from the
# other arms' for the reasons the `simple` arm's are.
new_fails_service="bondi-check-new-fails-$$"
new_fails_host="new-fails.check-server-image.invalid"

# With v1 serving, a blue-green deploy of an image whose health check never
# passes exits 1 and leaves v1 serving, by the same container id, and the
# container it started beside v1, under the temporary name, gone. The stream
# naming that container unhealthy is the affirmative half of its absence.
arm_blue_green_new_fails() {
    local v1 failing v1_id
    v1="$healthcheck_repo:v1"
    failing="$unhealthy_repo:v1"

    echo "==> $image: a blue-green deploy of $v1, then of $failing, whose health check never passes"
    deploy_service "$new_fails_service" "$v1" "$new_fails_host" blue-green "${blue_green_settings[@]}"
    expect_code "deploy $v1" 0
    v1_id="$(container_id_of "$new_fails_service")"
    expect_running_at "$v1_id" "$v1"
    expect_served_by "$new_fails_host" "$v1_id"
    deploy_service "$new_fails_service" "$failing" "$new_fails_host" blue-green "${blue_green_settings[@]}"
    expect_code "deploy $failing" 1
    expect_stream_contains "deploy $failing" stderr "container $new_fails_service-new is unhealthy"
    expect_running_at "$v1_id" "$v1"
    expect_served_by "$new_fails_host" "$v1_id"
    expect_no_container_named "$new_fails_service-new"
}

# The Loki and the Alloy the failed-candidate logs arm starts. Their names carry
# this run's pid, as the registry's does, and every port they publish is one the
# engine picks on loopback, so neither can be taken by anything already on the
# engine and the preconditions have nothing to refuse for them. Both carry the
# fixture's label, so teardown removes them with the rest.
log_sink_loki="bondi-check-loki-$$"
log_sink_alloy="bondi-check-alloy-$$"
# Loki's published address, and the value of `SECONDS` just before Alloy was
# started, both set by `start_log_sink`.
loki_address=""
alloy_started_at=""
# How long Loki, then Alloy, is given to answer ready, and the marker to arrive:
# the bound the real-Alloy suite gives its Loki, which is room for a loaded
# engine.
log_sink_bound=120
# Alloy first lists containers no earlier than `alloy_started_at`, so a refresh
# of Alloy's one-minute default lists them next no earlier than a minute after
# it. A candidate removed within this many seconds of the start is one that
# default never lists, and the arm tells the two apart. The bound is under a
# minute by the margin of whole-second clocks, as the suite's is.
log_sink_window=55

# A Loki on loopback, then an Alloy in its network namespace over the committed
# config, which pushes to that Loki at 127.0.0.1:3100. Alloy's HTTP port is
# published by the Loki, since a container in another's namespace publishes
# nothing. The config goes in with `docker cp`, as the registry's certificate
# does, so nothing depends on the engine sharing this shell's filesystem. The
# config reads the journal at /var/log/journal, and Alloy refuses to load it
# where that path is missing, so an empty tmpfs is mounted there: it gives the
# journal source nothing to read, and the arm needs nothing from the host.
start_log_sink() {
    local deadline alloy_id alloy_address
    docker run --detach --name "$log_sink_loki" --label "$fixture_label" \
        --publish 127.0.0.1::3100 --publish 127.0.0.1::12345 \
        "$loki_image" -config.file=/etc/loki/local-config.yaml -auth.enabled=false > /dev/null
    loki_address="$(docker port "$log_sink_loki" 3100/tcp | head -n 1)"
    alloy_address="$(docker port "$log_sink_loki" 12345/tcp | head -n 1)"
    if [ -z "$loki_address" ] || [ -z "$alloy_address" ]; then
        echo "error: $log_sink_loki published no address for Loki or for Alloy" >&2
        return 1
    fi
    # Alloy backs off between refused pushes, so it is started only once Loki
    # answers, and a slow Loki cannot read as a line that was not delivered.
    deadline=$((SECONDS + log_sink_bound))
    until curl --silent --fail --max-time 5 --output /dev/null "http://$loki_address/ready"; do
        if [ "$SECONDS" -ge "$deadline" ]; then
            echo "error: $log_sink_loki did not answer ready on $loki_address within ${log_sink_bound}s" >&2
            docker logs "$log_sink_loki" 2>&1 | tail -n 40 >&2 || true
            return 1
        fi
        sleep 1
    done
    echo "ok: $log_sink_loki answers ready on $loki_address"

    alloy_id="$(docker create --name "$log_sink_alloy" --label "$fixture_label" \
        --network "container:$log_sink_loki" \
        --volume /var/run/docker.sock:/var/run/docker.sock:ro \
        --tmpfs /var/log/journal \
        "$alloy_image" run --server.http.listen-addr=0.0.0.0:12345 /etc/alloy/config.alloy)"
    docker cp "$alloy_config" "$alloy_id:/etc/alloy/config.alloy" > /dev/null
    alloy_started_at=$SECONDS
    docker start "$alloy_id" > /dev/null
    deadline=$((SECONDS + log_sink_bound))
    until curl --silent --fail --max-time 5 --output /dev/null "http://$alloy_address/-/ready"; do
        if [ "$SECONDS" -ge "$deadline" ]; then
            echo "error: $log_sink_alloy did not answer ready on $alloy_address within ${log_sink_bound}s" >&2
            docker logs "$alloy_id" 2>&1 | tail -n 40 >&2 || true
            return 1
        fi
        sleep 1
    done
    echo "ok: $log_sink_alloy ($alloy_image) answers ready on $alloy_address, over $alloy_config"
}

# A line holding the marker is in Loki under the stream whose `container` label
# is the one given. The label is in the selector, so a line that arrived under
# any other `container`, the candidate's temporary name included, is not an
# answer. Asked again until the bound, because the line reaches Loki on Alloy's
# schedule, and each request is capped so one that hangs cannot hold the poll
# past it.
expect_logged_under() {
    local container_label marker deadline answer
    container_label="$1"
    marker="$2"
    deadline=$((SECONDS + log_sink_bound))
    answer=""
    while [ "$SECONDS" -lt "$deadline" ]; do
        if answer="$(curl --silent --fail --max-time 5 --get "http://$loki_address/loki/api/v1/query_range" \
            --data-urlencode "query={container=\"$container_label\"} |= \"$marker\"" \
            --data-urlencode limit=10)" && grep -qF -- "$marker" <<< "$answer"; then
            echo "ok: Loki holds '$marker' under container=$container_label"
            return 0
        fi
        sleep 2
    done
    {
        echo "error: expected Loki to hold '$marker' under container=$container_label within ${log_sink_bound}s"
        echo "  last answer: ${answer:-none}"
        echo "--- alloy logs ---"
        docker logs "$log_sink_alloy" 2>&1 | tail -n 40 || true
    } >&2
    return 1
}

# The service the failed-candidate logs arm deploys, named and hosted apart from
# the other arms' for the reasons the `simple` arm's are.
new_fails_logs_service="bondi-check-new-fails-logs-$$"
new_fails_logs_host="new-fails-logs.check-server-image.invalid"

# A blue-green candidate that fails its health check beside a serving container
# has its lines delivered, under the service's name. The candidate runs under the
# temporary name, so its `container` label is the service's only if the config
# reads `bondi.name`. It is alive for its health wait, about 18 s [assumed: the
# 15 s start period and three one-second failures, not timed], then for the
# 10 s the server's stop waits, since busybox `httpd` as PID 1 does not answer
# SIGTERM [observed -- 2026-11-24, Docker Engine 29.10.0: a stop of this image's
# command took 10 s]. Under a 5 s refresh the Docker source began tailing a new
# container 11 to 15 s after it started, and never tailed one removed after 10 s
# [observed in the real-Alloy suite -- 2026-11-24, Alloy v1.8.0], so the
# candidate's 28 s or so leave room past that.
#
# Loki and Alloy start here rather than with the fixture, so the arm knows when
# Alloy first listed containers. The candidate is gone well inside a minute of
# that, which is what lets the arm tell a 5 s refresh from Alloy's one-minute
# default: under the default, nothing lists the candidate, and its marker never
# arrives. A run slow enough that the candidate outlived the window could have
# been listed either way, so it fails rather than passes.
arm_blue_green_new_fails_logs() {
    local v1 failing v1_id elapsed
    v1="$healthcheck_repo:v1"
    failing="$unhealthy_repo:v1"

    echo "==> $image: a blue-green deploy of $v1, then of $failing, whose health check never passes"
    deploy_service "$new_fails_logs_service" "$v1" "$new_fails_logs_host" blue-green "${blue_green_settings[@]}"
    expect_code "deploy $v1" 0
    v1_id="$(container_id_of "$new_fails_logs_service")"
    expect_running_at "$v1_id" "$v1"
    # Started only now, so the window measures the candidate's lifetime and not
    # v1's whole deploy.
    echo "==> $image: a Loki and an Alloy over the generated config, for a failed candidate's logs"
    start_log_sink
    deploy_service "$new_fails_logs_service" "$failing" "$new_fails_logs_host" blue-green "${blue_green_settings[@]}"
    expect_code "deploy $failing" 1
    expect_stream_contains "deploy $failing" stderr "container $new_fails_logs_service-new is unhealthy"
    expect_no_container_named "$new_fails_logs_service-new"
    elapsed=$((SECONDS - alloy_started_at))
    if [ "$elapsed" -gt "$log_sink_window" ]; then
        {
            echo "error: the failed candidate was removed ${elapsed}s after Alloy started, past the ${log_sink_window}s"
            echo "inside which a one-minute refresh could not have listed it. Its marker would arrive"
            echo "whichever refresh the config carries, so this run cannot tell them apart."
        } >&2
        return 1
    fi
    echo "ok: the failed candidate was removed ${elapsed}s after Alloy started"
    expect_logged_under "$new_fails_logs_service" "$unhealthy_marker"
    # Not left running until teardown; teardown by label still covers an abort.
    docker rm -f "$log_sink_alloy" "$log_sink_loki" >/dev/null
}

# The two services the side-by-side arm deploys, named and hosted apart from each
# other and from the other arms' for the reasons the `simple` arm's are.
first_service="bondi-check-first-$$"
first_host="first.check-server-image.invalid"
second_service="bondi-check-second-$$"
second_host="second.check-server-image.invalid"

# Two services deployed side by side on one Traefik are each served by their own
# container. Both run the same image, so what tells them apart is only the router
# each deploy labels its container with: a router or load-balancer service that two
# services shared would send both hosts to one container, or to neither. The first
# is asked again once the second is up, because the second's labels are what would
# take its host away.
arm_two_services() {
    local reference first_id second_id
    reference="$workload_repo:v1"

    echo "==> $image: simple deploys of $first_service and $second_service, side by side"
    deploy_service "$first_service" "$reference" "$first_host" simple
    expect_code "deploy $first_service" 0
    first_id="$(container_id_of "$first_service")"
    expect_running_at "$first_id" "$reference"
    expect_served_by "$first_host" "$first_id"
    deploy_service "$second_service" "$reference" "$second_host" simple
    expect_code "deploy $second_service" 0
    second_id="$(container_id_of "$second_service")"
    expect_running_at "$second_id" "$reference"
    expect_running_at "$first_id" "$reference"
    expect_served_by "$second_host" "$second_id"
    expect_served_by "$first_host" "$first_id"
}

# The service the failed-pull arm deploys, named and hosted apart from the other
# arms' for the reasons the `simple` arm's are.
pull_fails_service="bondi-check-pull-fails-$$"
pull_fails_host="pull-fails.check-server-image.invalid"

# A pull that fails inside the stream the engine answers 200 for leaves the
# running container serving. The engine reports a layer the registry cannot serve
# only in the body of the pull, so a server that judged the pull by its status
# would stop the v1 container and then fail to start one from an image it never
# got. The v1 container is seen running and answering before the deploy, so its
# still running and still answering after is the container that was there, by id,
# not one the failed deploy started. Exactly exit 1, for the reason the `simple`
# arm's missing tag is: a refusal of the request as written would leave it
# serving because nothing was attempted. The reference on stderr is the server's
# naming of the pull that failed; the engine's own line names only the layer.
arm_pull_stream_fails() {
    local v1 v1_id
    v1="$workload_repo:v1"

    echo "==> $image: a simple deploy of $v1, then of $missing_layer_reference, whose layer the registry does not have"
    deploy_service "$pull_fails_service" "$v1" "$pull_fails_host" simple
    expect_code "deploy $v1" 0
    v1_id="$(container_id_of "$pull_fails_service")"
    expect_running_at "$v1_id" "$v1"
    expect_served_by "$pull_fails_host" "$v1_id"
    deploy_service "$pull_fails_service" "$missing_layer_reference" "$pull_fails_host" simple
    expect_code "deploy $missing_layer_reference" 1
    expect_stream_contains "deploy $missing_layer_reference" stderr "could not pull $missing_layer_reference"
    expect_running_at "$v1_id" "$v1"
    expect_served_by "$pull_fails_host" "$v1_id"
}

# The service the credentials arm deploys, named and hosted apart from the other
# arms' for the reasons the `simple` arm's are.
credentials_service="bondi-check-credentials-$$"
credentials_host="credentials.check-server-image.invalid"

# A pull from a registry that wants credentials succeeds when the deploy carries
# them, and fails naming the image when it does not. The second half is what gives
# the first meaning: it shows the registry refuses an anonymous pull, so the pull
# that succeeds was authorised by the header the server sent. That header is
# base64url with padding, and these credentials put both `-` and `_` in it, the
# characters a reader of standard base64 would take for something else. The
# encoding is computed again here, independently of the server's, and asserted to
# hold all three; what the Engine accepted is what the deploy then shows.
arm_registry_credentials() {
    local reference auth_json encoded id before
    reference="$auth_repo:v1"
    auth_json="$(printf '{"serveraddress":"localhost:%s","username":"%s","password":"%s"}' \
        "$auth_registry_port" "$auth_registry_user" "$auth_registry_pass")"
    encoded="$(printf '%s' "$auth_json" | base64 | tr -d '\n' | tr '+/' '-_')"
    case "$encoded" in
        *-*) ;;
        *)
            echo "error: expected the auth header's base64url to hold '-', and it is $encoded" >&2
            return 1
            ;;
    esac
    case "$encoded" in
        *_*) ;;
        *)
            echo "error: expected the auth header's base64url to hold '_', and it is $encoded" >&2
            return 1
            ;;
    esac
    case "$encoded" in
        *=) ;;
        *)
            echo "error: expected the auth header's base64url to end in padding, and it is $encoded" >&2
            return 1
            ;;
    esac
    echo "ok: the auth header's base64url holds '-', '_' and padding: $encoded"

    echo "==> $image: a simple deploy of $reference, from a registry that wants credentials, with none and then with them"
    deploy_service "$credentials_service" "$reference" "$credentials_host" simple
    expect_code "deploy $reference without credentials" 1
    expect_stream_contains "deploy $reference without credentials" stderr "could not pull $reference"
    before="$(docker ps --all --quiet --no-trunc --filter "name=^/$credentials_service\$")"
    if [ -n "$before" ]; then
        echo "error: expected no container named $credentials_service after a refused pull, and $before exists" >&2
        return 1
    fi
    deploy_service "$credentials_service" "$reference" "$credentials_host" simple \
        "\"registry_user\": \"$auth_registry_user\"" "\"registry_pass\": \"$auth_registry_pass\""
    expect_code "deploy $reference with credentials" 0
    id="$(container_id_of "$credentials_service")"
    expect_running_at "$id" "$reference"
    expect_served_by "$credentials_host" "$id"
}

# The address the Traefik arms register with the certificate server. Pebble
# sends nothing to it, and the domain is one reserved for examples.
traefik_acme_email="bondi-check@example.com"

# The payload members that have a deploy run Traefik from the given image, set
# in `traefik_members` for the caller to pass to `deploy_service`. The
# certificate server is always Pebble, on every Traefik arm: a Traefik the server
# creates with none set orders from Let's Encrypt, and no run of this gate may.
traefik_members=()
traefik_settings() {
    traefik_members=(
        "\"traefik_image\": \"$1\""
        "\"traefik_acme_email\": \"$traefik_acme_email\""
        "\"traefik_acme_ca_server\": \"$pebble_directory\""
    )
}

# The certificate a Traefik serves for a host was issued by this run's Pebble. The
# issuer must be the intermediate Pebble generated at start and named in its log,
# whose name ends in a random suffix, so neither Traefik's default certificate nor
# one from any other server carries it.
#
# The handshake is made by this shell's openssl, the only client here that
# prints a certificate, and it reaches the Traefik through a relay: a busybox
# `nc` on the engine's default bridge, joined to the gate's network, that
# forwards each connection to that Traefik's address there. Neither the Traefik's
# published port 443 nor its address on the gate's network answered this shell,
# while the default bridge did [observed -- 2026-11-20, Docker Engine 29.10.0: a
# connection to a port published from a user-defined network, and to a container's
# address on one, hung; the same relay answered at once]. The relay is asked by
# the Traefik's id, so the answer comes from that container and no other.
#
# Polled, because Traefik orders after it starts and Pebble takes seconds to
# issue [observed -- 2026-11-19: about 12 s for one host]; each read is cut off
# at 5 s, so a handshake that hangs ends the attempt rather than the wait. The
# relay is removed on every path out once it exists, each refusal included, so a
# failed run does not leave it running until teardown. `issuer_attempts` is the
# poll's length, a variable so that a test can end it.
relay_port=8443
issuer_attempts=60
expect_issued_by_pebble() {
    local id host pebble_log issuer_cn expected traefik_address relay_id relay_address issuer attempt
    id="$1"
    host="$2"
    require_full_id "$id" expect_issued_by_pebble || return 1
    pebble_log="$(docker logs "$fixture_pebble" 2>&1)"
    issuer_cn="$(sed -n 's/.* Generated new intermediate issuer CN=\(.*\) with serial .*/\1/p' <<< "$pebble_log")"
    if [ -z "$issuer_cn" ] || [ "$(printf '%s\n' "$issuer_cn" | wc -l)" -ne 1 ]; then
        echo "error: expected one intermediate issuer named in $fixture_pebble's log, and found '$issuer_cn'" >&2
        return 1
    fi
    expected="issuer=CN=$issuer_cn"
    traefik_address="$(docker container inspect \
        --format "{{with index .NetworkSettings.Networks \"$fixture_network\"}}{{.IPAddress}}{{end}}" "$id")"
    if [ -z "$traefik_address" ]; then
        echo "error: $id has no address on $fixture_network" >&2
        return 1
    fi
    relay_id="$(docker run --detach --label "$fixture_label" "$busybox_image" \
        nc -lk -p "$relay_port" -e nc "$traefik_address" 443)"
    docker network connect "$fixture_network" "$relay_id"
    relay_address="$(docker container inspect \
        --format '{{with index .NetworkSettings.Networks "bridge"}}{{.IPAddress}}{{end}}' "$relay_id")"
    if [ -z "$relay_address" ]; then
        echo "error: the relay $relay_id has no address on the engine's default bridge" >&2
        docker rm --force "$relay_id" > /dev/null
        return 1
    fi
    issuer=""
    attempt=0
    while [ "$attempt" -lt "$issuer_attempts" ]; do
        if timeout 5 openssl s_client -connect "$relay_address:$relay_port" -servername "$host" \
            < /dev/null > "$work/served-certificate" 2> "$work/served-certificate-stderr"; then
            issuer="$(openssl x509 -noout -issuer -nameopt RFC2253 -in "$work/served-certificate" 2> /dev/null || true)"
            if [ "$issuer" = "$expected" ]; then
                docker rm --force "$relay_id" > /dev/null
                echo "ok: the certificate $id serves for $host was issued by $issuer_cn, this run's Pebble"
                return 0
            fi
        fi
        attempt=$((attempt + 1))
        sleep 1
    done
    {
        echo "error: expected the certificate $id serves for $host to be issued by $issuer_cn"
        echo "  last issuer: '$issuer'"
        echo "--- openssl stderr ---"
        cat "$work/served-certificate-stderr"
        echo "--- $id logs ---"
        docker logs "$id" 2>&1 || true
        echo "--- $fixture_pebble logs ---"
        docker logs "$fixture_pebble" 2>&1 || true
    } >&2
    docker rm --force "$relay_id" > /dev/null
    return 1
}

# The container's log names a host, and does not name another. The log is read
# into a variable and grep reads it from there, rather than from a pipe, for the
# reason `expect_container_log_contains` gives: a `grep -q` that matched and exited
# early would fail the pipeline and read as no match. A log that cannot be read
# fails at the read, under `set -e`, rather than passing as one that names
# nothing.
#
# The Traefik a deploy creates from the gate's copy logs at DEBUG, which is what
# puts the certificate server it contacts in its log: at the default level, error,
# a Traefik that ordered without error logs nothing, and an assertion that its log
# lacks a host passes whatever it did [observed -- 2026-11-20, Docker Engine
# 29.10.0]. `expect_log_names_host` is the affirmative half, asked first: a log
# that names the host Traefik was told to order from is one that would have named
# another.
expect_log_names_host() {
    local id needle log
    id="$1"
    needle="$2"
    require_full_id "$id" expect_log_names_host || return 1
    log="$(docker logs "$id" 2>&1)"
    if ! grep -qiF -- "$needle" <<< "$log"; then
        {
            echo "error: expected $id's log to name $needle, and it does not:"
            echo "$log"
        } >&2
        return 1
    fi
    echo "ok: $id's log names $needle"
}

expect_log_lacks_host() {
    local id needle log
    id="$1"
    needle="$2"
    require_full_id "$id" expect_log_lacks_host || return 1
    log="$(docker logs "$id" 2>&1)"
    if grep -qiF -- "$needle" <<< "$log"; then
        {
            echo "error: expected $id's log not to name $needle, and it does:"
            grep -iF -- "$needle" <<< "$log"
        } >&2
        return 1
    fi
    echo "ok: $id's log does not name $needle"
}

# The service the Traefik pull-failure arm deploys, named and hosted apart from
# the other arms' for the reasons the `simple` arm's are.
traefik_pull_fails_service="bondi-check-traefik-pull-fails-$$"
traefik_pull_fails_host="traefik-pull-fails.check-server-image.invalid"

# A deploy that asks for a Traefik image the registry does not have leaves the
# running Traefik in place and serving. The server pulls Traefik's replacement
# before it stops the running one, so a pull that fails stops nothing; a server
# that stopped first would leave no Traefik at all. The tag is one of the
# Traefik copy's repository never pushed, so the pull reaches the registry and is
# refused by it, and the image differs from the running one, so the server does
# plan the replacement. Exactly exit 1, for the reason the `simple` arm's missing
# tag is. The reference after the server's prefix ties the failure to Traefik's
# pull: the engine's refusal names the tag on its own, and a workload pull's
# failure would name the workload's image. The Traefik and the workload are both
# asked by id after, so what serves is what was there.
arm_traefik_pull_fails() {
    local v1 missing traefik_id v1_id
    v1="$workload_repo:v1"
    missing="$traefik_copy_repo:never-pushed"

    echo "==> $image: a simple deploy of $v1, then of it again asking for Traefik at $missing, a tag the registry does not have"
    deploy_service "$traefik_pull_fails_service" "$v1" "$traefik_pull_fails_host" simple
    expect_code "deploy $v1" 0
    v1_id="$(container_id_of "$traefik_pull_fails_service")"
    expect_running_at "$v1_id" "$v1"
    traefik_id="$(container_id_of "$fixture_traefik")"
    expect_running_at "$traefik_id" "$traefik_image"
    expect_served_by "$traefik_pull_fails_host" "$v1_id"
    traefik_settings "$missing"
    deploy_service "$traefik_pull_fails_service" "$v1" "$traefik_pull_fails_host" simple "${traefik_members[@]}"
    expect_code "deploy with Traefik $missing" 1
    expect_stream_contains "deploy with Traefik $missing" stderr "could not pull $missing"
    expect_running_at "$traefik_id" "$traefik_image"
    expect_running_at "$v1_id" "$v1"
    expect_served_by "$traefik_pull_fails_host" "$v1_id"
}

# The database the drain workload reaches, as `host:port`, once the echo is up,
# and the empty string before.
drain_echo_address=""
drain_echo="bondi-check-drain-echo-$$"

# The echo is started off the network a deploy attaches to, on the engine's
# default bridge, and published on that network's gateway address alone, on a
# port the engine picks: the drain workload reaches it through the host, as a
# service reaches a database hosted elsewhere, and a container with no network
# cannot reach it at all. Up means a round trip from a container on that network
# came back, which is also what shows the workload's route to it exists. Started
# once, by whichever arm asks first.
start_drain_echo() {
    local gateway published attempt
    if [ -n "$drain_echo_address" ]; then
        return 0
    fi
    gateway="$(docker network inspect --format '{{range .IPAM.Config}}{{.Gateway}} {{end}}' "$fixture_network" \
        | tr ' ' '\n' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n 1 || true)"
    if [ -z "$gateway" ]; then
        echo "error: $fixture_network has no IPv4 gateway for the drain echo to publish on" >&2
        return 1
    fi
    docker run --detach --name "$drain_echo" --label "$fixture_label" \
        --publish "$gateway::15432" "$drain_client_image" python -u /echo.py > /dev/null
    published="$(docker port "$drain_echo" 15432/tcp | head -n 1)"
    case "$published" in
        "$gateway":[0-9]*) ;;
        *)
            echo "error: the drain echo was published at '$published', expected $gateway:<port>" >&2
            return 1
            ;;
    esac
    attempt=0
    while [ "$attempt" -lt "$attempts" ]; do
        if [ "$(docker run --rm --label "$fixture_label" --network "$fixture_network" "$busybox_image" \
            sh -c "echo ping | nc -w 2 ${published%:*} ${published##*:}" 2> /dev/null)" = ping ]; then
            drain_echo_address="$published"
            echo "ok: the drain echo answers at $published from $fixture_network, off it"
            return 0
        fi
        attempt=$((attempt + 1))
        sleep 1
    done
    echo "error: the drain echo at $published did not answer from $fixture_network after ${attempts}s" >&2
    docker logs "$drain_echo" >&2 2>&1 || true
    return 1
}

# The payload members a drain workload deploy adds: the blue-green settings, and
# where its database is and which name it looks up on shutdown. The name is the
# gate's Traefik's, which Docker's resolver on the network answers: a lookup the
# workload can only make while it has a network, and one that sends no query to
# a third party's resolver, which a lookup of a public name would.
#
# The health wait polls every quarter second rather than the other arms' second,
# so the server acts on the new container's health as soon after its `healthy`
# event as it can. Traefik applies what its Docker provider sees at most every
# two seconds, so the configuration that adds the new container can land up to
# two seconds after that event; a server that stopped the old container at once
# would stop the only one Traefik knows. That window is what the settle before
# the stop covers, and a fast poll is what keeps it open when the settle is
# missing: with the one-second poll a run with no settle lost 6 of 726 requests
# and passed [observed -- 2026-11-22, Docker Engine 29.10.0].
drain_members() {
    drain_deploy_members=('"health_timeout": 30.0' '"poll_interval": 0.25'
        "\"env_vars\": {\"DB_HOST\": \"${drain_echo_address%:*}\", \"DB_PORT\": \"${drain_echo_address##*:}\", \"DNS_NAME\": \"$fixture_traefik\"}")
}
drain_deploy_members=()

# What the container being replaced says and how it ends, recorded from before the
# deploy that stops it, because that deploy removes it: its log, followed into
# `$work/<prefix>-old.log`, which ends when the container is removed, and the
# exit code its `die` event carries, into `$work/<prefix>-old.die`. The event is
# followed rather than asked for afterwards, because the engine keeps only its
# most recent events for a later query and the health checks of every workload on
# the engine fill that quickly. Each follower is bounded: the log's by the
# container's removal, which teardown also does, and the event stream's by an
# `--until` five minutes on, so neither outlives a run that fails between here and
# `stop_following_old`.
following_logs_pid=""
following_events_pid=""
follow_old() {
    local id prefix
    id="$1"
    prefix="$2"
    docker logs --follow "$id" > "$work/$prefix-old.log" 2>&1 &
    following_logs_pid=$!
    docker events --filter "container=$id" --filter event=die \
        --format '{{.Actor.Attributes.exitCode}}' --until "$(($(date +%s) + 300))" \
        > "$work/$prefix-old.die" &
    following_events_pid=$!
}

# The log follower ends on its own once the deploy has removed the container; it
# is given ten seconds to, and stopped after them, in which case the lines it did
# not read are missing and the assertions on them fail. The event stream is then
# stopped.
stop_following_old() {
    local attempt
    attempt=0
    while kill -0 "$following_logs_pid" 2> /dev/null && [ "$attempt" -lt 50 ]; do
        attempt=$((attempt + 1))
        sleep 0.2
    done
    kill "$following_logs_pid" "$following_events_pid" 2> /dev/null || true
    wait "$following_logs_pid" "$following_events_pid" 2> /dev/null || true
}

# The line of the old container's log that has the event, or the empty string.
# Every line names its event second and its fields as key=value.
old_line() {
    awk -v event="$2" '$2 == event' "$work/$1-old.log" | head -n 1
}

# The old container left on its own: its `die` event carries exit code 0, not
# the 137 of the SIGKILL the engine sends at the stop timeout, and its log has
# the line it writes last.
expect_old_exited_on_its_own() {
    local prefix code
    prefix="$1"
    code="$(cat "$work/$prefix-old.die")"
    case "$code" in
        0) ;;
        137)
            echo "error: the old container was killed at the stop timeout: its die event carries exit code 137" >&2
            return 1
            ;;
        *)
            echo "error: expected one die event with exit code 0 for the old container, got '$code'" >&2
            return 1
            ;;
    esac
    if [ -z "$(old_line "$prefix" stopping)" ]; then
        echo "error: the old container exited 0 without logging that it was stopping" >&2
        cat "$work/$prefix-old.log" >&2
        return 1
    fi
    echo "ok: the old container exited 0 on its own after SIGTERM: $(old_line "$prefix" stopping)"
}

# The service the swap arm deploys, named and hosted apart from the other arms'
# for the reasons the `simple` arm's are.
swap_service="bondi-check-swap-$$"
swap_host="swap.check-server-image.invalid"
# The request stream's rate and per-request timeout, and how long it runs before
# the deploy starts and after it returns. The window must hold at least 600
# requests, so the 1-in-100 bound allows a handful rather than one or two. At 50 a
# second the ten seconds of margin give 500, and the deploy, its three-second
# settle included, adds the rest; a window that falls short fails the arm rather
# than passing it on fewer.
swap_rate=50
swap_timeout=15
swap_lead=5
swap_tail=5
swap_minimum_requests=600

# A blue-green swap under a steady stream of requests through Traefik, with a
# request held in flight by the container being replaced. The drain workload
# deployed at v1 is replaced by v2. Before that deploy, a slow request is sent to
# v1 directly, by its address on the network, and is seen to have reached it;
# the workload holds it until SIGTERM and two seconds more, so it is in flight
# when the stop arrives, whatever the deploy's timing. An open-loop stream then
# runs from before the deploy until after it. The arm fails if more than 1 in 100
# of the stream's requests failed, if the stream sent fewer than 600, if either
# of v1's shutdown probes (a DNS lookup and a database round trip, made after
# its requests finished) failed, if the held request did not come back 200 with
# its round trip after SIGTERM done, or if v1 exited by SIGKILL. That the stream
# was answered by v1 and by v2 is the affirmative half of its bound: the
# requests counted crossed the swap.
arm_blue_green_swap() {
    local v1 v2 v1_id v2_id short_old short_new old_address slow stream_pid stream_status
    local summary total failed by_old by_new slow_status slow_body dns db released attempt verdict_failures
    v1="$drain_repo:v1"
    v2="$drain_repo:v2"
    slow="bondi-check-drain-slow-$$"

    echo "==> $image: a blue-green deploy of $v1, then of $v2 under a stream of requests"
    start_drain_echo
    drain_members
    deploy_service "$swap_service" "$v1" "$swap_host" blue-green "${drain_deploy_members[@]}"
    expect_code "deploy $v1" 0
    v1_id="$(container_id_of "$swap_service")"
    expect_running_at "$v1_id" "$v1"
    expect_served_by "$swap_host" "$v1_id"
    short_old="${v1_id:0:12}"

    follow_old "$v1_id" swap
    old_address="$(docker inspect --format "{{(index .NetworkSettings.Networks \"$fixture_network\").IPAddress}}" "$v1_id")"
    docker run --detach --name "$slow" --label "$fixture_label" --network "$fixture_network" "$busybox_image" \
        wget -q -T 60 -O - "http://$old_address:$workload_port/slow?s=2" > /dev/null
    attempt=0
    while [ -z "$(old_line swap slow-start)" ] && [ "$attempt" -lt 50 ]; do
        attempt=$((attempt + 1))
        sleep 0.2
    done
    if [ -z "$(old_line swap slow-start)" ]; then
        echo "error: the slow request did not reach $short_old within 10s" >&2
        docker logs "$slow" >&2 2>&1 || true
        return 1
    fi
    echo "ok: a slow request is held by $short_old: $(old_line swap slow-start)"

    docker run --rm --name "bondi-check-drain-stream-$$" --label "$fixture_label" --network "$fixture_network" \
        "$drain_client_image" python -u /stream.py "https://$fixture_traefik/" "$swap_host" "$swap_rate" "$swap_timeout" \
        > "$work/swap-stream" 2> "$work/swap-stream-stderr" &
    stream_pid=$!
    sleep "$swap_lead"
    deploy_service "$swap_service" "$v2" "$swap_host" blue-green "${drain_deploy_members[@]}"
    expect_code "deploy $v2" 0
    sleep "$swap_tail"
    docker kill --signal TERM "bondi-check-drain-stream-$$" > /dev/null
    stream_status=0
    wait "$stream_pid" || stream_status=$?
    stop_following_old
    v2_id="$(container_id_of "$swap_service")"
    expect_running_at "$v2_id" "$v2"
    expect_gone "$v1_id"
    short_new="${v2_id:0:12}"

    # Every verdict below is reached and printed before the arm fails, so one run
    # says everything that went wrong in the swap.
    verdict_failures=0
    if [ "$stream_status" != 0 ]; then
        echo "error: the request stream exited $stream_status" >&2
        cat "$work/swap-stream-stderr" >&2
        verdict_failures=$((verdict_failures + 1))
    fi
    if ! summary="$(awk -v old="$short_old" -v new="$short_new" '
        { total++ }
        $2 < 200 || $2 > 299 { failed++ }
        $2 >= 200 && $2 <= 299 && $3 == old { by_old++ }
        $2 >= 200 && $2 <= 299 && $3 == new { by_new++ }
        END { printf "%d %d %d %d\n", total, failed, by_old, by_new }' "$work/swap-stream")"; then
        echo "error: the request stream's log could not be summarised" >&2
        summary="0 0 0 0"
        verdict_failures=$((verdict_failures + 1))
    fi
    read -r total failed by_old by_new <<< "$summary"
    echo "the stream: $total requests at $swap_rate/s, each failed after ${swap_timeout}s without an answer; $failed failed, $by_old answered by $short_old, $by_new by $short_new"
    if [ "$failed" -gt 0 ]; then
        echo "  the requests that failed (started, status, body or error, seconds):"
        awk '$2 < 200 || $2 > 299 { print "    " $0 }' "$work/swap-stream"
    fi
    if [ "$total" -lt "$swap_minimum_requests" ]; then
        echo "error: the stream sent $total requests, fewer than the $swap_minimum_requests a 1-in-100 bound needs" >&2
        verdict_failures=$((verdict_failures + 1))
    fi
    if [ "$by_old" -eq 0 ] || [ "$by_new" -eq 0 ]; then
        echo "error: the stream did not cross the swap: $by_old answers from $short_old, $by_new from $short_new" >&2
        verdict_failures=$((verdict_failures + 1))
    fi
    if [ $((failed * 100)) -gt "$total" ]; then
        echo "error: $failed of $total requests through $fixture_traefik failed during the swap, more than 1 in 100" >&2
        verdict_failures=$((verdict_failures + 1))
    else
        echo "ok: $failed of $total requests failed during the swap, no more than 1 in 100"
    fi

    if ! slow_status="$(docker wait "$slow")"; then
        echo "error: the engine did not report how $slow ended" >&2
        slow_status="unknown"
        verdict_failures=$((verdict_failures + 1))
    fi
    if ! slow_body="$(docker logs "$slow" 2>&1)"; then
        echo "error: the engine did not return the log of $slow" >&2
        slow_body=""
        verdict_failures=$((verdict_failures + 1))
    fi
    if ! docker rm "$slow" > /dev/null; then
        echo "error: the engine did not remove $slow" >&2
        verdict_failures=$((verdict_failures + 1))
    fi
    released="$(old_line swap slow-done)"
    case "$slow_status:$slow_body:$released" in
        "0:$short_old slow db_before=ok"*"db_after=ok"*":"*"released_by_sigterm=True db_after=ok"*)
            echo "ok: the held request came back from $short_old after SIGTERM: $slow_body"
            ;;
        *)
            {
                echo "error: expected the held request answered 200 by $short_old, its round trip after SIGTERM ok"
                echo "  wget exited $slow_status with '$slow_body'"
                echo "  the old container logged '$released'"
            } >&2
            verdict_failures=$((verdict_failures + 1))
            ;;
    esac

    dns="$(old_line swap shutdown-dns)"
    db="$(old_line swap shutdown-db)"
    case "$dns" in
        *" result=ok:"*) echo "ok: after its requests finished, the old container resolved $fixture_traefik: $dns" ;;
        *)
            echo "error: the old container's DNS lookup on shutdown did not succeed: '$dns'" >&2
            verdict_failures=$((verdict_failures + 1))
            ;;
    esac
    case "$db" in
        *" result=ok:"*) echo "ok: after its requests finished, the old container reached its database: $db" ;;
        *)
            echo "error: the old container's database round trip on shutdown did not succeed: '$db'" >&2
            verdict_failures=$((verdict_failures + 1))
            ;;
    esac
    if ! expect_old_exited_on_its_own swap; then
        verdict_failures=$((verdict_failures + 1))
    fi
    if [ "$verdict_failures" != 0 ]; then
        {
            echo "error: the swap failed $verdict_failures of its checks; the old container's log:"
            cat "$work/swap-old.log"
        } >&2
        return 1
    fi
}

# The service the upload arm deploys, named and hosted apart from the other arms'
# for the reasons the `simple` arm's are.
upload_service="bondi-check-upload-$$"
upload_host="upload.check-server-image.invalid"
# Each upload is 256 KiB paced at 128 KiB a second, so it is in flight for about
# two seconds, and one starts every quarter second, so about eight are in flight
# at any moment: the container being replaced holds some of them when it is sent
# SIGTERM, each with less left to read than its five seconds of grace.
upload_size=262144
upload_pace=131072
upload_interval=0.25
upload_timeout=15

# The upload verdict, from the backends' logs (the old container's, then the
# new's) and the uploader's lines, as `ERROR <reason>` lines and one
# `SUMMARY <sent> <answered 2xx> <matched> <failed visibly> <crossed>` line. An
# upload and a backend's record of it are joined by the upload's id, never by
# order. An upload answered 2xx is matched when a backend recorded its body
# complete, at the length and digest sent; one answered otherwise failed
# visibly. A record of a complete body at any other length or digest than the
# one sent, and an id that reached a backend more than once, are errors whatever
# the upload's answer. An upload crossed the swap when it reached the old
# container before that container logged SIGTERM and was not recorded before it.
upload_verdict() {
    awk -v old_log="$1" -v uploads="$3" '
        function field(name,    i) {
            for (i = 3; i <= NF; i++) {
                if (index($i, name "=") == 1) {
                    return substr($i, length(name) + 2)
                }
            }
            return ""
        }
        FILENAME == uploads {
            sent[$1] = 1; sent_length[$1] = $2; sent_digest[$1] = $3; status[$1] = $4
            next
        }
        FILENAME == old_log && $2 == "sigterm" { sigterm = 1 }
        $2 == "upload-start" {
            id = field("id")
            starts[id]++
            if (FILENAME == old_log && !sigterm) { before_sigterm[id] = 1 }
        }
        $2 == "upload" {
            id = field("id")
            recorded[id] = 1
            complete[id] = field("complete"); length_read[id] = field("length"); digest_read[id] = field("sha256")
            if (FILENAME == old_log && !sigterm) { recorded_before_sigterm[id] = 1 }
        }
        END {
            for (id in sent) {
                total++
                if (status[id] >= 200 && status[id] <= 299) {
                    answered++
                    if (recorded[id] && complete[id] == "True" && length_read[id] == sent_length[id] && digest_read[id] == sent_digest[id]) {
                        matched++
                    } else {
                        printf "ERROR upload %s was answered %s, and no backend recorded its %s bytes whole (recorded: complete=%s length=%s)\n", id, status[id], sent_length[id], complete[id], length_read[id]
                    }
                } else {
                    visible++
                }
            }
            for (id in recorded) {
                if (complete[id] == "True" && (!(id in sent) || length_read[id] != sent_length[id] || digest_read[id] != sent_digest[id])) {
                    printf "ERROR a backend recorded upload %s complete at %s bytes, sha256 %s, and %s bytes were sent\n", id, length_read[id], digest_read[id], sent_length[id]
                }
            }
            for (id in starts) {
                if (starts[id] > 1) { printf "ERROR upload %s reached a backend %d times\n", id, starts[id] }
                if (before_sigterm[id] && !recorded_before_sigterm[id]) { crossed++ }
            }
            printf "SUMMARY %d %d %d %d %d\n", total, answered, matched, visible, crossed
        }' "$1" "$2" "$3"
}

# Uploads of known length and digest run through Traefik across a blue-green swap
# of the drain workload, from v1 to v2. Each one is either answered 2xx with a
# backend's record of its body equal, in length and digest, to what was sent, or
# fails visibly; no backend records a short body as complete, and no upload
# reaches a backend twice. That uploads were matched, and that at least one was
# in flight to v1 when v1 was sent SIGTERM, are the affirmative halves: the
# uploads judged crossed the swap.
arm_blue_green_upload() {
    local v1 v2 v1_id v2_id short_old uploader_pid uploader_status verdict summary
    local total answered matched visible crossed verdict_failures
    v1="$drain_repo:v1"
    v2="$drain_repo:v2"

    echo "==> $image: a blue-green deploy of $v1, then of $v2 under uploads"
    start_drain_echo
    drain_members
    deploy_service "$upload_service" "$v1" "$upload_host" blue-green "${drain_deploy_members[@]}"
    expect_code "deploy $v1" 0
    v1_id="$(container_id_of "$upload_service")"
    expect_running_at "$v1_id" "$v1"
    expect_served_by "$upload_host" "$v1_id"
    short_old="${v1_id:0:12}"

    follow_old "$v1_id" upload
    docker run --rm --name "bondi-check-drain-upload-$$" --label "$fixture_label" --network "$fixture_network" \
        "$drain_client_image" python -u /upload.py "$fixture_traefik" "$upload_host" \
        "$upload_interval" "$upload_size" "$upload_pace" "$upload_timeout" "u$$" \
        > "$work/uploads" 2> "$work/uploads-stderr" &
    uploader_pid=$!
    sleep "$swap_lead"
    deploy_service "$upload_service" "$v2" "$upload_host" blue-green "${drain_deploy_members[@]}"
    expect_code "deploy $v2" 0
    sleep "$swap_tail"
    docker kill --signal TERM "bondi-check-drain-upload-$$" > /dev/null
    uploader_status=0
    wait "$uploader_pid" || uploader_status=$?
    stop_following_old
    v2_id="$(container_id_of "$upload_service")"
    expect_running_at "$v2_id" "$v2"
    expect_gone "$v1_id"
    docker logs "$v2_id" > "$work/upload-new.log" 2>&1

    verdict_failures=0
    if [ "$uploader_status" != 0 ]; then
        echo "error: the uploader exited $uploader_status" >&2
        cat "$work/uploads-stderr" >&2
        verdict_failures=$((verdict_failures + 1))
    fi
    verdict="$(upload_verdict "$work/upload-old.log" "$work/upload-new.log" "$work/uploads")"
    summary="$(printf '%s\n' "$verdict" | sed -n 's/^SUMMARY //p')"
    if [ -z "$summary" ]; then
        echo "error: the uploads' verdict carried no SUMMARY line, so nothing here was compared" >&2
        verdict_failures=$((verdict_failures + 1))
        summary="0 0 0 0 0"
    fi
    read -r total answered matched visible crossed <<< "$summary"
    echo "the uploads: $total of $upload_size bytes each; $answered answered 2xx, $matched of them recorded whole by a backend; $visible failed visibly; $crossed in flight to $short_old at its SIGTERM"
    if printf '%s\n' "$verdict" | grep -q '^ERROR '; then
        printf '%s\n' "$verdict" | sed -n 's/^ERROR /error: /p' >&2
        verdict_failures=$((verdict_failures + 1))
    fi
    if [ "${visible:-0}" -gt 0 ]; then
        echo "  the uploads that failed visibly (id, length, sha256, status, body or error):"
        awk '$4 < 200 || $4 > 299 { print "    " $0 }' "$work/uploads"
    fi
    if [ "${matched:-0}" -eq 0 ]; then
        echo "error: no upload was answered 2xx and recorded whole, so nothing here was compared" >&2
        verdict_failures=$((verdict_failures + 1))
    fi
    if [ "${crossed:-0}" -eq 0 ]; then
        echo "error: no upload was in flight to $short_old when it was sent SIGTERM, so none crossed the swap" >&2
        verdict_failures=$((verdict_failures + 1))
    fi
    if [ "$verdict_failures" != 0 ]; then
        {
            echo "error: the uploads failed $verdict_failures of their checks; the old container's log:"
            cat "$work/upload-old.log"
        } >&2
        return 1
    fi
    echo "ok: every upload answered 2xx was recorded whole, the rest failed visibly, and none was recorded short"
}

# The service the Traefik replacement arm deploys, named and hosted apart from
# the other arms' for the reasons the `simple` arm's are.
traefik_replaced_service="bondi-check-traefik-replaced-$$"
traefik_replaced_host="traefik-replaced.check-server-image.invalid"

# A deploy that asks for a Traefik image other than the one running replaces it:
# the gate's Traefik, seen running before, is gone, and a Traefik the server
# created runs the copy's second tag under the same name. The service deployed
# with it is answered through that Traefik, which is the only one left on the
# network under the name the probe asks. That Traefik orders the host's
# certificate from the certificate server the deploy named, Pebble, and not from
# Let's Encrypt: the certificate it serves was issued by Pebble, and its log
# names no Let's Encrypt host.
arm_traefik_replaced() {
    local v1 copy old_id new_id v1_id
    v1="$workload_repo:v1"
    copy="$traefik_copy_repo:${traefik_copy_tags[1]}"

    echo "==> $image: a simple deploy of $v1 asking for Traefik at $copy, with Pebble as its certificate server"
    old_id="$(container_id_of "$fixture_traefik")"
    expect_running_at "$old_id" "$traefik_image"
    traefik_settings "$copy"
    deploy_service "$traefik_replaced_service" "$v1" "$traefik_replaced_host" simple "${traefik_members[@]}"
    expect_code "deploy with Traefik $copy" 0
    new_id="$(container_id_of "$fixture_traefik")"
    expect_running_at "$new_id" "$copy"
    expect_gone "$old_id"
    v1_id="$(container_id_of "$traefik_replaced_service")"
    expect_running_at "$v1_id" "$v1"
    expect_served_by "$traefik_replaced_host" "$v1_id"
    expect_issued_by_pebble "$new_id" "$traefik_replaced_host"
    expect_log_names_host "$new_id" "${pebble_directory#https://}"
    expect_log_lacks_host "$new_id" letsencrypt.org
}

# The service the blue-green Traefik replacement arm deploys, named and hosted
# apart from the other arms' for the reasons the `simple` arm's are.
blue_green_traefik_service="bondi-check-blue-green-traefik-$$"
blue_green_traefik_host="blue-green-traefik.check-server-image.invalid"

# Under blue-green, the deploy converges Traefik as it does under simple. A
# deploy asking for a Traefik image other than the one running replaces it: the
# Traefik `arm_traefik_replaced` left running the copy's second tag, seen
# running before, is gone, and one running the first tag stands under the same
# name. A second deploy asking for that same image with a forced redeploy, and
# nothing else changed, replaces it again: another id, the one before it gone.
# The service is answered through each Traefik by the container that deploy
# left serving, so what serves is the Traefik just created.
arm_blue_green_traefik_replaced() {
    local v1 copy running old_id first_id second_id v1_id redeployed_id
    v1="$healthcheck_repo:v1"
    copy="$traefik_copy_repo:${traefik_copy_tags[0]}"
    running="$traefik_copy_repo:${traefik_copy_tags[1]}"

    echo "==> $image: a blue-green deploy of $v1 asking for Traefik at $copy, then again with a forced Traefik redeploy"
    old_id="$(container_id_of "$fixture_traefik")"
    expect_running_at "$old_id" "$running"
    traefik_settings "$copy"
    deploy_service "$blue_green_traefik_service" "$v1" "$blue_green_traefik_host" blue-green \
        "${blue_green_settings[@]}" "${traefik_members[@]}"
    expect_code "deploy with Traefik $copy" 0
    expect_stream_contains "deploy with Traefik $copy" stdout '"strategy":"blue-green"'
    first_id="$(container_id_of "$fixture_traefik")"
    expect_running_at "$first_id" "$copy"
    expect_gone "$old_id"
    v1_id="$(container_id_of "$blue_green_traefik_service")"
    expect_running_at "$v1_id" "$v1"
    expect_served_by "$blue_green_traefik_host" "$v1_id"

    deploy_service "$blue_green_traefik_service" "$v1" "$blue_green_traefik_host" blue-green \
        "${blue_green_settings[@]}" "${traefik_members[@]}" '"force_traefik_redeploy": true'
    expect_code "deploy with Traefik $copy, redeployed" 0
    expect_stream_contains "deploy with Traefik $copy, redeployed" stdout '"strategy":"blue-green"'
    second_id="$(container_id_of "$fixture_traefik")"
    expect_running_at "$second_id" "$copy"
    expect_gone "$first_id"
    redeployed_id="$(container_id_of "$blue_green_traefik_service")"
    expect_running_at "$redeployed_id" "$v1"
    expect_served_by "$blue_green_traefik_host" "$redeployed_id"
}

# The service the fresh-box arm deploys, named and hosted apart from the other
# arms' for the reasons the `simple` arm's are.
fresh_service="bondi-check-fresh-$$"
fresh_host="fresh.check-server-image.invalid"

# A deploy sent to the orchestrator in the background, with Pebble joined to the
# network a deploy attaches to as soon as the deploy has made it, and then waited
# for: its status and streams land where `run_subcommand` leaves them. A fresh
# box has no such network for Pebble to be on before the deploy, and a Traefik
# the deploy creates orders a host's certificate only once a router names that
# host. Under blue-green that is once the new container passes its health check,
# after the network, the Traefik and the container have all been made, so
# Pebble is on the network by then [assumed from Traefik's Docker provider,
# which leaves out a container whose health check has not passed; the order is
# not observed here]. A Traefik that ordered before Pebble joined would fail the
# issuance assertion, never pass it.
#
# The network is recorded for teardown as soon as it is seen: the preconditions
# and the arm saw no network of that name before the deploy, so it is the one
# this run's deploy made. The poll ends when the deploy does.
deploy_service_joining_pebble() {
    local deploy_pid network_id
    rm -f "$work/background-status"
    (
        deploy_service "$@"
        echo "$subcommand_status" > "$work/background-status"
    ) &
    deploy_pid=$!
    while kill -0 "$deploy_pid" 2> /dev/null; do
        if ! network_id="$(network_id_of "$fixture_network")"; then
            kill "$deploy_pid" 2> /dev/null || true
            wait "$deploy_pid" 2> /dev/null || true
            echo "error: the network could not be looked up while the deploy ran" >&2
            return 1
        fi
        if [ -n "$network_id" ]; then
            fixture_network_id="$network_id"
            join_pebble
            break
        fi
        sleep 0.2
    done
    # The status is read from the file the subshell wrote, so the wait's own
    # status is not the deploy's, and under `set -e` it must not end the arm here.
    wait "$deploy_pid" || true
    if [ -z "$fixture_network_id" ]; then
        if ! fixture_network_id="$(network_id_of "$fixture_network")"; then
            echo "error: the network could not be looked up after the deploy" >&2
            return 1
        fi
    fi
    if [ ! -s "$work/background-status" ]; then
        echo "error: the deploy ran in the background and left no status" >&2
        return 1
    fi
    subcommand_status="$(cat "$work/background-status")"
}

# On an engine with neither the network a deploy attaches to nor a Traefik, an
# image that declares a health check, deployed with no strategy named, deploys
# blue-green: the server creates the network and a Traefik, that Traefik orders
# the host's certificate from the certificate server the deploy named, Pebble,
# and a request for the host through it is answered by the new container. Both
# absences are asked before the deploy, and both are present after it, so what
# stands is what the deploy made. The arm then removes what the deploy made, the
# images it pulled included, so the network and Traefik the fixture makes next
# are made on an engine as it found them, and a later deploy of these images
# pulls them again.
arm_blue_green_fresh() {
    local reference copy traefik_id workload_id
    reference="$healthcheck_repo:v1"
    copy="$traefik_copy_repo:${traefik_copy_tags[0]}"

    echo "==> $image: a deploy of $reference with no strategy named, on an engine with no $fixture_network and no $fixture_traefik"
    expect_no_network "$fixture_network"
    expect_no_container_named "$fixture_traefik" "$fresh_service" "$fresh_service-new"
    traefik_settings "$copy"
    deploy_service_joining_pebble "$fresh_service" "$reference" "$fresh_host" auto \
        "${blue_green_settings[@]}" "${traefik_members[@]}"
    expect_code "deploy $reference" 0
    expect_stream_contains "deploy $reference" stdout '"strategy":"blue-green"'
    if [ -z "$fixture_network_id" ]; then
        echo "error: expected the deploy to create the network $fixture_network, and there is none" >&2
        return 1
    fi
    echo "ok: the deploy created the network $fixture_network ($fixture_network_id)"
    traefik_id="$(container_id_of "$fixture_traefik")"
    expect_running_at "$traefik_id" "$copy"
    workload_id="$(container_id_of "$fresh_service")"
    expect_running_at "$workload_id" "$reference"
    expect_served_by "$fresh_host" "$workload_id"
    expect_issued_by_pebble "$traefik_id" "$fresh_host"

    echo "==> $image: removing what the deploy of $reference created"
    docker rm --force "$workload_id" "$traefik_id" > /dev/null
    expect_gone "$workload_id"
    expect_gone "$traefik_id"
    docker network disconnect "$fixture_network" "$fixture_pebble"
    docker network rm "$fixture_network_id" > /dev/null
    fixture_network_id=""
    expect_no_network "$fixture_network"
    docker image rm "$reference" "$copy" > /dev/null
    expect_image_absent "$reference"
    expect_image_absent "$copy"
}

# Remove what the fixture made: every container carrying this run's label (the
# fixture's own and every container a deploy started from its images, with their
# anonymous volumes, which the registry declares), then the host's acme.json and
# the directories this run made for it, then the network it created, then the
# images it pushed or pulled. It reports and fails on what it could not
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
    # After the containers, any of which may bind it, and before the images, since
    # the removal runs the pinned busybox.
    if [ -n "$acme_created" ]; then
        if remove_acme_json; then
            acme_created=""
        else
            failed=1
        fi
    fi
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
