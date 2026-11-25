type verdict =
  | Healthy
  | Never_healthy of { port : int }
  | Unhealthy of { body : string }
  | Curl_missing
  | Unreadable of Host_answer.t

let healthy_marker = "BONDI_ALLOY_HEALTHY"
let never_healthy_marker = "BONDI_ALLOY_NEVER_HEALTHY"
let unhealthy_marker = "BONDI_ALLOY_UNHEALTHY"
let curl_missing_marker = "BONDI_ALLOY_CURL_MISSING"
let wait_seconds = 30

(* The cap on one attempt. A process other than Alloy holding the port may
   accept the connection and never answer, and an uncapped curl would then
   spend the whole bound on its first attempt. *)
let attempt_seconds = 2
let health_url ~port = Printf.sprintf "http://127.0.0.1:%d/-/healthy" port

(* The bound is read off the host's clock rather than counted in attempts: an
   attempt that waits out its cap takes longer than the sleep between attempts,
   so a count would run past the bound it claims. The deadline is checked after
   an attempt, so the first one is always made, and an attempt that fails near
   the deadline ends the wait as never healthy, the same verdict as any other
   failed attempt. *)
let probe_command ~port ~timeout_s =
  Printf.sprintf
    "if ! command -v curl >/dev/null 2>&1; then echo %s; exit 0; fi; \
     deadline=$(($(date +%%s) + %d)); unhealthy=; seen=; while :; do \
     out=$(curl -s --max-time %d -w '%%{http_code}' %s 2>/dev/null); \
     code=$(printf %%s \"$out\" | tail -c 3); if [ \"$code\" = 200 ]; then \
     echo %s; exit 0; fi; if [ \"$code\" = 500 ]; then unhealthy=1; \
     seen=${out%%???}; fi; if [ \"$(date +%%s)\" -ge \"$deadline\" ]; then if \
     [ -n \"$unhealthy\" ]; then echo %s; printf '%%s\\n' \"$seen\"; else echo \
     %s; fi; exit 0; fi; sleep 1; done"
    curl_missing_marker timeout_s attempt_seconds
    (Filename.quote (health_url ~port))
    healthy_marker unhealthy_marker never_healthy_marker

(* The marker leads and Alloy's own words follow it. [Host_answer] folds line
   breaks into spaces, so the separator is read as either. *)
let unhealthy_body answer =
  let text = String.trim (Host_answer.to_string answer) in
  let n = String.length unhealthy_marker in
  if String.equal text unhealthy_marker then Some ""
  else if
    String.length text > n
    && String.equal (String.sub text 0 n) unhealthy_marker
    && (text.[n] = ' ' || text.[n] = '\n')
  then Some (String.trim (String.sub text n (String.length text - n)))
  else None

let verdict_of_probe ~port answer =
  match unhealthy_body answer with
  | Some body -> Unhealthy { body }
  | None -> (
      match String.trim (Host_answer.to_string answer) with
      | marker when String.equal marker healthy_marker -> Healthy
      | marker when String.equal marker never_healthy_marker ->
          Never_healthy { port }
      | marker when String.equal marker curl_missing_marker -> Curl_missing
      | _ -> Unreadable answer)

let require_healthy = function
  | Healthy -> Ok ()
  | Unhealthy { body } ->
      Error
        (Printf.sprintf
           "Alloy answered at the end of the wait, but reported itself \
            unhealthy: %s"
           body)
  | Never_healthy { port } ->
      Error
        (Printf.sprintf
           "Alloy did not answer healthy at %s before setup gave up waiting. \
            It may have exited at start: another process on the box may hold \
            port %d."
           (health_url ~port) port)
  | Curl_missing ->
      Error
        "the box has no curl on its PATH, so setup could not ask Alloy whether \
         it is healthy. Install curl on the box and run setup again."
  | Unreadable answer ->
      Error
        (Printf.sprintf
           "could not read whether Alloy answered healthy: the probe printed \
            no verdict: %S"
           (Host_answer.to_string answer))
