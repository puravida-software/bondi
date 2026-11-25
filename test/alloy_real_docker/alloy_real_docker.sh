#!/usr/bin/env bash
#
# The generated Alloy config keeps and drops the containers each collect mode
# means it to, and names every kept one by its workload, judged by Alloy itself.
#
# The relabel rules name the labels they read. Which labels a target actually
# carries is decided by Alloy's Docker discovery, so a rule can name a label
# nothing produces and still read as correct to anything that inspects the
# config's text. The only oracle is a running Alloy: this file starts labelled
# containers, runs the image the server deploys against the config this tree
# generates, and reads what the discovery and relabel components computed from
# Alloy's own HTTP API.
#
# What is real here: the Alloy image, its discovery against a real Docker
# socket, the generated config, the relabel output, and a Loki the generated
# config writes to. That Loki is a pinned image run locally with auth disabled;
# Grafana Cloud is not reached, and the credentials the config reads are empty,
# which a Loki without auth ignores.
#
# Every Alloy but the loopback one below runs inside its Loki's network
# namespace and pushes to it over loopback, and both are reached from here
# through ports Loki publishes. A
# Docker network of the run's own would need a subnet of its own, and Docker
# hands out subnets regardless of the host's routes: on a host whose VPN routes
# part of Docker's address pool, such a network's published ports were observed
# to refuse or hang whenever its subnet landed in the routed part. A shared
# namespace on the default bridge needs no subnet and no name lookup.
#
# Every keep or drop verdict is read twice: off the relabel output, which is
# what Alloy decided to tail, and off Loki, which is what arrived. Each fixture
# prints one marker line naming itself, so a kept fixture's marker is in Loki
# and a dropped fixture's is not. Each collect mode writes to a Loki of its own:
# the fixtures print their markers once, before either mode runs, so a shared
# Loki would hold the first mode's deliveries when the second is judged, and a
# fixture the second mode wrongly dropped would still read as delivered.
#
# Written against, and executed under, Docker Engine 29.8.1 with the Alloy image
# named by the server's defaults (v1.8.0 when written), jq 1.8.2 and GNU bash
# 5.3. The hosted runner image lists jq 1.7.1, which this has not yet run under.
# The delivery arms were written against, and executed under, Docker Engine
# 29.9.3 with the Loki image emit_config names (3.7.9 when written).
#
# Every assertion block has an arm: before anything is read off the relabel
# component, the discovery component's own target list must hold every fixture
# this run started, and the relabel component must have received them. When the
# arm fails, nothing below it is a verdict on the rules -- Alloy did not start,
# the API moved, or discovery did not run -- so the mode's rule assertions are
# not read at all.
#
# Every fixture's name carries this run's prefix, and every assertion reads only
# those names: discovery selects on `bondi.managed=true`, so on a machine that
# runs real Bondi containers it sees those too.
#
# Docker absent is a failure when CI is set and a skip only on a developer
# machine. A skip-if-absent case is indistinguishable from no case.
#
# The journal path. A cron container can exit before Docker discovery ever
# lists it, so cron containers log through journald and Alloy reads the host
# journal, and the Docker path drops them. The journal assertions run one more
# Alloy, against a Loki of its own. Every Alloy here, the collect-mode ones
# included, runs with the journal mounts, state bind and storage path
# emit_config prints from the module that owns them for setup's run line. Only
# each Alloy's host state directory is this run's own. The generated config
# reads the journal, and Alloy v1.8.0 refuses to load it when the journal path
# is not there [observed -- 2026-11-12], so without a readable persistent
# journal no Alloy here can start: the whole script skips on a developer
# machine and fails where CI is set. Written against, and executed under,
# Docker Engine 29.9.3 and systemd 261's journalctl and logger.
#
# A line Alloy sends twice cannot be counted in Loki. Loki 3.7.9 returns one
# copy of entries that share a stream, a timestamp and a line, and the journal
# source stamps each entry with the journal's own timestamp, so a re-sent line
# is identical to the first. A restarted Alloy that kept its read position
# also re-sends the last entry it had shipped. [observed -- 2026-11-12, probes
# against Loki 3.7.9 and Alloy v1.8.0.] The restart assertion therefore also
# reads, from the restarted Alloy's own metrics, how many journal lines it
# read. The bound is the cron entries the host journal gained since the old
# Alloy stopped, plus that one re-sent entry. An Alloy that lost its position
# re-reads every earlier entry of this run and exceeds it. The metric is read
# by its name in Alloy v1.8.0, `loki_source_journal_target_lines_total`.
#
# Alloy's HTTP server on the host's loopback. One more Alloy runs the way setup
# runs it: with the journal arguments and the network and listen address
# emit_config prints from the module that owns them for setup's run line. Only
# its port is this run's own, drawn from below the kernel's ephemeral range and
# checked free, since several Alloys share this host. It shares the host's
# network, so it pushes to a Loki of its own at the port that Loki publishes,
# and everything about it is read from this host with curl, never with
# `docker exec`. Its arms: a container that logs and is removed before the
# discovery refresh Alloy defaults to (one minute) has its line delivered; the
# dropped-entries and sent-entries counters are read from the host; and the
# port listens on the host's 127.0.0.1 only, so a container on Docker's default
# bridge is refused at the bridge's gateway on it. The listener table is read
# with ss. Written against, and executed under, Docker Engine 29.10.0, Alloy
# v1.8.0, Loki 3.7.9 and iproute2 7.2.0's ss.

set -u

emit_config=${1:?usage: alloy_real_docker.sh PATH_TO_EMIT_CONFIG}

