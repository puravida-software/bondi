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
# socket, the generated config, and the relabel output. What is not: the Loki
# endpoint, which is a port nothing listens on, so nothing is pushed and no
# credential is needed. Delivery is not this file's subject; the relabel output
# is exactly the target list the log source consumes.
#
# Written against, and executed under, Docker Engine 29.8.1 with the Alloy image
# named by the server's defaults (v1.8.0 when written), jq 1.8.2 and GNU bash
# 5.3. The hosted runner image lists jq 1.7.1, which this has not yet run under.
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
  printf 'skipped: %s. This case is not skippable where CI is set, and fails there instead.\n' "$1"
  exit 0
}

for program in docker jq curl; do
  command -v "$program" > /dev/null 2>&1 \
    || unavailable "$program is not on this machine's PATH"
done
docker info > /dev/null 2>&1 \
  || unavailable "the Docker daemon does not answer 'docker info'"

# A small image whose only job is to exist with labels. Pinned so the fixture
# is the same container on every machine.
fixture_image='busybox:1.37.0'

if ! alloy_image=$("$emit_config" image); then
  printf 'FAIL: %s could not name the Alloy image.\n' "$emit_config" >&2
  exit 1
fi

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

for image in "$fixture_image" "$alloy_image"; do
  docker pull -q "$image" > /dev/null \
    || harness_failure "could not pull $image; this is a harness failure, not a verdict on the rules"
done

# The fixtures: a name suffix, then the labels it carries beside
# `bondi.managed=true`. Every container a mode drops has a sibling of the same
# `bondi.type` that differs only in the label under test and is kept, so a
# rule that drops everything cannot pass as a rule that drops the right thing.
fixtures=(
  'service-logs-true bondi.type=service bondi.logs=true'
  'service-logs-false bondi.type=service bondi.logs=false'
  'service-logs-absent bondi.type=service'
  'cron-logs-true bondi.type=cron bondi.logs=true'
  'managed bondi.type=managed bondi.logs=true'
  'infrastructure-logs-true bondi.type=infrastructure bondi.logs=true'
  'infrastructure-logs-false bondi.type=infrastructure bondi.logs=false'
  'untyped'
  'excluded bondi.type=service bondi.logs=true'
  # A cron pass runs under its job name plus a timestamp for its whole life,
  # so the name discovery sees differs on every pass; `bondi.name` carries the
  # job name that stays the same.
  "job-1727790000.123 bondi.type=cron bondi.logs=true bondi.name=$prefix-job"
)
excluded_name="$prefix-excluded"
cron_pass='job-1727790000.123'

suffixes=()
for fixture in "${fixtures[@]}"; do
  read -r suffix labels <<< "$fixture"
  label_args=(--label bondi.managed=true)
  for label in $labels; do
    label_args+=(--label "$label")
  done
  docker run -d --name "$prefix-$suffix" "${label_args[@]}" \
    "$fixture_image" sleep 600 > /dev/null \
    || harness_failure "could not start fixture $prefix-$suffix"
  suffixes+=("$suffix")
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

