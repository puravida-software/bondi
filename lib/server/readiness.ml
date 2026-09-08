type probe = Docker_socket | Crontab_spool | Diagnostic_sink
type observation = { probe : probe; outcome : (unit, string) result }
type verdict = Ready | Not_ready of observation list

(* The reason an operator reads: the path that was probed and the system's own
   word for what happened to it. It carries no value taken from a payload --
   these lines reach a terminal, an HTTP response and the container log. *)
let unix_reason path error =
  Printf.sprintf "%s: %s" path (Unix.error_message error)

(* Closing is not part of what a probe reports. The reading is of the connect,
   the create or the write; a close that fails on a descriptor opened moments
   ago tells the operator nothing they can act on, and reporting it would put a
   second condition behind the same verdict. *)
let close_quietly fd =
  try Unix.close fd with
  | Unix.Unix_error _ -> ()

(* Connected to rather than opened. Unix.openfile on a socket file returns
   ENXIO, so a literal open would report every working Engine as broken.
   Connecting also separates a live socket from one an engine left behind when
   it died, which refuses the connection where an existence check passes.

   [observed -- 2026-09-07] Two programs, OCaml 5.3 on Linux
   7.2.1-ogc4.1.fc44.x86_64. The first binds and listens on a Unix stream
   socket, then reads that same path three ways:

     open(2) O_WRONLY: open failed "m6.sock" -> No such device or address
     open(2) O_RDONLY: open failed "m6.sock" -> No such device or address
     connect(2): succeeded

   The second binds, closes the bound descriptor without listening, and leaves
   the socket file where a dead engine would have left it:

     Sys.file_exists: true
     connect(2): connect failed "" -> Connection refused *)
let docker_socket_probe path =
  let outcome =
    match Unix.socket Unix.PF_UNIX Unix.SOCK_STREAM 0 with
    | exception Unix.Unix_error (error, _, _) -> Error (unix_reason path error)
    | socket ->
        Fun.protect
          ~finally:(fun () -> close_quietly socket)
          (fun () ->
            match Unix.connect socket (Unix.ADDR_UNIX path) with
            | () -> Ok ()
            | exception Unix.Unix_error (error, _, _) ->
                Error (unix_reason path error))
  in
  { probe = Docker_socket; outcome }

(* Removing what the probe made, on the failing path as well as the passing
   one. The unlink in the body is the one that reports -- a spool that will not
   give the file back is a spool the operator has to look at -- and this is the
   sweep behind it, so an exception raised anywhere in between cannot leave the
   file in the directory the probe is testing. Already gone is the ordinary
   case, and it is not a finding. *)
let remove_quietly path =
  try Unix.unlink path with
  | Unix.Unix_error _ -> ()

(* The name every probe file is made under. Three things about it are
   load-bearing:

   The leading dot, because cron skips spool entries whose name begins with one
   and the file must never be read as a crontab in the window it exists.
   [assumed -- from Debian/vixie cron's documented spool handling; the source
   was not read here.] A rename that drops the dot would break this silently,
   which is why [test_readiness_probes.ml] pins the prefix through the one
   message that carries the name.

   [Filename.temp_file], because the name has to be unique per attempt and not
   merely per process. A run killed between the create and the unlink leaves
   its file behind; a pid-derived name then collides with that leftover as soon
   as a pid is reused -- inside a long-lived container, where [check] is a
   short-lived process landing on recycled low pids, that is ordinary -- and
   the collision would be reported as an unwritable spool, which is a diagnosis
   of the wrong thing.

   O_EXCL, which [Filename.temp_file] opens with, so the probe can never
   truncate something it did not make. [observed -- 2026-09-07] The stdlib
   shipped in this switch, [_opam/lib/ocaml/filename.ml:350-358], opens with
   [Open_wronly; Open_creat; Open_excl] at 0o600 and retries a fresh name up to
   21 times. Measured against a directory with the write bit cleared, it
   returns at once with [Sys_error "<dir>/.bondi-readiness.ea7412: Permission
   denied"], so the reason still names the path the operator has to go and look
   at. *)
let probe_file_prefix = ".bondi-readiness."

(* A file is created in the spool and removed again rather than its mode bits
   being read: what the caller needs to know is whether a crontab can be
   installed here, and the modes only predict that. *)
let crontab_spool_probe dir =
  let outcome =
    match Filename.temp_file ~temp_dir:dir probe_file_prefix "" with
    | exception Sys_error reason -> Error reason
    | path ->
        Fun.protect
          ~finally:(fun () -> remove_quietly path)
          (fun () ->
            match Unix.unlink path with
            | () -> Ok ()
            | exception Unix.Unix_error (error, _, _) ->
                Error (unix_reason path error))
  in
  { probe = Crontab_spool; outcome }

(* The line the probe writes. It is the marker the image gate looks for in
   `docker logs` after running `check`, which is the one observer positioned to
   see whether the line reaches the log stream; that assertion is not this
   module's, and nothing here claims the line arrived anywhere. *)
let sink_marker = "bondi check: diagnostic sink is writable"

(* Opened non-blocking for the reason Diagnostics sets out at length: PID 1's
   stderr is a pipe in the ordinary case, and a reader that has stalled would
   otherwise suspend the process that is trying to report on it. A sink with no
   room for the line is a sink this reports on, never one it waits for.

   EAGAIN is a pass. On the deployed sink -- a pipe -- a write under PIPE_BUF
   that will not fit comes back EAGAIN rather than short, so this is the arm a
   momentarily undrained log stream actually takes. [observed -- 2026-09-07]
   "a full diagnostic sink is not a failure" in [test_readiness_probes.ml] fills
   a fifo to capacity behind a reader that does not drain and then takes this
   probe against it; before this arm existed the probe answered
   [Error "<fifo>: Resource temporarily unavailable"], never a short write.
   Reporting that would put the box on the operator's repair list for being
   briefly behind on its own logs.

   [Diagnostics.write_all] already draws that line, taking EAGAIN as the
   sink not being ready for this line rather than as a sink that cannot be
   written, and the two agree here on purpose: a full pipe is a line dropped,
   never a machine to fix. What the probe asked is whether the sink is there
   and will take bytes, and a pipe with a reader behind it has answered yes.

   A short write is a failure rather than a retry. With EAGAIN accounted for,
   what remains is a sink that took part of a forty-byte line and stopped --
   the regular-file case, a filesystem with no room -- and the probe's question
   is whether the sink takes a line, which that has answered no. *)
let diagnostic_sink_probe path =
  let line = sink_marker ^ "\n" in
  let length = String.length line in
  let outcome =
    match
      Unix.openfile path [ Unix.O_WRONLY; Unix.O_APPEND; Unix.O_NONBLOCK ] 0
    with
    | exception Unix.Unix_error (error, _, _) -> Error (unix_reason path error)
    | fd ->
        Fun.protect
          ~finally:(fun () -> close_quietly fd)
          (fun () ->
            match Unix.write_substring fd line 0 length with
            | exception Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK), _, _)
              ->
                Ok ()
            | exception Unix.Unix_error (error, _, _) ->
                Error (unix_reason path error)
            | written when Int.equal written length -> Ok ()
            | written ->
                Error
                  (Printf.sprintf "%s: wrote %d of %d bytes" path written length))
  in
  { probe = Diagnostic_sink; outcome }