# The build system hands this over relative to the directory the action runs in.
case $emit_config in
  /*) ;;
  *) emit_config="$PWD/$emit_config" ;;
esac

# Absence is decided by where this runs: a skip on a developer machine is a
# convenience, a skip on a runner would be this behaviour's only coverage
# disappearing without anything saying so.
unavailable() {
  if [ -n "${CI:-}" ]; then
    printf 'FAIL: %s, and CI is set. This is the only test that runs the generated Alloy config against real containers, so it is not skippable here.\n' \
      "$1" >&2
    exit 1
  fi
  printf 'skipped: %s. This case is not skippable where CI is set, and fails there instead. Dune caches a skip: re-run with: dune build @test/alloy_real_docker/runtest --force, once it is available.\n' "$1"
  exit 0
}

for program in docker jq curl ss; do
  command -v "$program" > /dev/null 2>&1 \
    || unavailable "$program is not on this machine's PATH"
done
docker info > /dev/null 2>&1 \
  || unavailable "the Docker daemon does not answer 'docker info'"
# The Alloy container mounts this path and the config targets it, so a daemon
# reached some other way (DOCKER_HOST, a context) cannot be tested here.
[ -S /var/run/docker.sock ] \
  || unavailable "/var/run/docker.sock is not a socket on this machine"

if ! fixture_image=$("$emit_config" fixture-image); then
  printf 'FAIL: %s could not name the fixture image.\n' "$emit_config" >&2
  exit 1
fi

if ! alloy_image=$("$emit_config" image); then
  printf 'FAIL: %s could not name the Alloy image.\n' "$emit_config" >&2
  exit 1
fi

if ! loki_image=$("$emit_config" loki-image); then
  printf 'FAIL: %s could not name the Loki image.\n' "$emit_config" >&2
  exit 1
fi

if ! journal_dir=$("$emit_config" journal-path); then
  printf 'FAIL: %s could not name the journal path.\n' "$emit_config" >&2
  exit 1
fi

# Whether any Alloy here can run. The generated config reads the host's
# persistent journal, which journald keeps under a directory named by the
# machine id; with only volatile storage the parent directory can exist and
# stay empty, so the machine's own directory is what is checked.
machine_id=$(cat /etc/machine-id 2> /dev/null) || machine_id=''
command -v journalctl > /dev/null 2>&1 \
  || unavailable "journalctl is not on this machine's PATH"
command -v logger > /dev/null 2>&1 \
  || unavailable "logger is not on this machine's PATH"
[ -n "$machine_id" ] && [ -d "$journal_dir/$machine_id" ] \
  || unavailable "$journal_dir/<machine-id> does not exist, so this machine keeps no persistent journal"
journalctl -D "$journal_dir" -q -n 1 > /dev/null 2>&1 \
  || unavailable "journalctl cannot read $journal_dir"

prefix="bondi-alloy-test-$$-$RANDOM"
work=$(mktemp -d) || {
  printf 'FAIL: could not create a working directory.\n' >&2
  exit 1
}

cleanup() {
  local ids
  ids=$(docker ps -aq --filter "name=^/$prefix-")
  if [ -n "$ids" ]; then
    # Word splitting is the point: one id per word.
    # shellcheck disable=SC2086
    docker rm -f $ids > /dev/null 2>&1
  fi
  # Alloy writes its state as root, which this user may not be able to delete.
  # Every Alloy's state directory begins `alloy-state`.
  if compgen -G "$work/alloy-state*" > /dev/null; then
    # The single quotes are the point: the glob is expanded in the container.
    # shellcheck disable=SC2016
    docker run --rm -v "$work:/work" "$fixture_image" \
      sh -c 'rm -rf /work/alloy-state*' > /dev/null 2>&1
  fi
  rm -rf "$work"
  return 0
}
# A signal handler that returns lets the script carry on, so an interrupt exits,
# and the exit is what removes the containers.
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

failures=0

report() {
  local description=$1 expected=$2 actual=$3
  if [ "$expected" = "$actual" ]; then
    printf 'ok: %s\n' "$description"
  else
    printf 'FAIL: %s\n  expected: %s\n  actual:   %s\n' \
      "$description" "$expected" "$actual" >&2
    failures=$((failures + 1))
  fi
}

harness_failure() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

for image in "$fixture_image" "$alloy_image" "$loki_image"; do
  docker image inspect "$image" > /dev/null 2>&1 && continue
  docker pull -q "$image" > /dev/null \
    || harness_failure "could not pull $image; this is a harness failure, not a verdict on the rules"
done

# The fixtures: a name suffix, then the labels it carries beside
# `bondi.managed=true`. Every container a mode drops has a sibling of the same
# `bondi.type` that differs only in the label under test and is kept, so a
# rule that drops everything cannot pass as a rule that drops the right thing.
# Cron is the exception: the Docker path drops every cron container, under
# both modes, and the journal assertions below are where one is kept.
fixtures=(
  'service-logs-true bondi.type=service bondi.logs=true'
  'service-logs-false bondi.type=service bondi.logs=false'
  'service-logs-absent bondi.type=service'
  'cron-logs-true bondi.type=cron bondi.logs=true'
  "managed bondi.type=managed bondi.logs=true bondi.name=$prefix-managed-name"
  'infrastructure-logs-true bondi.type=infrastructure bondi.logs=true'
  'infrastructure-logs-false bondi.type=infrastructure bondi.logs=false'
  'untyped'
  # An empty `bondi.name` is no name: the container name is the fallback.
  'service-name-empty bondi.type=service bondi.name='
  'excluded bondi.type=service bondi.logs=true'
  # A cron pass runs under its job name plus a timestamp for its whole life,
  # and carries `bondi.name`, as a real pass does. The Docker path drops it
  # whatever it carries; the journal assertions judge its stable name.
  "job-1727790000.123 bondi.type=cron bondi.logs=true bondi.name=$prefix-job"
)
excluded_name="$prefix-excluded"
cron_pass='job-1727790000.123'

# The line a fixture prints, naming it. Every marker begins with this run's
# prefix, which is what the Loki query filters on.
marker_prefix="bondi-marker $prefix-"

suffixes=()
for fixture in "${fixtures[@]}"; do
  read -r suffix labels <<< "$fixture"
  label_args=(--label bondi.managed=true)
  for label in $labels; do
    label_args+=(--label "$label")
  done
  # The marker is printed once, at start. Alloy's Docker source reads a log it
  # holds no position for from its beginning, so the line written before Alloy
  # starts is still delivered.
  # The single quotes are the point: `$1` is expanded by the fixture's shell.
  # shellcheck disable=SC2016
  docker run -d --name "$prefix-$suffix" "${label_args[@]}" \
    "$fixture_image" sh -c 'echo "$1"; exec sleep 600' sh \
    "$marker_prefix$suffix" > /dev/null \
    || harness_failure "could not start fixture $prefix-$suffix"
  suffixes+=("$suffix")
done

# One Loki per collect mode, and one for the journal assertions, all started
# now so each is ready by the time it is used. Each publishes Alloy's API port as well as its own,
# because the Alloy that writes to it runs in its network namespace and can
# publish nothing itself. `-auth.enabled=false` is named rather than left to the
# image's bundled config: with auth on, every push without a tenant header is
# refused, and the config pushes none.
for mode in services_only all journal; do
  docker run -d --name "$prefix-loki-$mode" \
    -p 127.0.0.1::3100 -p 127.0.0.1::12345 "$loki_image" \
    -config.file=/etc/loki/local-config.yaml -auth.enabled=false > /dev/null \
    || harness_failure "could not start $loki_image for $mode"
done

# Every list of names below is in one shape: this run's suffixes, sorted by jq,
# joined by single spaces. One shape on both sides of every comparison, so a
# difference is a difference in names and never in whitespace.
fixture_names=$(printf '%s\n' "${suffixes[@]}" \
  | jq -Rnr '[inputs] | unique | join(" ")') \
  || harness_failure 'could not list the fixtures'

# The names a component holds in one attribute, this run's only, without the
# prefix. `section` is `exports` or `arguments`. An attribute that holds no
# targets at all is an empty list, not an error.
target_names() {
  local response=$1 section=$2 field=$3
  printf '%s' "$response" | jq -r --arg section "$section" \
    --arg field "$field" --arg prefix "$prefix-" \
    '[ .[$section][] | select(.name == $field) | (.value.value // [])[]
       | .value[] | select(.key == "__meta_docker_container_name")
       | .value.value | ltrimstr("/") | select(startswith($prefix))
       | ltrimstr($prefix) ] | unique | join(" ")'
}

# The relabel component's last answer, and this run's kept names read off it,
# both set by run_alloy.
relabel=''
kept=''

# The labels a target carries, as one jq array of `{key, value}` entries per
# target, for every target the relabel component output.
output_targets='.exports[] | select(.name == "output") | (.value.value // [])[] | .value'

# The `container` label of one fixture's target, read off the relabel output.
# Empty when the fixture was dropped or its target carries no such label.
container_of() {
  printf '%s' "$relabel" | jq -r --arg name "$prefix-$1" \
    "[ $output_targets"' | select(any(.[]; .key == "__meta_docker_container_name"
                               and (.value.value | ltrimstr("/")) == $name))
       | .[] | select(.key == "container") | .value.value ] | unique | join(" ")'
}

# This run's kept names whose target carries a non-empty `container` label,
# in the shape `kept` has.
labelled_names() {
  printf '%s' "$relabel" | jq -r --arg prefix "$prefix-" \
    "[ $output_targets"' | select(any(.[]; .key == "container" and .value.value != ""))
       | .[] | select(.key == "__meta_docker_container_name")
       | .value.value | ltrimstr("/") | select(startswith($prefix))
       | ltrimstr($prefix) ] | unique | join(" ")'
}

# Every kept target is named. Against an empty kept set this would agree with
# itself, so an empty set is a failure in its own right.
report_every_kept_target_labelled() {
  report "every_kept_target_has_a_container_label ($1)" \
    "${kept:-at least one kept target}" "$(labelled_names)"
}

# The Loki answer for one mode, and this run's delivered names read off it,
# both set by run_alloy.
loki_answer=''
delivered=''

# Every line one Loki holds that begins with this run's marker prefix. Loki
# gives every stream a `service_name`, by its documentation falling back to
# `unknown_service` when no label it derives one from is present, so the
# selector matches any stream, including one a wrongly shipped fixture would
# arrive on without a `container` label. Each read is capped, so one that
# hangs cannot hold a poll past its bound.
query_loki() {
  curl -sfG --max-time 5 "http://$1/loki/api/v1/query_range" \
    --data-urlencode "query={service_name=~\".+\"} |= \"$marker_prefix\"" \
    --data-urlencode limit=1000
}

# This run's suffixes whose marker is in a Loki answer, in the shape `kept`
# has.
delivered_names() {
  printf '%s' "$1" | jq -r --arg marker "$marker_prefix" \
    '[ .data.result[].values[][1] | rtrimstr("\n") | select(startswith($marker))
       | ltrimstr($marker) ] | unique | join(" ")'
}

# The `container` label of the Loki stream holding one fixture's marker. Empty
# when the marker is absent or its stream carries no such label.
delivered_container_of() {
  printf '%s' "$loki_answer" | jq -r --arg line "$marker_prefix$1" \
    '[ .data.result[] | select(any(.values[]; .[1] | rtrimstr("\n") == $line))
       | .stream.container // "" ] | unique | join(" ")'
}

# Whether every name in the second list is in the first.
holds_all() {
  local have=" $1 " name
  for name in $2; do
    case "$have" in
      *" $name "*) ;;
      *) return 1 ;;
    esac
  done
  return 0
}

# Sets `loki_address` to the published address of one mode's Loki once it
# answers ready. Alloy backs off between refused pushes, so it starts only once
# Loki answers ready, and a slow Loki start cannot read as an undelivered line.
await_loki() {
  local loki=$1 mode=$2 deadline
  loki_address=$(docker port "$loki" 3100/tcp | head -n 1)
  [ -n "$loki_address" ] || harness_failure "Loki for $mode published no port"
  deadline=$((SECONDS + 120))
  until curl -sf --max-time 5 "http://$loki_address/ready" > /dev/null; do
    if [ "$SECONDS" -ge "$deadline" ]; then
      docker logs "$loki" 2>&1 | tail -n 40 >&2
      printf 'Loki at %s last answered /ready with: %s\n' "$loki_address" \
        "$(curl -sS --max-time 5 "http://$loki_address/ready" 2>&1)" >&2
      harness_failure "Loki for $mode was not ready within 120 seconds; this is a harness failure, not a verdict on the rules"
    fi
    sleep 1
  done
}

# Creates the host state directory given and reads, into `shipped_docker_args`
# and `shipped_alloy_args`, the arguments emit_config prints for an Alloy whose
# state lives there. Each output is bound to a variable before it is split, so
# an emit_config that fails stops the run instead of leaving an empty argument
# list. An empty output is an empty list, not a failure: a run line that lost
# its storage path prints no Alloy arguments, and that has to reach Alloy and
# be judged by the restart assertion, not stop the run. Split as it is, an
# empty output would become one empty argument.
load_shipped_args() {
  local state=$1 out
  mkdir "$state" || harness_failure "could not create $state"
  out=$("$emit_config" alloy-run-args docker "$state") \
    || harness_failure 'emit_config could not print the docker run arguments'
  shipped_docker_args=()
  [ -z "$out" ] || mapfile -t shipped_docker_args <<< "$out"
  out=$("$emit_config" alloy-run-args alloy "$state") \
    || harness_failure "emit_config could not print Alloy's run arguments"
  shipped_alloy_args=()
  [ -z "$out" ] || mapfile -t shipped_alloy_args <<< "$out"
}

# Runs Alloy over the config generated for one mode, writing to that mode's
# Loki, waits on the arm, and leaves the relabel component's answer in
# `relabel`, its kept names in `kept`, Loki's answer in `loki_answer` and the
# names delivered to it in `delivered`. Returns non-zero when the arm did not
# hold, in which case none of them is a verdict.
run_alloy() {
  local mode=$1 config="$work/$1.alloy" name="$prefix-alloy-$1"
  local loki="$prefix-loki-$1"
  local address api discovery seen_by_discovery seen_by_relabel deadline
  local loki_address answer
  relabel=''
  kept=''
  loki_answer=''
  delivered=''

  await_loki "$loki" "$mode"

  "$emit_config" config "$mode" "http://127.0.0.1:3100/loki/api/v1/push" \
    "$excluded_name" > "$config" \
    || harness_failure "emit_config could not generate the $mode config"
  load_shipped_args "$work/alloy-state-$mode"
  docker run -d --name "$name" --network "container:$loki" \
    -v /var/run/docker.sock:/var/run/docker.sock:ro \
    -v "$config:/etc/alloy/config.alloy:ro,Z" \
    "${shipped_docker_args[@]}" \
    "$alloy_image" run --server.http.listen-addr=0.0.0.0:12345 \
    "${shipped_alloy_args[@]}" /etc/alloy/config.alloy > /dev/null \
    || harness_failure "could not start $alloy_image for $mode"
  address=$(docker port "$loki" 12345/tcp | head -n 1)
  [ -n "$address" ] || harness_failure "Loki for $mode published no port for Alloy"
  api="http://$address/api/v0/web/components"

  # Discovery lists containers once at start, so the fixtures are expected on
  # the first answer; the bound covers Alloy's own startup, not a refresh.
  seen_by_discovery=''
  seen_by_relabel=''
  deadline=$((SECONDS + 60))
  while [ "$SECONDS" -lt "$deadline" ]; do
    if discovery=$(curl -sf --max-time 5 "$api/discovery.docker.containers") \
      && relabel=$(curl -sf --max-time 5 "$api/discovery.relabel.bondi"); then
      seen_by_discovery=$(target_names "$discovery" exports targets)
      seen_by_relabel=$(target_names "$relabel" arguments targets)
      if [ "$seen_by_discovery" = "$fixture_names" ] \
        && [ "$seen_by_relabel" = "$fixture_names" ]; then
        break
      fi
    fi
    sleep 1
  done

  report "arm_discovery_sees_every_fixture_container ($mode)" \
    "discovery: $fixture_names | relabel input: $fixture_names" \
    "discovery: $seen_by_discovery | relabel input: $seen_by_relabel"
  if [ "$seen_by_discovery" != "$fixture_names" ] \
    || [ "$seen_by_relabel" != "$fixture_names" ]; then
    printf 'The arm did not hold for %s; this is a harness failure, so no rule is judged. Alloy said:\n' \
      "$mode" >&2
    docker logs "$name" 2>&1 | tail -n 40 >&2
    return 1
  fi

  # Read after the arm, so the output is computed from the input the arm saw.
  relabel=$(curl -sf --max-time 5 "$api/discovery.relabel.bondi") \
    || harness_failure "the relabel component stopped answering for $mode"
  jq -e '.exports' <<< "$relabel" > /dev/null \
    || harness_failure "the relabel component's answer for $mode has no exports"
  kept=$(target_names "$relabel" exports output)

  # Waits until every target the relabel component kept has its marker in
  # Loki, then reads Loki once more. A wrongly shipped fixture's marker would
  # travel beside the kept ones; the pause covers more than one batch of
  # `loki.write`, whose documented default wait is one second, so its absence
  # is read after it would have arrived. A kept marker still missing at the
  # bound is a verdict, read by the assertions below, and not a harness
  # failure.
  deadline=$((SECONDS + 60))
  while [ "$SECONDS" -lt "$deadline" ]; do
    if answer=$(query_loki "$loki_address"); then
      holds_all "$(delivered_names "$answer")" "$kept" && break
    fi
    sleep 1
  done
  sleep 3
  loki_answer=$(query_loki "$loki_address") \
    || harness_failure "Loki stopped answering for $mode"
  delivered=$(delivered_names "$loki_answer")
  docker rm -f "$name" "$loki" > /dev/null 2>&1
  return 0
}

# One `suffix=kept` or `suffix=dropped` per suffix named, in the order named,
# read off the list of names given first, in the shape `kept` has.
verdict() {
  local names=$1 suffix out=''
  shift
  for suffix in "$@"; do
    case " $names " in
      *" $suffix "*) out+="$suffix=kept " ;;
      *) out+="$suffix=dropped " ;;
    esac
  done
  printf '%s' "${out% }"
}

# One keep or drop expectation, judged twice: off the relabel output, then off
# what Loki received, where `kept` reads as "its marker arrived". The
# expectation is written once, so the two arms cannot drift apart.
report_kept_and_delivered() {
  local description=$1 expected=$2
  shift 2
  report "$description" "$expected" "$(verdict "$kept" "$@")"
  report "$description, delivered" "$expected" "$(verdict "$delivered" "$@")"
}

# One fixture's `container` label, judged twice: on its relabelled target,
# then on the Loki stream its marker arrived on.
report_container_and_delivered() {
  local description=$1 expected=$2 suffix=$3
  report "$description" "$expected" "$(container_of "$suffix")"
  report "$description, delivered" "$expected" \
    "$(delivered_container_of "$suffix")"
}

if run_alloy services_only; then
  report_kept_and_delivered 'services_only_keeps_service_and_drops_cron' \
    "service-logs-true=kept cron-logs-true=dropped $cron_pass=dropped" \
    service-logs-true cron-logs-true "$cron_pass"
  report_kept_and_delivered \
    'services_only_drops_managed_infrastructure_and_untyped' \
    'managed=dropped infrastructure-logs-true=dropped untyped=dropped' \
    managed infrastructure-logs-true untyped
  report_kept_and_delivered \
    'logs_false_dropped_and_logs_true_sibling_kept (services_only)' \
    'service-logs-false=dropped service-logs-true=kept' \
    service-logs-false service-logs-true
  report_kept_and_delivered 'logs_absent_is_kept (services_only)' \
    'service-logs-absent=kept' \
    service-logs-absent
  report_kept_and_delivered 'excluded_name_dropped (services_only)' \
    'excluded=dropped service-logs-true=kept' \
    excluded service-logs-true
  report_container_and_delivered \
    'label_less_service_falls_back_to_container_name' \
    "$prefix-service-logs-true" \
    service-logs-true
  report_every_kept_target_labelled services_only
fi

if run_alloy all; then
  report_kept_and_delivered \
    'logs_false_dropped_and_logs_true_sibling_kept (all)' \
    'service-logs-false=dropped service-logs-true=kept infrastructure-logs-false=dropped infrastructure-logs-true=kept' \
    service-logs-false service-logs-true infrastructure-logs-false infrastructure-logs-true
  report_kept_and_delivered 'logs_absent_is_kept (all)' \
    'service-logs-absent=kept' \
    service-logs-absent
  report_kept_and_delivered 'all_keeps_every_non_opted_out_non_cron_container' \
    "service-logs-true=kept service-logs-absent=kept service-name-empty=kept cron-logs-true=dropped $cron_pass=dropped managed=kept infrastructure-logs-true=kept untyped=kept" \
    service-logs-true service-logs-absent service-name-empty cron-logs-true "$cron_pass" managed infrastructure-logs-true untyped
  report_container_and_delivered \
    'managed_container_label_is_its_bondi_name_not_the_gateway_default' \
    "$prefix-managed-name" \
    managed
  report_container_and_delivered \
    'empty_bondi_name_falls_back_to_container_name' \
    "$prefix-service-name-empty" \
    service-name-empty
  report_kept_and_delivered 'excluded_name_dropped (all)' \
    'excluded=dropped service-logs-true=kept' \
    excluded service-logs-true
  report_container_and_delivered 'infrastructure_container_label_is_its_name' \
    "$prefix-infrastructure-logs-true" \
    infrastructure-logs-true
  report_every_kept_target_labelled all
fi

# --- The journal path ---

# Starts one journald fixture: a name suffix, the tag, the labels it carries,
# then the command it runs. The logging options are the ones a cron container
# runs with: the tag is the job name, and the four `bondi.*` labels are copied
# into the journal as fields of their own, all printed by emit_config from
# Run.cron_log_config. `bondi.managed=true` is named by
# each caller, so a fixture can stand for a container outside Bondi.
start_journald() {
  local suffix=$1 tag=$2 labels=$3 label
  shift 3
  local label_args=()
  for label in $labels; do
    label_args+=(--label "$label")
  done
  local log_args
  log_args=$("$emit_config" cron-log-args "$tag") \
    || harness_failure "emit_config could not name the cron log options"
  # shellcheck disable=SC2086  # one option per line, none with a space
  docker run -d --name "$prefix-$suffix" "${label_args[@]}" $log_args \
    "$fixture_image" "$@" > /dev/null \
    || harness_failure "could not start fixture $prefix-$suffix"
}

# Runs one journald fixture that prints its marker and exits at once, and
# waits for the exit: a name suffix, the tag, the labels, the marker's name.
run_journald_pass() {
  start_journald "$1" "$2" "$3" echo "$marker_prefix$4"
  docker wait "$prefix-$1" > /dev/null \
    || harness_failure "could not wait for fixture $prefix-$1"
}

# How many lines in `loki_answer` are exactly one marker, across every stream.
marker_count() {
  printf '%s' "$loki_answer" | jq -r --arg line "$marker_prefix$1" \
    '[ .data.result[].values[][1] | rtrimstr("\n") | select(. == $line) ]
     | length'
}

# One `marker=count` per marker named, in the order named.
marker_counts() {
  local marker out=''
  for marker in "$@"; do
    out+="$marker=$(marker_count "$marker") "
  done
  printf '%s' "${out% }"
}

# The label set of the stream holding one marker: its keys, its project, and
# whether its service_name is its container, the way Loki derives it. `absent`
# when no stream holds the marker.
stream_shape() {
  printf '%s' "$loki_answer" | jq -r --arg line "$marker_prefix$1" \
    '[ .data.result[] | select(any(.values[]; .[1] | rtrimstr("\n") == $line))
       | .stream
       | "keys=\(keys | join(",")) project=\(.project // "")"
         + " service_name_is_container=\(.container != null
                                         and .service_name == .container)" ]
     | if length == 0 then "absent" else unique | join(" | ") end'
}

# Waits until every marker named has arrived in the Loki at the address given
# first, or the bound in seconds given second passes, then reads that Loki once
# more after the pause run_alloy explains, into `loki_answer`. A marker still
# missing is a verdict, read by the assertions, and not a harness failure.
await_markers() {
  local address=$1 bound=$2 answer deadline marker missing
  shift 2
  deadline=$((SECONDS + bound))
  while [ "$SECONDS" -lt "$deadline" ]; do
    if answer=$(query_loki "$address"); then
      loki_answer=$answer
      missing=''
      for marker in "$@"; do
        [ "$(marker_count "$marker")" -ge 1 ] || missing=yes
      done
      [ -z "$missing" ] && break
    fi
    sleep 1
  done
  sleep 3
  loki_answer=$(query_loki "$address") \
    || harness_failure "the Loki at $address stopped answering"
}

# Starts one Alloy for the journal assertions, with the arguments emit_config
# printed, and waits until it answers ready.
start_journal_alloy() {
  local name=$1 deadline
  docker run -d --name "$name" --network "container:$journal_loki" \
    -v /var/run/docker.sock:/var/run/docker.sock:ro \
    -v "$journal_config:/etc/alloy/config.alloy:ro,Z" \
    "${shipped_docker_args[@]}" \
    "$alloy_image" run --server.http.listen-addr=0.0.0.0:12345 \
    "${shipped_alloy_args[@]}" /etc/alloy/config.alloy > /dev/null \
    || harness_failure "could not start $alloy_image for the journal assertions"
  deadline=$((SECONDS + 60))
  until curl -sf --max-time 5 "http://$journal_api_address/-/ready" > /dev/null; do
    if [ "$SECONDS" -ge "$deadline" ]; then
      docker logs "$name" 2>&1 | tail -n 40 >&2
      harness_failure "$name was not ready within 60 seconds; this is a harness failure, not a verdict on the journal path"
    fi
    sleep 1
  done
}

run_journal() {
  local state="$work/alloy-state" out discovery deadline listed=''
  local first="$prefix-alloy-journal-1" second="$prefix-alloy-journal-2"
  local job="$prefix-jjob" held=jheld-1727790000.231 pass=jjob-1727790000.201
  local noname=jnoname-1727790000.241 journal_components docker_path
  local gap_start host_entries host_count metrics lines_read bound reread
  local loki_address
  journal_loki="$prefix-loki-journal"
  journal_config="$work/journal.alloy"
  loki_answer=''

  await_loki "$journal_loki" journal
  journal_loki_address=$loki_address
  journal_api_address=$(docker port "$journal_loki" 12345/tcp | head -n 1)
  [ -n "$journal_api_address" ] \
    || harness_failure 'Loki for the journal published no port for Alloy'
  journal_components="http://$journal_api_address/api/v0/web/components"

  "$emit_config" config all "http://127.0.0.1:3100/loki/api/v1/push" \
    "$excluded_name" > "$journal_config" \
    || harness_failure 'emit_config could not generate the journal config'
  load_shipped_args "$state"

  start_journal_alloy "$first"

  # A cron pass held running until discovery lists it, so the Docker path has
  # its chance to ship the same line the journal does.
  # The single quotes are the point: `$1` is expanded by the fixture's shell.
  # shellcheck disable=SC2016
  start_journald "$held" "$prefix-jheld" \
    "bondi.managed=true bondi.type=cron bondi.logs=true bondi.name=$prefix-jheld" \
    sh -c 'echo "$1"; while [ ! -e /tmp/release ]; do sleep 0.2; done' sh \
    "${marker_prefix}journal-held"

  # Passes that exit at once, each differing from the first only in what its
  # assertion is about. The non-cron container, the container outside Bondi
  # and the logger line carry the job's tag, so a source that matched on the
  # tag would ship them.
  run_journald_pass "$pass" "$job" \
    "bondi.managed=true bondi.type=cron bondi.logs=true bondi.name=$job" \
    journal-subsecond
  run_journald_pass jjob-1727790000.211 "$job" \
    "bondi.managed=true bondi.type=cron bondi.logs=false bondi.name=$job" \
    journal-optout
  run_journald_pass excluded-jjob-1727790000.221 "$prefix-excluded-jjob" \
    "bondi.managed=true bondi.type=cron bondi.logs=true bondi.name=$prefix-excluded-jjob" \
    journal-excluded
  # An empty `bondi.name` is written as an empty field, so the container name
  # is the fallback, as on the Docker path.
  run_journald_pass "$noname" "$prefix-jnoname" \
    "bondi.managed=true bondi.type=cron bondi.logs=true bondi.name=" \
    journal-noname
  run_journald_pass jservice "$job" \
    "bondi.managed=true bondi.type=service bondi.logs=true bondi.name=$job" \
    journal-service
  # A cron-typed container that is not Bondi's: without the label, the driver
  # writes no BONDI_MANAGED field.
  run_journald_pass junmanaged-1727790000.251 "$job" \
    "bondi.type=cron bondi.logs=true bondi.name=$job" journal-unmanaged
  logger -t "$job" -- "${marker_prefix}journal-logger" \
    || harness_failure 'logger could not write to the journal'

  # The generated config has discovery refresh every 5 seconds, so the held
  # pass is listed within one refresh of its start; the bound leaves room for
  # a slow host. The held pass has to reach the Docker path's relabel component
  # too, so its output below is a verdict on this pass.
  deadline=$((SECONDS + 90))
  while [ "$SECONDS" -lt "$deadline" ]; do
    if discovery=$(curl -sf --max-time 5 "$journal_components/discovery.docker.containers") \
      && relabel=$(curl -sf --max-time 5 "$journal_components/discovery.relabel.bondi"); then
      case " $(target_names "$discovery" exports targets) | $(target_names "$relabel" arguments targets) " in
        *" $held "*"|"*" $held "*)
          listed=listed
          break
          ;;
      esac
    fi
    sleep 1
  done
  report 'arm_discovery_lists_the_held_cron_pass (journal)' listed \
    "${listed:-not listed}"
  # Loki cannot show the Docker path shipping the held pass a second time: with
  # that path's cron drop removed, the count below still read 1 [observed --
  # 2026-11-13]. The Docker source is assumed to read a journald container's
  # lines back from the journal, timestamp included, so its copy is identical
  # and Loki keeps one. What the Docker path chose to tail is read instead.
  docker_path=$(verdict "$(target_names "$relabel" exports output)" "$held")
  # The Docker source starts tailing once the relabelled target reaches it;
  # the pause gives it that time before the pass exits.
  sleep 5
  docker exec "$prefix-$held" touch /tmp/release \
    || harness_failure "could not release $prefix-$held"
  docker wait "$prefix-$held" > /dev/null \
    || harness_failure "could not wait for $prefix-$held"

  await_markers "$journal_loki_address" 30 journal-subsecond journal-held \
    journal-noname \
    service-logs-true

  report 'journal: sub-second cron marker in Loki' \
    "journal-subsecond=1 container=$job" \
    "$(marker_counts journal-subsecond) container=$(delivered_container_of journal-subsecond)"
  report 'journal: cron pass without a bondi.name is named by its container' \
    "journal-noname=1 container=$prefix-$noname" \
    "$(marker_counts journal-noname) container=$(delivered_container_of journal-noname)"
  # The service stream is the reference: a fixture the Docker path ships,
  # re-read from its start by this Alloy.
  if [ "$(stream_shape service-logs-true)" = absent ]; then
    report 'arm_service_stream_delivered (journal)' present absent
  else
    report 'arm_service_stream_delivered (journal)' present present
  fi
  report 'journal: cron stream labels equal service stream labels' \
    "$(stream_shape service-logs-true)" "$(stream_shape journal-subsecond)"
  # Once is only a verdict on the two paths while the journal path delivers at
  # all, so the sub-second pass's delivery is part of the expectation.
  report 'journal: discovered cron marker shipped once' \
    "journal-held=1 journal-subsecond=1 | docker path: $held=dropped" \
    "$(marker_counts journal-held journal-subsecond) | docker path: $docker_path"
  report 'journal: opted-out cron ships nothing' \
    'journal-optout=0 journal-subsecond=1' \
    "$(marker_counts journal-optout journal-subsecond)"
  report 'journal: excluded cron ships nothing' \
    'journal-excluded=0 journal-subsecond=1' \
    "$(marker_counts journal-excluded journal-subsecond)"
  report 'journal: non-cron journald and logger markers absent' \
    'journal-service=0 journal-logger=0 journal-subsecond=1' \
    "$(marker_counts journal-service journal-logger journal-subsecond)"
  report 'journal: cron-typed container outside Bondi ships nothing' \
    'journal-unmanaged=0 journal-subsecond=1' \
    "$(marker_counts journal-unmanaged journal-subsecond)"
  report 'journal: docker logs shows exited cron marker' \
    "${marker_prefix}journal-subsecond" \
    "$(docker logs "$prefix-$pass" 2>&1)"

  # Alloy is replaced the way setup replaces it: stopped, then removed.
  if ! { docker stop "$first" > /dev/null && docker rm "$first" > /dev/null; }; then
    harness_failure "could not stop and remove $first"
  fi
  gap_start=$(date +%s)
  # A second's pause, so the window read below starts after every entry the
  # first Alloy could have read.
  sleep 1
  run_journald_pass jjob-1727790000.202 "$job" \
    "bondi.managed=true bondi.type=cron bondi.logs=true bondi.name=$job" \
    journal-down
  start_journal_alloy "$second"
  await_markers "$journal_loki_address" 30 journal-down

  # The cron entries the host journal gained since the first Alloy stopped,
  # every one of them, so a cron container of the host's own that logged in
  # the gap raises the bound rather than failing the run.
  host_entries=$(journalctl -D "$journal_dir" --since "@$gap_start" \
    BONDI_TYPE=cron -o json -q) \
    || harness_failure "journalctl could not read $journal_dir"
  host_count=$(printf '%s' "$host_entries" | grep -c .)
  bound=$((host_count + 1))
  metrics=$(curl -sf --max-time 5 "http://$journal_api_address/metrics") \
    || harness_failure "$second did not answer its metrics"
  lines_read=$(printf '%s\n' "$metrics" | awk '
    $1 ~ /^loki_source_journal_target_lines_total([{]|$)/ { sum += $2; seen = 1 }
    END { if (seen) printf "%d", sum }')
  if [ -z "$lines_read" ]; then
    reread='no journal source metric'
  elif [ "$lines_read" -ge 1 ] && [ "$lines_read" -le "$bound" ]; then
    reread="within 1..$bound"
  else
    reread="$lines_read lines, bound $bound"
  fi
  report 'journal: marker logged while Alloy is down arrives once' \
    "journal-down=1 journal-subsecond=1 | restarted Alloy read: within 1..$bound" \
    "$(marker_counts journal-down journal-subsecond) | restarted Alloy read: $reread"
}

run_journal

# --- Alloy's HTTP server on the host's loopback ---

# Sets `listeners` to every TCP and UDP listener on one port of this host, as
# `netid address:port`, in the shape `kept` has. Set rather than printed, so a
# failure to list stops the run instead of ending a command substitution.
listeners=''
read_listeners() {
  local out
  out=$(ss -Hltun "sport = :$1") \
    || harness_failure "ss could not list this host's listeners"
  listeners=$(printf '%s\n' "$out" | awk 'NF { print $1 " " $5 }' \
    | jq -Rnr '[inputs] | unique | join(" ")') \
    || harness_failure "could not read the listeners on port $1"
}

# Sets `free_port` to a port nothing on this host listens on, other than the
# one given. Drawn below the kernel's default ephemeral range (32768 up), where
# the ports Docker publishes for the Lokis land, so a draw cannot meet one of
# those.
free_port=''
pick_free_port() {
  local taken=$1 attempt port
  for attempt in 1 2 3 4 5 6 7 8 9 10; do
    port=$((20000 + RANDOM % 10000))
    [ "$port" = "$taken" ] && continue
    read_listeners "$port"
    if [ -z "$listeners" ]; then
      free_port=$port
      return 0
    fi
  done
  harness_failure "found no free port in $attempt draws"
}

# How a container on Docker's default bridge fares connecting to this host at
# the bridge's gateway on one port: `refused`, `answered` (any HTTP answer,
# error statuses included), or what the client said instead. A refusal is the
# host's own answer: the connection reached it and found nothing listening on
# that address. The gateway is read inside the container, as its default
# route, so it is the address that container would use.
bridge_reach() {
  # The single quotes are the point: the script runs in the probe's shell.
  # shellcheck disable=SC2016
  docker run --rm --name "$prefix-bridge-probe-$1" --network bridge \
    "$fixture_image" sh -c '
      gateway=$(ip route | sed -n "s/^default via \([0-9.]*\).*/\1/p")
      if [ -z "$gateway" ]; then
        echo "no default route"
      elif out=$(wget -q -T 5 -O /dev/null "http://$gateway:$1/" 2>&1); then
        echo answered
      else
        case $out in
          *"Connection refused"*) echo refused ;;
          *"server returned error"*) echo answered ;;
          *) echo "$out" ;;
        esac
      fi' sh "$1" 2>&1
}

