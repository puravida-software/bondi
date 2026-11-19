#!/usr/bin/env bash
# Drives deploy_fixture_preconditions (scripts/deploy-arms.sh) with a fake `docker`
# and `ss` first on PATH, one case per refusal branch plus the passing case. The
# fake answers are well-formed except for the one holder a case plants. The fake
# docker records every invocation, so each case also asserts that nothing was
# removed or changed: the function must only list.
set -euo pipefail

arms="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
arms_dir="$(dirname "$arms")"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
stubs="$scratch/stubs"
tools="$scratch/tools"
mkdir -p "$stubs" "$tools"

# A PATH that holds only the stubs and the few tools the function uses, so that
# the real `ss` and `docker` cannot answer and the absent-`ss` case can be real.
for tool in awk sed wc cat env bash; do
    ln -s "$(command -v "$tool")" "$tools/$tool"
done

cat > "$stubs/docker" <<'S'
#!/usr/bin/env bash
echo "$*" >> "$STUB_DIR/docker.log"
case "$1 $2" in
    "network ls") cat "$STUB_DIR/networks" ;;
    "ps --all") cat "$STUB_DIR/containers" ;;
    "ps --filter") cat "$STUB_DIR/publisher" ;;
    *) echo "stub docker: unexpected invocation: $*" >&2; exit 99 ;;
esac
S
cat > "$stubs/ss" <<'S'
#!/usr/bin/env bash
cat "$STUB_DIR/listener"
S
chmod +x "$stubs/docker" "$stubs/ss"

failures=0
fail() { echo "FAIL: $1" >&2; failures=$((failures + 1)); }

# The names the script derives from the server's sources, read the way it reads them.
names="$(ARMS_DIR="$arms_dir" bash -c 'set -euo pipefail; here="$ARMS_DIR"; . "$1"; printf "%s\n%s\n" "$fixture_network" "$fixture_traefik"' _ "$arms")"
network="$(printf '%s\n' "$names" | sed -n 1p)"
traefik="$(printf '%s\n' "$names" | sed -n 2p)"
[ -n "$network" ] && [ -n "$traefik" ] || { echo "FAIL: could not derive the network and traefik names" >&2; exit 1; }

# run_case NAME EXPECTED_RC EXPECTED_TEXT: the answers are those the case planted
# in "$scratch/case"; `ss` is on PATH unless the case removed it.
run_case() {
    local name="$1" want_rc="$2" want_text="$3" rc=0 out
    : > "$scratch/case/docker.log"
    out="$(PATH="$scratch/case/bin:$tools" STUB_DIR="$scratch/case" ARMS_DIR="$arms_dir" \
        bash -c 'set -euo pipefail; here="$ARMS_DIR"; . "$1"; deploy_fixture_preconditions' _ "$arms" 2>&1)" || rc=$?
    if [ "$rc" != "$want_rc" ]; then
        fail "$name: exit $rc, wanted $want_rc: $out"
    elif ! printf '%s\n' "$out" | grep -qF -- "$want_text"; then
        fail "$name: output lacks '$want_text': $out"
    elif grep -Eq '^(rm|stop|kill|run|network (rm|create)|container|rmi|image rm|build|pull|push)' "$scratch/case/docker.log"; then
        fail "$name: the function changed something: $(cat "$scratch/case/docker.log")"
    else
        echo "ok: $name"
    fi
}

# new_case: a clean engine, with `ss` present and nothing held.
new_case() {
    rm -rf "$scratch/case"
    mkdir -p "$scratch/case/bin"
    cp "$stubs/docker" "$stubs/ss" "$scratch/case/bin/"
    printf 'aaa111\tbridge\nbbb222\thost\n' > "$scratch/case/networks"
    printf 'c1\tweb\tnginx:1\n' > "$scratch/case/containers"
    : > "$scratch/case/publisher"
    : > "$scratch/case/listener"
}

new_case
run_case "a clean engine passes" 0 "ok: no $network"

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

new_case
printf 'LISTEN 0 4096 0.0.0.0:443 0.0.0.0:*\n' > "$scratch/case/listener"
run_case "a listener on the host port is refused" 1 "host port 443 is in use: no container publishes it; ss: LISTEN"

new_case
printf 'c4 registry\n' > "$scratch/case/publisher"
run_case "a container publishing the host port is refused" 1 "host port 443 is in use: c4 registry; ss: no listener"

new_case
rm "$scratch/case/bin/ss"
run_case "an absent ss is refused" 1 "which is not on PATH"

[ "$failures" = 0 ] || { echo "$failures case(s) failed" >&2; exit 1; }
