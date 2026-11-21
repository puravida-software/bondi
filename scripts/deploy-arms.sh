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
# `arm_traefik_replaced` runs last, because it has a deploy replace the gate's
# Traefik with one the server creates: every arm before it asserts through the
# gate's own.
deploy_arms=(arm_simple arm_blue_green arm_two_services arm_pull_stream_fails
    arm_registry_credentials arm_traefik_pull_fails arm_traefik_replaced)

# The host ports the fixture needs free: 80 and 443, which a Traefik the server
# creates publishes on every interface, and the two registries'.
fixture_host_ports=(80 443 "$registry_port" "$auth_registry_port")

# Refuse, naming what holds it, when the engine already has anything a deploy here
# would adopt or the registry or a Traefik the server creates would collide with,
# its host's acme.json included.
# A deploy attaches to the network by name and adopts any container whose image
# contains `traefik`, running or not, so either would put an operator's own
# deployment under this gate's deploys. The check refuses rather than skips: a gate
# that skipped would report green having asserted nothing.
#
# Every holder is named, not only the first, so one run says everything that has to
# move. Nothing here removes or changes anything, and no docker call it makes has
# an effect that outlives the run: the one image it may pull is recorded for
# teardown, and the one container it runs removes itself.
deploy_fixture_preconditions() {
    local held networks network_id containers traefik_holders port listener publisher
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
workload_tags=(v1 v2)
workload_port=8080

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

# Pebble, on the gate's network only and under the alias its own TLS certificate
# names, so a container there reaches its directory at `pebble_directory`. It is
# told to treat every challenge as valid, because nothing outside that network
# can reach a host the arms name. Up means its directory answers, asked from the
# network rather than inferred from the container running.
fixture_pebble="bondi-check-pebble-$$"
pebble_directory="https://pebble:14000/dir"
start_pebble() {
    local pebble_id attempt
    pebble_id="$(docker run --detach --name "$fixture_pebble" --label "$fixture_label" \
        --network "$fixture_network" --network-alias pebble \
        --env PEBBLE_VA_ALWAYS_VALID=1 \
        "$pebble_image")"
    attempt=0
    while [ "$attempt" -lt "$attempts" ]; do
        if docker run --rm --label "$fixture_label" --network "$fixture_network" "$busybox_image" \
            wget -q -T 2 --no-check-certificate -O - "$pebble_directory" \
            > "$work/pebble-directory" 2> /dev/null \
            && grep -qF '"newOrder"' "$work/pebble-directory"; then
            echo "ok: $fixture_pebble ($pebble_id) serves its ACME directory at $pebble_directory on $fixture_network"
            return 0
        fi
        attempt=$((attempt + 1))
        sleep 1
    done
    {
        echo "error: $fixture_pebble did not serve its ACME directory at $pebble_directory after ${attempts}s"
        echo "--- pebble logs ---"
        docker logs "$pebble_id" 2>&1 || true
    } >&2
    return 1
}

# The gate's copy of the pinned Traefik image, which trusts Pebble's CA: Pebble's
# image carries the CA that signs its TLS certificate, and the copy appends it to
# the bundle Traefik verifies a certificate server against [observed --
# 2026-11-19: the unmodified image refused Pebble's directory as signed by an
# unknown authority, and this copy registered and was issued a certificate]. It
# bakes in this run's label, so a Traefik a deploy creates from it is removed at
# teardown. It is pushed under a repository whose name contains `traefik`, because
# a deploy adopts Traefik by that substring, and at two tags, because a deploy
# replaces a running Traefik when the version it asks for differs. Both tags are
# removed from the engine once pushed, so a deploy of either pulls it.
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
    repository="$1"
    tag="$2"
    healthcheck="$3"
    docker_config="${4:-}"
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
    "${push_command[@]}" push --quiet "$reference" > /dev/null
    docker image rm "$reference" > /dev/null
    echo "ok: pushed $reference to the registry, and removed it from the engine"
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
    create_acme_json
    start_registry
    start_auth_registry
    login_auth_registry
    push_workload "$auth_repo" v1 no-healthcheck "$auth_docker_config"
    for tag in "${workload_tags[@]}"; do
        push_workload "$workload_repo" "$tag" no-healthcheck
        push_workload "$healthcheck_repo" "$tag" healthcheck
    done
    push_missing_layer
    build_traefik_copy
    fixture_network_id="$(docker network create --label "$fixture_label" "$fixture_network")"
    echo "ok: created the network $fixture_network ($fixture_network_id)"
    start_traefik
    start_pebble
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
    if grep -qxF -- "$id" <<< "$containers"; then
        echo "error: expected $id gone, and it is still on the engine" >&2
        docker ps --all --no-trunc --filter "id=$id" >&2 || true
        return 1
    fi
    echo "ok: $id is gone"
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
# leaving the server to choose one from whether the image has a health check.
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