# The two loki.write counters in one Alloy metrics page: whether the dropped
# counter is there at all, and whether the sent counter sums above zero. The
# dropped counter is read for presence only: Alloy exports it at zero for each
# reason before anything is dropped [observed -- 2026-11-24, Alloy v1.8.0], and
# this run drops nothing on purpose. The value is a line's last field.
loki_write_counters() {
  printf '%s\n' "$1" | awk '
    $1 ~ /^loki_write_dropped_entries_total([{]|$)/ { dropped = 1 }
    $1 ~ /^loki_write_sent_entries_total([{]|$)/ { sent_seen = 1; sent += $NF }
    END {
      printf "dropped: %s | sent: %s", (dropped ? "present" : "absent"),
        (!sent_seen ? "absent" : (sent > 0 ? "above zero" : "zero"))
    }'
}

run_loopback() {
  local loki="$prefix-loki-loopback" name="$prefix-alloy-loopback"
  local config="$work/loopback.alloy" short="$prefix-short-lived"
  local gateway_listener="$prefix-gateway-listener"
  local port other_port base components out alloy_started removed_after window
  local deadline ready='' discovery listed='' metrics delivered
  local loki_address

  docker run -d --name "$loki" -p 127.0.0.1::3100 "$loki_image" \
    -config.file=/etc/loki/local-config.yaml -auth.enabled=false > /dev/null \
    || harness_failure "could not start $loki_image for the loopback Alloy"
  await_loki "$loki" loopback

  pick_free_port ''
  port=$free_port
  base="http://127.0.0.1:$port"
  components="$base/api/v0/web/components"

  # This Alloy shares the host's network, so the Loki it pushes to is the one
  # at the port that Loki publishes on this host.
  "$emit_config" config all "http://$loki_address/loki/api/v1/push" \
    "$excluded_name" > "$config" \
    || harness_failure 'emit_config could not generate the loopback config'
  load_shipped_args "$work/alloy-state-loopback"
  # Bound before it is split, as load_shipped_args explains. A run line that
  # lost its network and listen address prints nothing here, and that has to
  # reach Alloy and be judged below, not stop the run.
  out=$("$emit_config" alloy-run-args http-docker "$port") \
    || harness_failure 'emit_config could not print the HTTP docker run arguments'
  shipped_http_docker_args=()
  [ -z "$out" ] || mapfile -t shipped_http_docker_args <<< "$out"
  out=$("$emit_config" alloy-run-args http-alloy "$port") \
    || harness_failure "emit_config could not print Alloy's HTTP run arguments"
  shipped_http_alloy_args=()
  [ -z "$out" ] || mapfile -t shipped_http_alloy_args <<< "$out"

  alloy_started=$SECONDS
  docker run -d --name "$name" \
    -v /var/run/docker.sock:/var/run/docker.sock:ro \
    -v "$config:/etc/alloy/config.alloy:ro,Z" \
    "${shipped_docker_args[@]}" "${shipped_http_docker_args[@]}" \
    "$alloy_image" run "${shipped_alloy_args[@]}" \
    "${shipped_http_alloy_args[@]}" /etc/alloy/config.alloy > /dev/null \
    || harness_failure "could not start $alloy_image for the loopback assertions"

  # Everything below is read at this address, so an Alloy that does not answer
  # there is the counters arm failing, not a harness failure.
  deadline=$((SECONDS + 60))
  while [ "$SECONDS" -lt "$deadline" ]; do
    if curl -sf --max-time 5 "$base/-/ready" > /dev/null; then
      ready=ready
      break
    fi
    sleep 1
  done
  report "loopback: Alloy answers ready at the host's 127.0.0.1:<its port>" \
    ready "${ready:-no answer at $base/-/ready within 60 seconds}"
  if [ -z "$ready" ]; then
    printf 'Nothing below is read: it is all read at %s. Alloy said:\n' \
      "$base" >&2
    docker logs "$name" 2>&1 | tail -n 40 >&2
    return 0
  fi

  # Discovery lists containers once at start. A fixture started after that
  # answer is listed only by a later refresh, and one removed before the
  # refresh Alloy defaults to is never listed under that default.
  deadline=$((SECONDS + 60))
  while [ "$SECONDS" -lt "$deadline" ]; do
    if discovery=$(curl -sf --max-time 5 "$components/discovery.docker.containers"); then
      case " $(target_names "$discovery" exports targets) " in
        *" service-logs-true "*)
          listed=listed
          break
          ;;
      esac
    fi
    sleep 1
  done
  report 'arm_discovery_has_answered (loopback)' listed "${listed:-not listed}"
  if [ -z "$listed" ]; then
    docker logs "$name" 2>&1 | tail -n 40 >&2
    return 0
  fi

  # The single quotes are the point: `$1` is expanded by the fixture's shell.
  # shellcheck disable=SC2016
  docker run -d --name "$short" --label bondi.managed=true \
    --label bondi.type=service --label bondi.logs=true \
    "$fixture_image" sh -c 'echo "$1"; exec sleep 600' sh \
    "${marker_prefix}short-lived" > /dev/null \
    || harness_failure "could not start fixture $short"
  # Under the 5-second refresh the Docker source began tailing a new container
  # 11 to 15 seconds after it started, and a fixture removed after 10 seconds
  # was never tailed [observed -- 2026-11-24, Docker Engine 29.10.0, Alloy
  # v1.8.0, five starts and one 10-second run]. So the fixture lives 25
  # seconds: past that, and still removed well before a one-minute refresh.
  sleep 25
  docker rm -f "$short" > /dev/null \
    || harness_failure "could not remove fixture $short"
  # Alloy's first discovery answer came no earlier than its start, so its next
  # refresh under the one-minute default comes no earlier than a minute after
  # the start. Removed before that, the fixture is one that default never
  # lists. The bound is under a minute by the margin of whole-second clocks.
  removed_after=$((SECONDS - alloy_started))
  window="removed $removed_after s after Alloy started"
  [ "$removed_after" -lt 55 ] && window='removed within 55 s of Alloy starting'
  report 'arm_short_lived_fixture_removed_before_a_one_minute_refresh (loopback)' \
    'removed within 55 s of Alloy starting' "$window"

  await_markers "$loki_address" 30 short-lived
  if [ "$(marker_count short-lived)" -ge 1 ]; then
    delivered=delivered
  else
    delivered='not delivered'
  fi
  report 'short-lived: a container removed before a one-minute refresh has its marker in Loki' \
    delivered "$delivered"

  # Read from the host, at the address the box's operator reads, once a marker
  # has been delivered.
  if metrics=$(curl -sf --max-time 5 "$base/metrics"); then
    report 'counters: dropped and sent entries read from the host' \
      'dropped: present | sent: above zero' "$(loki_write_counters "$metrics")"
  else
    report 'counters: dropped and sent entries read from the host' \
      'dropped: present | sent: above zero' "no answer at $base/metrics"
  fi

  read_listeners "$port"
  report "loopback: the only listener on Alloy's port is the host's 127.0.0.1" \
    "tcp 127.0.0.1:$port" "$listeners"

  # A listener on every address of the host, so a refusal on Alloy's port is
  # told apart from a bridge that reaches nothing on the host.
  pick_free_port "$port"
  other_port=$free_port
  docker run -d --name "$gateway_listener" --network host "$fixture_image" \
    httpd -f -p "$other_port" > /dev/null \
    || harness_failure "could not start $gateway_listener"
  deadline=$((SECONDS + 30))
  read_listeners "$other_port"
  while [ -z "$listeners" ] && [ "$SECONDS" -lt "$deadline" ]; do
    sleep 1
    read_listeners "$other_port"
  done
  [ -n "$listeners" ] \
    || harness_failure "$gateway_listener did not listen on $other_port within 30 seconds"
  report "loopback: a default-bridge container is refused at the gateway on Alloy's port, and answered on a port listening on every address" \
    "alloy=refused every-address=answered" \
    "alloy=$(bridge_reach "$port") every-address=$(bridge_reach "$other_port")"

  docker rm -f "$name" "$loki" "$gateway_listener" > /dev/null 2>&1
  return 0
}

run_loopback

if [ "$failures" -ne 0 ]; then
  printf '%d assertion(s) failed against a real Alloy (%s) writing to a real Loki (%s).\n' \
    "$failures" "$alloy_image" "$loki_image" >&2
  exit 1
fi
