#!/usr/bin/env bash
# Drives deploy_fixture_preconditions (scripts/deploy-arms.sh) with a fake `docker`
# and `ss` first on PATH, one case per refusal branch plus the passing cases. The
# fake answers are well-formed except for the one holder a case plants. The fake
# docker records every invocation, so each case also asserts that no docker call
# it made has an effect that outlives the run. The function lists, reads the
# engine host's /etc through a throwaway container that binds it read-only, and
# pulls the pinned busybox that container runs only when the engine lacks it,
# recording the pull so teardown removes the image again.
#
# The fake also drives the fixture's acme.json from creation to teardown, against
# a modelled /etc on the engine's host, so that teardown is seen to remove only
# what the run created whatever already stood under /etc/traefik.
set -euo pipefail

arms="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
arms_dir="$(dirname "$arms")"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
stubs="$scratch/stubs"
tools="$scratch/tools"
mkdir -p "$stubs" "$tools"

# A PATH that holds only the stubs and the few tools the function and the stubs
# use, so that the real `ss` and `docker` cannot answer and the absent-`ss` case
# can be real.
for tool in awk sed wc cat env bash grep mv head cut tr mkdir sleep; do
    ln -s "$(command -v "$tool")" "$tools/$tool"
done

# Both port witnesses answer per port, from `publisher-<port>` and
# `listener-<port>`, so a case holds one port and leaves the others free. A port
# with no such file has nothing on it.
#
# The engine's images are the lines of `images`. The engine host's /etc is
# `host-etc`: one line per path that exists, relative to /etc, in the shape the
# fixture's probe prints (`path|type|mode|owner|size`). A path with no line is
# absent. A container is modelled by the mount it binds:
# - /etc bound read-only is the probe, which answers for each path it is given;
# - a directory under /etc bound with `--volume` is the create. As the engine
#   does, the bind makes the missing directories, root-owned and 755, and the
#   command makes the file it is given, empty and of mode 600;
# - /etc bound read-write is the removal: `rm -f` of its first path, then
#   `rmdir` of each further one, which fails on a directory that is absent or
#   not empty.
# A `run` of an image the engine lacks fails under `--pull never`, and without it
# pulls the image unrecorded, as the CLI does.
cat > "$stubs/docker" <<'S'
#!/usr/bin/env bash
echo "$*" >> "$STUB_DIR/docker.log"
has_line() { grep -qxF -- "$1" "$2"; }
drop_path() {
    grep -v "^$1|" "$STUB_DIR/host-etc" > "$STUB_DIR/host-etc.new" || true
    mv "$STUB_DIR/host-etc.new" "$STUB_DIR/host-etc"
}
case "$1" in
    run)
        shift
        pull=missing mount="" image="" paths=()
        while [ "$#" -gt 0 ]; do
            case "$1" in
                --rm) shift ;;
                --pull) pull="$2"; shift 2 ;;
                --label) shift 2 ;;
                --mount) mount="mount:$2"; shift 2 ;;
                --volume) mount="volume:$2"; shift 2 ;;
                -*) echo "stub docker: unexpected run flag: $1" >&2; exit 99 ;;
                *) image="$1"; shift; break ;;
            esac
        done
        [ "$1 $2" = "sh -c" ] || { echo "stub docker: expected sh -c: $*" >&2; exit 99; }
        shift 2
        [ "$2" = _ ] || { echo "stub docker: expected the script's arguments after _: $*" >&2; exit 99; }
        shift 2
        paths=("$@")
        if ! has_line "$image" "$STUB_DIR/images"; then
            if [ "$pull" = never ]; then
                echo "docker: Error response from daemon: No such image: $image" >&2
                exit 125
            fi
            echo "$image" >> "$STUB_DIR/images"
        fi
        case "$mount" in
            mount:type=bind,src=/etc,dst=/host-etc,readonly)
                # A case may plant a probe that fails, or one whose answer is
                # malformed, in place of the modelled one.
                if [ -e "$STUB_DIR/probe-fails" ]; then
                    echo "docker: Error response from daemon: mount denied" >&2
                    exit 125
                fi
                if [ -e "$STUB_DIR/probe-answer" ]; then
                    cat "$STUB_DIR/probe-answer"
                    exit 0
                fi
                for p in "${paths[@]}"; do
                    line="$(grep "^$p|" "$STUB_DIR/host-etc" || true)"
                    printf '%s\n' "${line:-$p|absent}"
                done
                ;;
            volume:/etc/*:/acme)
                source="${mount#volume:/etc/}"
                source="${source%:/acme}"
                prefix=""
                IFS=/ read -r -a parts <<< "$source"
                for part in "${parts[@]}"; do
                    prefix="${prefix:+$prefix/}$part"
                    grep -q "^$prefix|" "$STUB_DIR/host-etc" \
                        || echo "$prefix|directory|755|root:root|0" >> "$STUB_DIR/host-etc"
                done
                # A case may plant the mode the command leaves the file at.
                mode="$(cat "$STUB_DIR/create-mode" 2> /dev/null || echo 600)"
                echo "$source/${paths[0]}|regular empty file|$mode|root:root|0" >> "$STUB_DIR/host-etc"
                ;;
            mount:type=bind,src=/etc,dst=/host-etc)
                drop_path "${paths[0]}"
                for dir in "${paths[@]:1}"; do
                    if ! grep -q "^$dir|directory|" "$STUB_DIR/host-etc"; then
                        echo "rmdir: '/host-etc/$dir': No such file or directory" >&2
                        exit 1
                    fi
                    if grep -q "^$dir/" "$STUB_DIR/host-etc"; then
                        echo "rmdir: '/host-etc/$dir': Directory not empty" >&2
                        exit 1
                    fi
                    drop_path "$dir"
                done
                ;;
            *) echo "stub docker: unexpected run mount: $mount" >&2; exit 99 ;;
        esac
        exit 0
        ;;
    pull)
        [ "$2" = --quiet ] || { echo "stub docker: unexpected pull: $*" >&2; exit 99; }
        echo "$3" >> "$STUB_DIR/images"
        echo "$3"
        exit 0
        ;;
esac
case "$1 $2" in
    "network ls") cat "$STUB_DIR/networks" ;;
    "ps --all")
        case "$3" in
            # Teardown's listing of the containers that carry this run's label:
            # the fake runs none that outlive their command.
            --quiet) : ;;
            *) cat "$STUB_DIR/containers" ;;
        esac
        ;;
    "ps --filter")
        case "$3" in
            publish=*) cat "$STUB_DIR/publisher-${3#publish=}" 2> /dev/null || true ;;
            *) echo "stub docker: unexpected filter: $*" >&2; exit 99 ;;
        esac
        ;;
    "image inspect")
        has_line "$3" "$STUB_DIR/images" || { echo "Error: No such image: $3" >&2; exit 1; }
        ;;
    "image rm")
        has_line "$3" "$STUB_DIR/images" || { echo "Error: No such image: $3" >&2; exit 1; }
        grep -vxF -- "$3" "$STUB_DIR/images" > "$STUB_DIR/images.new" || true
        mv "$STUB_DIR/images.new" "$STUB_DIR/images"
        ;;
    *) echo "stub docker: unexpected invocation: $*" >&2; exit 99 ;;
esac
S
cat > "$stubs/ss" <<'S'
#!/usr/bin/env bash
filter="${*: -1}"
case "$filter" in
    "sport = :"*) cat "$STUB_DIR/listener-${filter#sport = :}" 2> /dev/null || true ;;
    *) echo "stub ss: unexpected invocation: $*" >&2; exit 99 ;;
esac
S
# The driver the functions below the preconditions run against: the registry's API
# through `curl`, the engine through `docker`, the handshake through `timeout` and
# `openssl`. Each answers what its case planted in "$STUB_DIR", and logs what it
# was asked.
cat > "$stubs/docker-fn" <<'S'
#!/usr/bin/env bash
echo "$*" >> "$STUB_DIR/docker.log"
case "$1" in
    run)
        for argument in "$@"; do
            if [ "$argument" = --detach ]; then
                echo detachid
                exit 0
            fi
        done
        exit "$(cat "$STUB_DIR/probe-rc" 2> /dev/null || echo 0)"
        ;;
    logs)
        case "$2" in
            bondi-check-pebble-*) cat "$STUB_DIR/logs-pebble" 2> /dev/null || true ;;
            *) cat "$STUB_DIR/logs-other" 2> /dev/null || true ;;
        esac
        ;;
    container)
        case "$*" in
            *'"bridge"'*) cat "$STUB_DIR/relay-address" 2> /dev/null || true ;;
            *) cat "$STUB_DIR/traefik-address" 2> /dev/null || true ;;
        esac
        ;;
    version) echo "linux amd64" ;;
    network | rm | exec | restart) ;;
    *) echo "stub docker: unexpected invocation: $*" >&2; exit 99 ;;
esac
S
cat > "$stubs/curl" <<'S'
#!/usr/bin/env bash
echo "$*" >> "$STUB_DIR/curl.log"
previous=""
for argument in "$@"; do
    if [ "$previous" = --dump-header ]; then
        cat "$STUB_DIR/planted-upload-headers" > "$argument"
    fi
    previous="$argument"
done
case "$*" in
    *--write-out*)
        case "${*: -1}" in
            *manifests/*) cat "$STUB_DIR/manifest-status" ;;
            *blobs/*) cat "$STUB_DIR/blob-status" ;;
        esac
        ;;
esac
S
cat > "$stubs/timeout" <<'S'
#!/usr/bin/env bash
if [ -e "$STUB_DIR/handshake-fails" ]; then
    exit 1
fi
shift
exec "$@"
S
cat > "$stubs/openssl" <<'S'
#!/usr/bin/env bash
case "$1" in
    s_client) exit 0 ;;
    x509) cat "$STUB_DIR/served-issuer" ;;
    *) echo "stub openssl: unexpected invocation: $*" >&2; exit 99 ;;
esac
S
chmod +x "$stubs/docker" "$stubs/ss" "$stubs/docker-fn" "$stubs/curl" "$stubs/timeout" "$stubs/openssl"

failures=0
fail() { echo "FAIL: $1" >&2; failures=$((failures + 1)); }

# The names the script derives from the server's sources, read the way it reads them.
# The registry's port is read from the script too: the case for it holds whatever
# port the registry is published on, and that port must be refused. So are the
# pinned busybox the probe runs and the host path a Traefik the server creates
# binds its certificate store from.
names="$(ARMS_DIR="$arms_dir" bash -c 'set -euo pipefail; here="$ARMS_DIR"; . "$1"; printf "%s\n%s\n%s\n%s\n%s\n%s\n" "$fixture_network" "$fixture_traefik" "$registry_port" "$busybox_image" "$acme_host_path" "$auth_registry_port"' _ "$arms")"
network="$(printf '%s\n' "$names" | sed -n 1p)"
traefik="$(printf '%s\n' "$names" | sed -n 2p)"
registry_port="$(printf '%s\n' "$names" | sed -n 3p)"
busybox="$(printf '%s\n' "$names" | sed -n 4p)"
acme_path="$(printf '%s\n' "$names" | sed -n 5p)"
auth_registry_port="$(printf '%s\n' "$names" | sed -n 6p)"
[ -n "$network" ] && [ -n "$traefik" ] && [ -n "$registry_port" ] && [ -n "$busybox" ] && [ -n "$acme_path" ] && [ -n "$auth_registry_port" ] \
    || { echo "FAIL: could not derive the network and traefik names, the registry port, the busybox pin and the acme.json path" >&2; exit 1; }
# A Traefik the server creates publishes 80 and 443, so a registry on either would
# collide with it, and the registry's case below would test nothing of its own.
case "$registry_port" in
    80 | 443) echo "FAIL: the registry is published on $registry_port, which a Traefik the server creates takes" >&2; exit 1 ;;
esac
case "$auth_registry_port" in
    80 | 443 | "$registry_port") echo "FAIL: the credentialed registry is published on $auth_registry_port, which is taken" >&2; exit 1 ;;
esac
# The cases below plant the host's /etc relative to it, as the probe reads it.
case "$acme_path" in
    /etc/*/*/*) ;;
    *) echo "FAIL: the acme.json path $acme_path is not under /etc at the depth these cases plant" >&2; exit 1 ;;
esac
acme_rel="${acme_path#/etc/}"
acme_dir="${acme_rel%/*}"
acme_top="${acme_dir%/*}"

# Every docker call a preconditions case made either changes nothing (a listing,
# an image inspect, the probe that binds /etc read-only and removes itself), or
# is a pull of the busybox pin that the run recorded, so teardown removes it.
# Anything else is an effect that outlives the run.
calls_outlive_the_run() {
    local call
    while IFS= read -r call; do
        case "$call" in
            "network ls "* | "ps --all "* | "ps --filter "* | "image inspect "*) ;;
            "run --rm --pull never --label "*" --mount type=bind,src=/etc,dst=/host-etc,readonly $busybox sh -c "*) ;;
            "pull --quiet $busybox")
                if ! grep -qxF -- "$busybox" "$scratch/case/pulled"; then
                    echo "a pull of $busybox the run did not record"
                    return 0
                fi
                ;;
            *)
                echo "$call"
                return 0
                ;;
        esac
    done < "$scratch/case/docker.log"
    return 1
}

# Runs BODY (by default the preconditions) with the case's answers, in a shell
# that sources the script as check-server-image.sh does. On exit it records what
# the run recorded as pulled.
run_body() {
    local body="$1"
    : > "$scratch/case/docker.log"
    PATH="$scratch/case/bin:$tools" STUB_DIR="$scratch/case" ARMS_DIR="$arms_dir" \
        bash -c 'set -euo pipefail; here="$ARMS_DIR"; work="$STUB_DIR"; . "$1"
            trap '"'"': > "$STUB_DIR/pulled"; for r in ${fixture_pulled[@]+"${fixture_pulled[@]}"}; do echo "$r" >> "$STUB_DIR/pulled"; done'"'"' EXIT
            eval "$2"' _ "$arms" "$body" 2>&1
}

# run_case NAME EXPECTED_RC EXPECTED_TEXT: the answers are those the case planted
# in "$scratch/case"; `ss` is on PATH unless the case removed it.
run_case() {
    local name="$1" want_rc="$2" want_text="$3" rc=0 out outliving
    out="$(run_body deploy_fixture_preconditions)" || rc=$?
    if [ "$rc" != "$want_rc" ]; then
        fail "$name: exit $rc, wanted $want_rc: $out"
    elif ! printf '%s\n' "$out" | grep -qF -- "$want_text"; then
        fail "$name: output lacks '$want_text': $out"
    elif outliving="$(calls_outlive_the_run)"; then
        fail "$name: a docker call outlives the run: $outliving"
    else
        echo "ok: $name"
    fi
}

# run_teardown_case NAME BODY EXPECTED_RC EXPECTED_TEXT REMOVED: BODY runs the
# fixture's own functions. Afterwards the modelled host and the engine's images
# must be as the case planted them, and the removal, if any ran, must have named
# exactly REMOVED (the file, then the directories, as given to it).
run_teardown_case() {
    local name="$1" body="$2" want_rc="$3" want_text="$4" want_removed="$5" rc=0 out removed
    cp "$scratch/case/host-etc" "$scratch/case/host-etc.before"
    cp "$scratch/case/images" "$scratch/case/images.before"
    out="$(run_body "$body")" || rc=$?
    removed="$(sed -n 's/^run .*--mount type=bind,src=\/etc,dst=\/host-etc [^ ]* sh -c .* _ //p' "$scratch/case/docker.log")"
    if [ "$rc" != "$want_rc" ]; then
        fail "$name: exit $rc, wanted $want_rc: $out"
    elif ! printf '%s\n' "$out" | grep -qF -- "$want_text"; then
        fail "$name: output lacks '$want_text': $out"
    elif [ "$removed" != "$want_removed" ]; then
        fail "$name: the removal named '$removed', wanted '$want_removed'"
    elif ! cmp -s "$scratch/case/host-etc" "$scratch/case/host-etc.before"; then
        fail "$name: the host's /etc is not as it was: before $(cat "$scratch/case/host-etc.before"), after $(cat "$scratch/case/host-etc")"
    elif ! cmp -s "$scratch/case/images" "$scratch/case/images.before"; then
        fail "$name: the engine's images are not as they were: before $(cat "$scratch/case/images.before"), after $(cat "$scratch/case/images")"
    else
        echo "ok: $name"
    fi
}

# run_refusal_body NAME BODY EXPECTED_RC EXPECTED_TEXT: BODY runs the fixture's
# own functions, and only its exit and its words are asserted. For the refusals
# that leave the host other than as planted, which is what they report.
run_refusal_body() {
    local name="$1" body="$2" want_rc="$3" want_text="$4" rc=0 out
    out="$(run_body "$body")" || rc=$?
    if [ "$rc" != "$want_rc" ]; then
        fail "$name: exit $rc, wanted $want_rc: $out"
    elif ! printf '%s\n' "$out" | grep -qF -- "$want_text"; then
        fail "$name: output lacks '$want_text': $out"
    else
        echo "ok: $name"
    fi
}

# new_case: a clean engine, with `ss` present, nothing held, no busybox and
# nothing under the host's /etc that the fixture reads.
new_case() {
    local tool
    rm -rf "$scratch/case"
    mkdir -p "$scratch/case/bin"
    cp "$stubs/docker" "$stubs/ss" "$scratch/case/bin/"
    # The tools the preconditions require be present; none is run by them.
    for tool in curl openssl timeout sha256sum base64; do
        printf '#!/usr/bin/env bash\nexit 0\n' > "$scratch/case/bin/$tool"
        chmod +x "$scratch/case/bin/$tool"
    done
    printf 'aaa111\tbridge\nbbb222\thost\n' > "$scratch/case/networks"
    printf 'c1\tweb\tnginx:1\n' > "$scratch/case/containers"
    : > "$scratch/case/images"
    printf 'hostname|regular file|644|root:root|5\n' > "$scratch/case/host-etc"
}

new_case
run_case "a clean engine passes" 0 "ok: no $network"
grep -qxF -- "pull --quiet $busybox" "$scratch/case/docker.log" \
    || fail "a clean engine passes: busybox was absent, and was not pulled for the probe"

# Busybox on the engine already is someone else's: not pulled, and not recorded.
new_case
echo "$busybox" > "$scratch/case/images"
run_case "a clean engine holding busybox passes" 0 "ok: $busybox was on the engine already, and is left there"
if [ -s "$scratch/case/pulled" ]; then
    fail "a clean engine holding busybox passes: the run recorded a pull: $(cat "$scratch/case/pulled")"
fi

new_case
printf 'aaa111\tbridge\nnet999\t%s\n' "$network" > "$scratch/case/networks"
run_case "the network held is refused" 1 "the network $network exists (id net999)"

new_case
printf 'c1\tweb\tnginx:1\nc2\tedge\ttraefik@sha256:abc\n' > "$scratch/case/containers"
run_case "a container whose image holds traefik is refused" 1 "a container whose image contains 'traefik': c2 edge (image traefik@sha256:abc)"

# A container merely named after Traefik is not one a deploy adopts.
new_case
printf 'c3\ttraefik-notes\tnginx:1\n' > "$scratch/case/containers"
run_case "a container only named traefik passes" 0 "ok: no $network"

# An acme.json already on the host is a certificate store a Traefik there owns:
# a deploy here would bind it, and teardown would remove it.
new_case
printf '%s|directory|755|root:root|0\n%s|directory|700|root:root|0\n%s|regular file|600|root:root|3409\n' \
    "$acme_top" "$acme_dir" "$acme_rel" >> "$scratch/case/host-etc"
run_case "an existing acme.json is refused" 1 "$acme_path exists on the engine's host (regular file, mode 600, 3409 bytes, owned by root:root)"

# What the engine leaves when a Traefik binds the file before it exists.
new_case
printf '%s|directory|755|root:root|0\n%s|directory|755|root:root|0\n%s|directory|755|root:root|0\n' \
    "$acme_top" "$acme_dir" "$acme_rel" >> "$scratch/case/host-etc"
run_case "an acme.json that is a directory is refused" 1 "$acme_path exists on the engine's host (directory, mode 755"

# A probe that cannot read the host, or that answers other than one line for each
# path it was asked about, cannot say that nothing is there.
new_case
touch "$scratch/case/probe-fails"
run_case "a probe that cannot read the host is refused" 1 "error: could not read $acme_rel $acme_dir $acme_top under the engine host's /etc"

new_case
printf '%s|absent\n' "$acme_rel" > "$scratch/case/probe-answer"
run_case "a probe answering too few lines is refused" 1 "answered 1 lines, not 3"

new_case
printf '%s|absent\n%s|absent\n%s|absent\n' "$acme_rel" "$acme_rel" "$acme_top" > "$scratch/case/probe-answer"
run_case "a probe answering a path twice is refused" 1 "error: reading $acme_rel under the engine host's /etc answered no single line for it"

# Each port the fixture needs, held through each witness on its own: 80 and 443,
# which a Traefik the server creates publishes, and the port the registry is
# published on.
for port in 80 443 "$registry_port" "$auth_registry_port"; do
    new_case
    printf 'LISTEN 0 4096 0.0.0.0:%s 0.0.0.0:*\n' "$port" > "$scratch/case/listener-$port"
    run_case "a listener on host port $port is refused" 1 "host port $port is in use: no container publishes it; ss: LISTEN 0 4096 0.0.0.0:$port"

    new_case
    printf 'c4 edge\n' > "$scratch/case/publisher-$port"
    run_case "a container publishing host port $port is refused" 1 "host port $port is in use: c4 edge; ss: no listener"
done

new_case
rm "$scratch/case/bin/ss"
run_case "an absent ss is refused" 1 "which is not on PATH"

# From creation to teardown, the run removes the file and only the directories
# that were absent before it, so the host ends as it began whatever stood there.
up_and_down='deploy_fixture_preconditions; create_acme_json; deploy_fixture_down'
back="ok: $acme_path is gone, and the host's /etc is as it was before the run"

new_case
run_teardown_case "teardown removes acme.json and both directories it made" \
    "$up_and_down" 0 "$back" "$acme_rel $acme_dir $acme_top"

new_case
printf '%s|directory|755|root:root|0\n%s/traefik.yml|regular file|644|root:root|120\n' \
    "$acme_top" "$acme_top" >> "$scratch/case/host-etc"
run_teardown_case "teardown leaves a $acme_top that was there before" \
    "$up_and_down" 0 "$back" "$acme_rel $acme_dir"

new_case
printf '%s|directory|755|root:root|0\n%s|directory|700|root:root|0\n' \
    "$acme_top" "$acme_dir" >> "$scratch/case/host-etc"
run_teardown_case "teardown leaves a $acme_dir that was there before" \
    "$up_and_down" 0 "$back" "$acme_rel"

# A create that leaves the store more open than Traefik accepts is refused, not
# left for the deploy that binds it to find.
new_case
echo 644 > "$scratch/case/create-mode"
run_refusal_body "a create that leaves acme.json at mode 644 is refused" \
    'deploy_fixture_preconditions; create_acme_json' 1 \
    "error: expected $acme_path an empty regular file of mode 600, and it is regular empty file, mode 644"

# Teardown reports, and does not empty, a directory it made that something else
# wrote into, and reports a directory that stood before and has changed.
new_case
run_refusal_body "teardown reports a directory it made that is not empty" \
    "deploy_fixture_preconditions; create_acme_json; echo '$acme_dir/other|regular file|644|root:root|1' >> \"\$STUB_DIR/host-etc\"; deploy_fixture_down" 1 \
    "error: could not remove $acme_path and the directories this run made for it"

new_case
printf '%s|directory|755|root:root|0\n' "$acme_top" >> "$scratch/case/host-etc"
run_refusal_body "teardown reports a directory that stood before and changed" \
    "deploy_fixture_preconditions; create_acme_json; sed -i 's/^$acme_top|directory|755|/$acme_top|directory|700|/' \"\$STUB_DIR/host-etc\"; deploy_fixture_down" 1 \
    "error: /etc/$acme_top was directory, mode 755, 0 bytes, owned by root:root before the run, and is directory, mode 700"

# A refused run created nothing, so its teardown removes nothing but the busybox
# it pulled, as check-server-image.sh's exit trap runs it.
new_case
printf '%s|directory|755|root:root|0\n%s|directory|700|root:root|0\n%s|regular file|600|root:root|3409\n' \
    "$acme_top" "$acme_dir" "$acme_rel" >> "$scratch/case/host-etc"
run_teardown_case "a refused run removes nothing on the host" \
    "trap 'deploy_fixture_down || exit 3' EXIT; deploy_fixture_preconditions" 1 "exists on the engine's host" ""

# Each tool the arms call outside docker is refused before anything is pulled, made
# or written, and the refusal names it.
for tool in curl openssl timeout sha256sum base64; do
    new_case
    rm "$scratch/case/bin/$tool"
    run_case "an absent $tool is refused" 1 "error: the deploy arms need $tool, which is not on PATH"
    if [ -s "$scratch/case/docker.log" ]; then
        fail "an absent $tool is refused: docker was called before the refusal: $(cat "$scratch/case/docker.log")"
    fi
done

# `acme_path_of` guards the path teardown removes through a read-write /etc bind,
# so each way a source can fail it is planted, and the one way it passes.
plant_traefik_source() {
    mkdir -p "$scratch/case/src"
    printf '%s' "$1" > "$scratch/case/src/traefik.ml"
}
acme_line() { printf '    "%s:/acme/acme.json";\n' "$1"; }
run_acme_case() {
    local name="$1" source="$2" want_rc="$3" want_text="$4"
    new_case
    plant_traefik_source "$source"
    # shellcheck disable=SC2016
    run_refusal_body "$name" 'acme_path_of "$STUB_DIR/src/traefik.ml"' "$want_rc" "$want_text"
}
run_acme_case "acme_path_of refuses a source with no acme.json bind" \
    'let binds = [];' 1 "error: could not derive the acme.json bind's host path from"
run_acme_case "acme_path_of refuses a source with two acme.json binds" \
    "$(acme_line /etc/traefik/acme/acme.json)$(acme_line /etc/other/acme/acme.json)" 1 \
    "error: could not derive the acme.json bind's host path from"
run_acme_case "acme_path_of refuses a path one directory below /etc" \
    "$(acme_line /etc/a/b)" 1 "is not a file two directories below /etc"
run_acme_case "acme_path_of refuses a path three directories below /etc" \
    "$(acme_line /etc/a/b/c/d)" 1 "is not a file two directories below /etc"
run_acme_case "acme_path_of answers a path two directories below /etc" \
    "$(acme_line /etc/traefik/acme/acme.json)" 0 "/etc/traefik/acme/acme.json"

# The registry fixture's own refusals, driven by a stub `docker` and `curl`. Every
# answer is well-formed but for the one the case plants.
new_fn_case() {
    new_case
    cp "$stubs/docker-fn" "$scratch/case/bin/docker"
    cp "$stubs/curl" "$stubs/timeout" "$stubs/openssl" "$scratch/case/bin/"
    printf '#!/usr/bin/env bash\nexec %s "$@"\n' "$(command -v sha256sum)" > "$scratch/case/bin/sha256sum"
    chmod +x "$scratch/case/bin/sha256sum"
    printf 'HTTP/1.1 202 Accepted\r\nLocation: /v2/app/blobs/uploads/u1\r\n\r\n' > "$scratch/case/planted-upload-headers"
    printf 200 > "$scratch/case/manifest-status"
    printf 404 > "$scratch/case/blob-status"
    : > "$scratch/case/blob"
}
# shellcheck disable=SC2016
fn_body_prefix='registry_certs="$STUB_DIR/certs"; attempts=1; '

new_fn_case
printf 'HTTP/1.1 202 Accepted\r\n\r\n' > "$scratch/case/planted-upload-headers"
run_refusal_body "upload_blob refuses an upload that names no location" \
    "${fn_body_prefix}upload_blob app \"\$STUB_DIR/blob\" sha256:abc" 1 \
    "the registry opened an upload to app and named no location for it"

new_fn_case
run_refusal_body "upload_blob follows the location the registry named" \
    "${fn_body_prefix}upload_blob app \"\$STUB_DIR/blob\" sha256:abc; grep -q 'blobs/uploads/u1?digest=sha256:abc' \"\$STUB_DIR/curl.log\" && echo located" 0 "located"

new_fn_case
run_refusal_body "push_missing_layer passes where the manifest is served and the layer is not" \
    "${fn_body_prefix}push_missing_layer" 0 "the registry serves"

new_fn_case
printf 404 > "$scratch/case/manifest-status"
run_refusal_body "push_missing_layer refuses a manifest the registry does not serve" \
    "${fn_body_prefix}push_missing_layer" 1 "manifest: HTTP 404 (expected 200)"

new_fn_case
printf 200 > "$scratch/case/blob-status"
run_refusal_body "push_missing_layer refuses a layer the registry still serves" \
    "${fn_body_prefix}push_missing_layer" 1 "HTTP 200 (expected 404)"

new_fn_case
printf 1 > "$scratch/case/probe-rc"
echo "pebble says nothing" > "$scratch/case/logs-pebble"
run_refusal_body "start_pebble refuses a Pebble whose directory never answers" \
    "${fn_body_prefix}start_pebble" 1 "did not serve its ACME directory"

# expect_issued_by_pebble. The id is a full container id, which is all
# `require_full_id` asks of it.
traefik_id="$(printf 'a%.0s' {1..64})"
issuer_line='2026/11/21 00:00:00 Generated new intermediate issuer CN=Pebble Intermediate CA 1a2b3c with serial 1'
issued_body="${fn_body_prefix}issuer_attempts=1; expect_issued_by_pebble $traefik_id host.invalid"
relay_removed() { grep -qxF -- "rm --force detachid" "$scratch/case/docker.log"; }

new_fn_case
run_refusal_body "expect_issued_by_pebble refuses an id that is not hexadecimal" \
    "${fn_body_prefix}expect_issued_by_pebble not-an-id host.invalid" 1 "error: expect_issued_by_pebble: 'not-an-id' is not a container id"
if [ -s "$scratch/case/docker.log" ]; then
    fail "expect_issued_by_pebble refuses an id that is not hexadecimal: the engine was asked: $(cat "$scratch/case/docker.log")"
fi
run_refusal_body "expect_issued_by_pebble refuses an id that is not a full container id" \
    "${fn_body_prefix}expect_issued_by_pebble abc123 host.invalid" 1 "error: expect_issued_by_pebble: 'abc123' is not a full container id"
# Another refusal further on would give the same exit and a log of the same words,
# so the refusal is held to have come first: nothing was asked of the engine.
if [ -s "$scratch/case/docker.log" ]; then
    fail "expect_issued_by_pebble refuses an id that is not a full container id: the engine was asked: $(cat "$scratch/case/docker.log")"
fi

new_fn_case
: > "$scratch/case/logs-pebble"
run_refusal_body "expect_issued_by_pebble refuses a Pebble log naming no intermediate issuer" \
    "$issued_body" 1 "expected one intermediate issuer named in"

new_fn_case
printf '%s\n%s\n' "$issuer_line" "$issuer_line" > "$scratch/case/logs-pebble"
run_refusal_body "expect_issued_by_pebble refuses a Pebble log naming two intermediate issuers" \
    "$issued_body" 1 "expected one intermediate issuer named in"

new_fn_case
echo "$issuer_line" > "$scratch/case/logs-pebble"
run_refusal_body "expect_issued_by_pebble refuses a Traefik with no address on the network" \
    "$issued_body" 1 "$traefik_id has no address on"

new_fn_case
echo "$issuer_line" > "$scratch/case/logs-pebble"
echo 172.18.0.5 > "$scratch/case/traefik-address"
run_refusal_body "expect_issued_by_pebble refuses a relay with no address on the bridge" \
    "$issued_body" 1 "the relay detachid has no address on the engine's default bridge"
relay_removed || fail "expect_issued_by_pebble refuses a relay with no address on the bridge: the relay was not removed"

new_fn_case
echo "$issuer_line" > "$scratch/case/logs-pebble"
echo 172.18.0.5 > "$scratch/case/traefik-address"
echo 172.17.0.9 > "$scratch/case/relay-address"
touch "$scratch/case/handshake-fails"
run_refusal_body "expect_issued_by_pebble refuses a certificate it cannot read" \
    "$issued_body" 1 "expected the certificate $traefik_id serves for host.invalid to be issued by Pebble Intermediate CA 1a2b3c"
relay_removed || fail "expect_issued_by_pebble refuses a certificate it cannot read: the relay was not removed"

new_fn_case
echo "$issuer_line" > "$scratch/case/logs-pebble"
echo 172.18.0.5 > "$scratch/case/traefik-address"
echo 172.17.0.9 > "$scratch/case/relay-address"
echo "issuer=CN=Some Other CA" > "$scratch/case/served-issuer"
run_refusal_body "expect_issued_by_pebble refuses a certificate another CA issued" \
    "$issued_body" 1 "last issuer: 'issuer=CN=Some Other CA'"
relay_removed || fail "expect_issued_by_pebble refuses a certificate another CA issued: the relay was not removed"

new_fn_case
echo "$issuer_line" > "$scratch/case/logs-pebble"
echo 172.18.0.5 > "$scratch/case/traefik-address"
echo 172.17.0.9 > "$scratch/case/relay-address"
echo "issuer=CN=Pebble Intermediate CA 1a2b3c" > "$scratch/case/served-issuer"
run_refusal_body "expect_issued_by_pebble passes a certificate this run's Pebble issued" \
    "$issued_body" 0 "was issued by Pebble Intermediate CA 1a2b3c, this run's Pebble"
relay_removed || fail "expect_issued_by_pebble passes a certificate this run's Pebble issued: the relay was not removed"

[ "$failures" = 0 ] || { echo "$failures case(s) failed" >&2; exit 1; }
