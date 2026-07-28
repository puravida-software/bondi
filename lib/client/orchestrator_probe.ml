(* Markers rather than exit codes, and the probe always exits 0. SSH's own exit
   status already means "could the command be run on that host at all", and
   overloading it with the verdict loses the verdict: the SSH layer reports a
   non-zero remote command as an error carrying its stderr, discarding the
   stdout that said why. The marker is the one signal that survives. *)
let serving_marker = "BONDI_ORCHESTRATOR_SERVING"
let unreachable_marker = "BONDI_ORCHESTRATOR_UNREACHABLE"
let container_name = "bondi-orchestrator"
let health_path = "/api/v1/health"
let readiness_attempts = 30

(* The health request is issued from inside the orchestrator container with
   busybox wget, which the server image has because it is Alpine-based. Probing
   from the host would need curl or wget there, which setup does not otherwise
   require and which a minimal server may not have. *)
let probe_command ~port ~attempts =
  Printf.sprintf
    "attempt=0; while [ \"$attempt\" -lt %d ]; do if ! docker ps --filter \
     name=^/%s$ --format '{{.Names}}' | grep -q '^%s$'; then echo %s; exit 0; \
     fi; if docker exec %s wget -q -O /dev/null http://127.0.0.1:%d%s \
     >/dev/null 2>&1; then echo %s; exit 0; fi; attempt=$((attempt + 1)); \
     sleep 1; done; echo %s; exit 0"
    attempts container_name container_name unreachable_marker container_name
    port health_path serving_marker unreachable_marker

let diagnostics_command =
  Printf.sprintf
    "docker inspect --format 'status={{.State.Status}} \
     exit={{.State.ExitCode}} oom={{.State.OOMKilled}} error={{.State.Error}}' \
     %s 2>&1; echo '--- last 50 log lines ---'; docker logs --tail 50 %s 2>&1"
    container_name container_name

let verdict probe =
  match probe with
  | Ok output ->
      if Bondi_common.String_utils.contains ~needle:serving_marker output then
        Ok ()
      else
        Error
          (Printf.sprintf
             "the orchestrator container did not answer GET %s. The readiness \
              check answered: %s"
             health_path (String.trim output))
  | Error message ->
      Error
        (Printf.sprintf "the readiness check could not be run on the server: %s"
           message)

let failure_message ~ip_address ~image ~reason ~diagnostics =
  Printf.sprintf
    "bondi-orchestrator did not come up on server %s.\n\
     Image: %s\n\
     %s\n\
     Container state and logs from the server:\n\
     %s\n\
     The container was left in place so it can be inspected: run `docker logs \
     %s` on %s. To restore service, set bondi_server.version in bondi.yaml \
     back to a version known to run on this host and run `bondi setup` again."
    ip_address image reason diagnostics container_name ip_address
