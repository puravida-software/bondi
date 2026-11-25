type curl_verdict =
  | Curl_present
  | Curl_missing
  | Curl_unreadable of Host_answer.t

type port_verdict =
  | Port_free
  | Port_held_by_alloy
  | Port_held of { port : int }
  | Port_unreadable of { port : int; answer : Host_answer.t }

let curl_present_marker = "BONDI_ALLOY_CURL_PRESENT"
let curl_missing_marker = "BONDI_ALLOY_CURL_MISSING"
let port_free_marker = "BONDI_ALLOY_PORT_FREE"
let port_held_by_alloy_marker = "BONDI_ALLOY_PORT_HELD_BY_ALLOY"
let port_held_marker = "BONDI_ALLOY_PORT_HELD"
let port_unreadable_marker = "BONDI_ALLOY_PORT_UNREADABLE"

(* [command -v] reports a missing name by exiting non-zero, which is the channel
   a dropped connection arrives on too, so the probe says which on standard
   output and always exits 0. *)
let curl_probe_command =
  Printf.sprintf
    "if command -v curl >/dev/null 2>&1; then echo %s; else echo %s; fi"
    curl_present_marker curl_missing_marker

let curl_verdict_of_probe answer =
  match String.trim (Host_answer.to_string answer) with
  | marker when String.equal marker curl_present_marker -> Curl_present
  | marker when String.equal marker curl_missing_marker -> Curl_missing
  | _ -> Curl_unreadable answer

let require_curl ~port = function
  | Curl_present -> Ok ()
  | Curl_missing ->
      Error
        (Printf.sprintf
           "the box has no curl on its PATH, so setup could not ask Alloy \
            whether it is healthy on port %d once started. Nothing was \
            stopped. Install curl on the box and run setup again."
           port)
  | Curl_unreadable answer ->
      Error
        (Printf.sprintf
           "could not read whether the box has curl, which setup needs to ask \
            Alloy whether it is healthy on port %d: the probe printed no \
            verdict: %S. Nothing was stopped."
           port
           (Host_answer.to_string answer))

(* The listener check comes first and the Docker question only when something
   listens, so a free port costs no Docker call. A failing [ss] is its own
   marker: an empty listing is the evidence of a free port only when [ss] ran. *)
let port_probe_command ~port =
  Printf.sprintf
    "if ! command -v ss >/dev/null 2>&1; then echo %s; elif ! held=$(ss -Hltn \
     'sport = :%d' 2>/dev/null); then echo %s; elif [ -z \"$held\" ]; then \
     echo %s; elif [ \"$(docker inspect -f '{{.State.Running}} \
     {{.HostConfig.NetworkMode}}' bondi-alloy 2>/dev/null)\" = 'true host' ]; \
     then echo %s; else echo %s; fi"
    port_unreadable_marker port port_unreadable_marker port_free_marker
    port_held_by_alloy_marker port_held_marker

let port_verdict_of_probe ~port answer =
  match String.trim (Host_answer.to_string answer) with
  | marker when String.equal marker port_free_marker -> Port_free
  | marker when String.equal marker port_held_by_alloy_marker ->
      Port_held_by_alloy
  | marker when String.equal marker port_held_marker -> Port_held { port }
  | _ -> Port_unreadable { port; answer }

let require_port_available = function
  | Port_free
  | Port_held_by_alloy ->
      Ok ()
  | Port_held { port } ->
      Error
        (Printf.sprintf
           "port %d on the box is held by a process that is not the \
            bondi-alloy container, and Alloy's HTTP server binds that port, so \
            a replacement would exit at start. Nothing was stopped. Free the \
            port, or stop what holds it, and run setup again."
           port)
  | Port_unreadable { port; answer } ->
      Error
        (Printf.sprintf
           "could not read whether port %d on the box is free, which Alloy's \
            HTTP server needs: the probe printed no verdict: %S. Nothing was \
            stopped."
           port
           (Host_answer.to_string answer))