# Runs Alloy over the config generated for one mode, waits on the arm, and
# leaves the relabel component's answer in `relabel` and its kept names in
# `kept`. Returns non-zero when the arm did not hold, in which case neither is
# a verdict.
run_alloy() {
  local mode=$1 config="$work/$1.alloy" name="$prefix-alloy-$1"
  local address api discovery seen_by_discovery seen_by_relabel deadline
  relabel=''
  kept=''
  "$emit_config" config "$mode" "$excluded_name" > "$config" \
    || harness_failure "emit_config could not generate the $mode config"
  docker run -d --name "$name" -p 127.0.0.1::12345 \
    -v /var/run/docker.sock:/var/run/docker.sock:ro \
    -v "$config:/etc/alloy/config.alloy:ro,Z" \
    "$alloy_image" run --server.http.listen-addr=0.0.0.0:12345 \
    /etc/alloy/config.alloy > /dev/null \
    || harness_failure "could not start $alloy_image for $mode"
  address=$(docker port "$name" 12345/tcp | head -n 1)
  [ -n "$address" ] || harness_failure "Alloy for $mode published no port"
  api="http://$address/api/v0/web/components"

  # Discovery lists containers once at start, so the fixtures are expected on
  # the first answer; the bound covers Alloy's own startup, not a refresh.
  seen_by_discovery=''
  seen_by_relabel=''
  deadline=$((SECONDS + 60))
  while [ "$SECONDS" -lt "$deadline" ]; do
    if discovery=$(curl -sf "$api/discovery.docker.containers") \
      && relabel=$(curl -sf "$api/discovery.relabel.bondi"); then
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
  relabel=$(curl -sf "$api/discovery.relabel.bondi") \
    || harness_failure "the relabel component stopped answering for $mode"
  kept=$(target_names "$relabel" exports output)
  docker rm -f "$name" > /dev/null 2>&1
  return 0
}

# One `suffix=kept` or `suffix=dropped` per suffix named, in the order named.
verdict() {
  local suffix out=''
  for suffix in "$@"; do
    case " $kept " in
      *" $suffix "*) out+="$suffix=kept " ;;
      *) out+="$suffix=dropped " ;;
    esac
  done
  printf '%s' "${out% }"
}

if run_alloy services_only; then
  report 'services_only_keeps_service_and_cron' \
    'service-logs-true=kept cron-logs-true=kept' \
    "$(verdict service-logs-true cron-logs-true)"
  report 'services_only_drops_managed_infrastructure_and_untyped' \
    'managed=dropped infrastructure-logs-true=dropped untyped=dropped' \
    "$(verdict managed infrastructure-logs-true untyped)"
  report 'logs_false_dropped_and_logs_true_sibling_kept (services_only)' \
    'service-logs-false=dropped service-logs-true=kept' \
    "$(verdict service-logs-false service-logs-true)"
  report 'logs_absent_is_kept (services_only)' \
    'service-logs-absent=kept' \
    "$(verdict service-logs-absent)"
  report 'excluded_name_dropped (services_only)' \
    'excluded=dropped service-logs-true=kept' \
    "$(verdict excluded service-logs-true)"
  report 'cron_temp_name_gets_stable_container_label' \
    "$prefix-job" \
    "$(container_of "$cron_pass")"
  report 'label_less_service_falls_back_to_container_name' \
    "$prefix-service-logs-true" \
    "$(container_of service-logs-true)"
  report_every_kept_target_labelled services_only
fi

if run_alloy all; then
  report 'logs_false_dropped_and_logs_true_sibling_kept (all)' \
    'service-logs-false=dropped service-logs-true=kept infrastructure-logs-false=dropped infrastructure-logs-true=kept' \
    "$(verdict service-logs-false service-logs-true infrastructure-logs-false infrastructure-logs-true)"
  report 'logs_absent_is_kept (all)' \
    'service-logs-absent=kept' \
    "$(verdict service-logs-absent)"
  report 'all_keeps_every_non_opted_out_container' \
    'service-logs-true=kept service-logs-absent=kept cron-logs-true=kept managed=kept infrastructure-logs-true=kept untyped=kept' \
    "$(verdict service-logs-true service-logs-absent cron-logs-true managed infrastructure-logs-true untyped)"
  report 'excluded_name_dropped (all)' \
    'excluded=dropped service-logs-true=kept' \
    "$(verdict excluded service-logs-true)"
  report 'infrastructure_container_label_is_its_name' \
    "$prefix-infrastructure-logs-true" \
    "$(container_of infrastructure-logs-true)"
  report_every_kept_target_labelled all
fi

if [ "$failures" -ne 0 ]; then
  printf '%d assertion(s) failed against a real Alloy (%s).\n' \
    "$failures" "$alloy_image" >&2
  exit 1
fi
