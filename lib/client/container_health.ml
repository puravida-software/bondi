type verdict =
  | Healthy
  | Unhealthy of string
  | No_healthcheck
  | Timed_out of { seconds : int }
  | Gone
  | Unreadable of string

let healthy_marker = "BONDI_CONTAINER_HEALTHY"
let unhealthy_marker = "BONDI_CONTAINER_UNHEALTHY"
let no_healthcheck_marker = "BONDI_CONTAINER_NO_HEALTHCHECK"
let timeout_marker = "BONDI_CONTAINER_TIMEOUT"
let gone_marker = "BONDI_CONTAINER_GONE"
let unreadable_marker = "BONDI_CONTAINER_UNREADABLE"
let wait_timeout_seconds = 120

(* The word Docker writes into a healthcheck's test when an operator disables
   one with --no-healthcheck. The record is present and non-empty, so asking
   only whether it exists reads an explicit "there is no check here" as a check
   to wait for — and then waits out the whole bound before failing the run. *)
let disabled_healthcheck_test = "NONE"

(* Four things the loop has to keep apart, and the shape of the command follows
   from them:

   - a reading that could not be taken. Every [docker inspect] here discards its
     stderr, so a daemon that is down or a socket the user may not open comes
     back as an empty string. Compared against "running" that is not running,
     which reported a read that never happened as a fact about the container.
     Each read is now tested for having succeeded at all, and where one has not,
     the daemon is asked whether it answers before this says the container is
     gone.
   - a container that has stopped, which is a real answer and stops the wait.
   - a check the operator disabled, which is not a check to wait for.
   - the bound, taken from the host's clock rather than from a count of
     iterations. Each pass does several round-trips plus a sleep, so a loop
     counting to 120 runs well past 120 seconds, and the row prints the number
     in seconds. A deadline makes the printed number true. *)
let wait_command ~container_name ~timeout_seconds =
  let container = Filename.quote container_name in
  Printf.sprintf
    "deadline=$(($(date +%%s) + %d)); while [ \"$(date +%%s)\" -lt \
     \"$deadline\" ]; do if ! state=$(docker inspect --format \
     '{{.State.Status}}' %s 2>/dev/null); then if docker version >/dev/null \
     2>&1; then echo %s; else echo %s; fi; exit 0; fi; if [ -z \"$state\" ]; \
     then echo %s; exit 0; fi; if [ \"$state\" != running ]; then echo %s; \
     exit 0; fi; if ! check=$(docker inspect --format '{{if \
     .Config.Healthcheck}}{{if .Config.Healthcheck.Test}}{{index \
     .Config.Healthcheck.Test 0}}{{end}}{{end}}' %s 2>/dev/null); then echo \
     %s; exit 0; fi; if [ -z \"$check\" ] || [ \"$check\" = %s ]; then echo \
     %s; exit 0; fi; status=$(docker inspect --format '{{if \
     .State.Health}}{{.State.Health.Status}}{{end}}' %s 2>/dev/null); if [ \
     \"$status\" = healthy ]; then echo %s; exit 0; fi; if [ \"$status\" = \
     unhealthy ]; then echo %s; docker inspect --format 'failing streak \
     {{.State.Health.FailingStreak}}' %s 2>/dev/null; exit 0; fi; sleep 1; \
     done; echo %s %d; exit 0"
    timeout_seconds container gone_marker unreadable_marker unreadable_marker
    gone_marker container unreadable_marker disabled_healthcheck_test
    no_healthcheck_marker container healthy_marker unhealthy_marker container
    timeout_marker timeout_seconds

let detail_after ~marker output =
  match Bondi_common.String_utils.index_of ~needle:marker output with
  | None -> None
  | Some index ->
      let start = index + String.length marker in
      Some
        (String.trim (String.sub output start (String.length output - start)))

let timed_out_of_detail detail =
  match int_of_string_opt detail with
  | Some seconds -> Timed_out { seconds }
  | None ->
      Unreadable "the host stopped waiting without naming the bound it waited"

(* Two failures an operator resolves in different places, and the wait cannot
   report a verdict for either. A host that ran the wait and exited non-zero has
   said something about itself -- the command always exits 0 by construction, so
   a non-zero exit is the host's own report that something on it is wrong. A
   host that was never reached has said nothing, and giving both the same
   sentence sends an operator to the key when the answer is on the box. *)
let unreadable_of_failure failure =
  if Remote_exec.ran_on_host failure then
    Unreadable
      (Printf.sprintf "the wait ran on the host and failed: %s"
         (Remote_exec.message failure))
  else Unreadable (Remote_exec.message failure)

let verdict_of_output reading =
  match reading with
  | Error failure -> unreadable_of_failure failure
  | Ok output -> (
      let marked (marker, of_detail) =
        Option.map of_detail (detail_after ~marker output)
      in
      let ordered =
        [
          ( unreadable_marker,
            fun _ ->
              Unreadable
                "the host could not read the container's state, so nothing \
                 about its health was established" );
          (gone_marker, fun _ -> Gone);
          (timeout_marker, timed_out_of_detail);
          (unhealthy_marker, fun detail -> Unhealthy detail);
          (no_healthcheck_marker, fun _ -> No_healthcheck);
          (healthy_marker, fun _ -> Healthy);
        ]
      in
      match List.find_map marked ordered with
      | Some verdict -> verdict
      | None ->
          Unreadable
            (Printf.sprintf
               "the health check on the host answered without a verdict: %s"
               (String.trim output)))
