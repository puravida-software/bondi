(* The name the rest of setup creates, inspects and removes the container
   under, taken from the module that also writes the crontab line execing
   into it. A probe that spelled the name itself could go on waiting for a
   container nothing creates any more, and would report the host unreachable
   rather than say so. *)
let container_name = Bondi_common.Builtin_container.orchestrator

(* The path the image installs the server binary at, and the path its entry
   point names. It is spelled absolutely rather than left to the container's
   PATH because the exec runs with whatever environment the image's shell
   happens to publish, and a check that could not find the binary is
   indistinguishable at this distance from a box that is not ready. *)
let server_binary = "/usr/local/bin/bondi-server"
let running_attempts = 30

(* How much of a container's log stream is read back, by the diagnostics a
   refused reading quotes and by the caller establishing that the check's own
   line reached the stream. One number rather than one per caller, and one
   spelling rather than one per position: the diagnostics read announces the
   bound in a banner above the lines it then asks docker for, and a banner
   saying fifty above twenty-five lines misreports what an operator is looking
   at on the single run where any of this is read.

   Bounded, because the line the caller looks for was written moments ago and
   an unbounded read pulls a busy orchestrator's whole history across the
   connection to find it. Not bounded to one or two lines either: an
   orchestrator that is serving writes lines of its own between the check
   answering and the read being taken, and a bound tight enough for them to
   push the marker out would report a healthy container as one whose
   diagnostics never arrive. *)
let log_lines = 50

(* The wait carries its answer in the exit status, and the two ways of failing
   are told apart by the sentence on standard error rather than by the code: the
   transport merges the error stream into a failure's output, so a caller sees
   which happened without a second code to agree on.

   The loop reads the container's state rather than asking whether a name
   appears in a listing, because the two failures it has to separate -- a
   container that is not there at all and one that is there and not yet up --
   look the same in a listing filtered by name. It stops only on the first. A
   container being restarted under a restart policy is present and not running
   for as long as the restart takes, and a wait that gave up on that state would
   report a box that was coming up as one that had gone. *)

(* The name is quoted once and then stands quoted in every position, the two
   sentences an operator reads included. The caller supplies it, and a name
   carrying a quote would break the command while one carrying [$] or a
   backtick would be evaluated by the host's shell -- so the sentences hand the
   quoted word to [echo] as a word of its own rather than interpolating it into
   a quoted string, which is also why the timeout sentence, which does want
   [$state] expanded, cannot simply be one pair of double quotes around the
   lot. [echo] joins its arguments with a single space, so what an operator
   reads is the sentence either way. *)
let running_command ~container_name ~attempts =
  let container = Filename.quote container_name in
  Printf.sprintf
    "attempt=0; while [ \"$attempt\" -lt %d ]; do if ! state=$(docker inspect \
     --format '{{.State.Status}}' %s 2>/dev/null); then echo container %s 'is \
     not present on this host' >&2; exit 1; fi; if [ \"$state\" = running ]; \
     then exit 0; fi; attempt=$((attempt + 1)); sleep 1; done; echo container \
     %s \"did not reach a running state after %d attempts; its last state was \
     $state\" >&2; exit 1"
    attempts container container container attempts

(* The check runs inside the container because that is where the binary is, and
   [docker exec] is the only way in that does not require the container to have
   published anything. Standard error is left where it is: the subcommand writes
   its document to standard output and its reasons to standard error, and the
   transport already brings both back on a non-zero status, which is the only
   outcome the reasons are wanted for. *)
let check_command ~container_name ~cron_configured =
  Printf.sprintf "docker exec %s %s check%s"
    (Filename.quote container_name)
    server_binary
    (match cron_configured with
    | true -> " --cron-configured"
    | false -> "")

(* Both streams, because the line being looked for is a diagnostic and
   diagnostics are written to standard error. Bounded, because a busy
   orchestrator's whole history is not wanted on the connection to establish
   that a line written moments ago arrived. *)
let log_stream_command ~container_name ~lines =
  Printf.sprintf "docker logs --tail %d %s 2>&1" lines
    (Filename.quote container_name)

type verdict = Serving | Not_ready of string | Unreachable of string
type log_stream = Carrying | Silent | Unreadable of string

(* Every reason an operator reads for a reading that was not taken opens the
   same way, because the first thing they have to know is that the box said
   nothing -- not that a command failed, which is also true of a box that
   answered. The rest is the transport's own account, which already separates a
   host that ran the command from one that was never reached and bounds what it
   quotes back. *)
let nothing_obtained detail =
  Printf.sprintf "no reading was obtained from the box: %s" detail

(* Asked of the transport's type rather than by matching a guarded
   [Command_failed] arm here: a guarded arm followed by the remaining
   constructors is a match the compiler cannot check for completeness, because
   the guarded arm and the fall-through share a constructor. *)
let is_readiness_status failure =
  Remote_exec.exited_with ~code:Bondi_common.Readiness_exit_code.not_ready
    failure

let verdict_of_output reading =
  match reading with
  | Ok output ->
      if String.trim output = "" then
        Unreachable
          (nothing_obtained
             "the check exited without writing a document, and a command that \
              exited saying nothing is not evidence that the box can serve")
      else Serving
  | Error failure ->
      if is_readiness_status failure then
        Not_ready
          (Printf.sprintf "the box reported it is not in a state to serve: %s"
             (Remote_exec.message failure))
      else
        Unreachable
          (nothing_obtained
             (Remote_exec.explain ~subject:"the readiness check" failure))

let log_stream_of_output reading =
  match reading with
  | Ok output ->
      if
        Bondi_common.String_utils.contains
          ~needle:Bondi_common.Check_marker.diagnostic_sink output
      then Carrying
      else Silent
  | Error failure ->
      Unreadable (Remote_exec.explain ~subject:"the log stream read" failure)

let diagnostics_command =
  Printf.sprintf
    "docker inspect --format 'status={{.State.Status}} \
     exit={{.State.ExitCode}} oom={{.State.OOMKilled}} error={{.State.Error}}' \
     %s 2>&1; echo '--- last %d log lines ---'; docker logs --tail %d %s 2>&1"
    container_name log_lines log_lines container_name

let failure_message ~ip_address ~image ~reason ~diagnostics =
  Printf.sprintf
    "%s did not come up on server %s.\n\
     Image: %s\n\
     %s\n\
     Container state and logs from the server:\n\
     %s\n\
     The container was left in place so it can be inspected: run `docker logs \
     %s` on %s. To restore service, set bondi_server.version in bondi.yaml \
     back to a version known to run on this host and run `bondi setup` again."
    container_name ip_address image reason diagnostics container_name ip_address