(* The gather, and its only conditional is the spool's: it is probed when the
   deployment says cron is configured, and omitted otherwise. Nothing here
   chooses a verdict -- that is plan, below. Each probe is bound before the list
   is built so the observations are in the order the readings were taken rather
   than in whatever order the constructor happened to evaluate. *)
let observe ~cron_configured ~docker_socket ~spool_dir ~diagnostic_sink =
  let socket = docker_socket_probe docker_socket in
  let spool =
    match cron_configured with
    | true -> [ crontab_spool_probe spool_dir ]
    | false -> []
  in
  let sink = diagnostic_sink_probe diagnostic_sink in
  (socket :: spool) @ [ sink ]

let failed observation =
  match observation.outcome with
  | Ok () -> false
  | Error _ -> true

let plan observations =
  match List.filter failed observations with
  | [] -> Ready
  | _ :: _ as failures -> Not_ready failures

(* The name an operator reads, not the constructor's. It appears in a message
   that is written to a terminal and to the container log, where the reader is
   diagnosing a machine rather than reading OCaml. *)
let probe_name = function
  | Docker_socket -> "docker socket"
  | Crontab_spool -> "crontab spool"
  | Diagnostic_sink -> "diagnostic sink"

(* A passing observation contributes no text. [Not_ready] is documented as
   carrying failures only and [plan] builds it that way, but the type admits a
   passing member, and the honest reading of one is that it has nothing to
   report rather than an empty reason to print. *)
let reasons observations =
  List.filter_map
    (fun observation ->
      match observation.outcome with
      | Ok () -> None
      | Error reason -> Some (probe_name observation.probe ^ ": " ^ reason))
    observations

let error_of_verdict = function
  | Ready -> None
  | Not_ready observations ->
      Some (Handler_error.Not_ready (String.concat "; " (reasons observations)))

(* The key a program reads, which is not the name a person reads: [probe_name]
   above is written into a message an operator finds on their terminal, and this
   is a field in a document a script compares against. They are kept apart
   rather than shared so that rewording the sentence cannot silently rename a
   key. Both are exhaustive over the variant, so a probe added later must answer
   here as well. *)
let probe_key = function
  | Docker_socket -> "docker_socket"
  | Crontab_spool -> "crontab_spool"
  | Diagnostic_sink -> "diagnostic_sink"

(* A failing observation carries its reason and a passing one carries no such
   field, rather than a reason of the empty string: a caller asking why a probe
   failed must not have to tell an empty reason from an absent one. *)
let observation_to_yojson observation =
  let named = [ ("name", `String (probe_key observation.probe)) ] in
  match observation.outcome with
  | Ok () -> `Assoc (named @ [ ("ok", `Bool true) ])
  | Error reason ->
      `Assoc (named @ [ ("ok", `Bool false); ("reason", `String reason) ])

(* [ready] is asked of [plan] rather than recomputed here, so the document and
   the exit code cannot disagree about the same observations. *)
let observations_to_yojson observations : Yojson.Safe.t =
  let ready =
    match plan observations with
    | Ready -> true
    | Not_ready _ -> false
  in
  `Assoc
    [
      ("ready", `Bool ready);
      ("probes", `List (List.map observation_to_yojson observations));
    ]
