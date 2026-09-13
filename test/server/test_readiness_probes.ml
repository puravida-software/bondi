open Alcotest
module Readiness = Bondi_server__Readiness
module String_utils = Bondi_common.String_utils
module Check_marker = Bondi_common.Check_marker

(* Named arm by arm rather than derived, so that a probe added to the variant
   later makes this [function] inexhaustive here — the same guard
   [test_readiness.ml] carries, owed again because this file also enumerates
   the probe set. *)
let probe_name = function
  | Readiness.Docker_socket -> "docker socket"
  | Readiness.Crontab_spool -> "crontab spool"
  | Readiness.Diagnostic_sink -> "diagnostic sink"
  | Readiness.Cron_divergence -> "cron divergence"

let probe_names observations =
  List.map
    (fun (observation : Readiness.observation) -> probe_name observation.probe)
    observations

let outcome_for probe observations =
  List.find_map
    (fun (observation : Readiness.observation) ->
      match String.equal (probe_name observation.probe) (probe_name probe) with
      | true -> Some observation.outcome
      | false -> None)
    observations

let is_ready = function
  | Readiness.Ready -> true
  | Readiness.Not_ready _ -> false

let failing_probe_names = function
  | Readiness.Ready -> []
  | Readiness.Not_ready observations -> probe_names observations

(* The outcome is compared as a name plus, for a failure, the text of the
   reason: the [Unix.error_message] a probe embeds is the platform's string and
   pinning it would be asserting about libc. What is owed is that the probe
   failed and that its reason names the path the operator has to go and look
   at. *)
let check_passed label probe observations =
  match outcome_for probe observations with
  | None -> fail (label ^ ": the probe was not taken at all")
  | Some (Error reason) -> fail (label ^ ": expected a pass, got " ^ reason)
  | Some (Ok ()) -> ()

let check_failed_naming label probe observations ~needle =
  match outcome_for probe observations with
  | None -> fail (label ^ ": the probe was not taken at all")
  | Some (Ok ()) -> fail (label ^ ": expected a failure, got a pass")
  | Some (Error reason) ->
      check bool
        (label ^ ": the reason names " ^ needle)
        true
        (String_utils.contains ~needle reason)

(* Both unwritable arms are permission-triggered, so a suite running as root
   would find every fixture writable and both arms would pass for a reason that
   is about the machine rather than about the probe. Asserted rather than
   skipped: an unwritable arm that silently does not run is the case the 204
   passed. *)
let check_not_root () =
  check bool
    "the suite does not run as root, or the unwritable arms prove nothing" false
    (Int.equal (Unix.geteuid ()) 0)

(* Every fixture below is manufactured by the test and removed by it, on the
   passing and the failing path alike. None of them is the developer's own
   /var/run/docker.sock or /var/spool/cron/crontabs: this box's socket is a
   symlink into /run/host/ and the CI runner's is a real Engine socket, so a
   test that reads either asserts about the machine it happens to run on. *)

let scratch_path prefix suffix =
  let path = Filename.temp_file prefix suffix in
  Sys.remove path;
  path

type fixture = { path : string; remove : unit -> unit }
(** A path the test made, together with the inverse of making it. The removal
    travels with the fixture so that a test cannot construct one and leave the
    teardown to a list written somewhere else. *)

let listening_socket () =
  let path = scratch_path "bondi-readiness-socket" ".sock" in
  let listener = Unix.socket Unix.PF_UNIX Unix.SOCK_STREAM 0 in
  Unix.bind listener (Unix.ADDR_UNIX path);
  Unix.listen listener 1;
  {
    path;
    remove =
      (fun () ->
        Unix.close listener;
        Sys.remove path);
  }

(* A path inside the same temporary directory, created and immediately removed,
   so that a connect to it fails ENOENT as whatever uid the suite runs as.
   Nothing is left behind to remove. *)
let absent_socket () =
  {
    path = scratch_path "bondi-readiness-absent" ".sock";
    remove = (fun () -> ());
  }

let spool_at mode =
  let path = scratch_path "bondi-readiness-spool" "" in
  Unix.mkdir path 0o700;
  Unix.chmod path mode;
  {
    path;
    remove =
      (fun () ->
        Unix.chmod path 0o700;
        Unix.rmdir path);
  }

let writable_spool () = spool_at 0o700
let unwritable_spool () = spool_at 0o500

let sink_at mode =
  let path = Filename.temp_file "bondi-readiness-sink" ".log" in
  Unix.chmod path mode;
  {
    path;
    remove =
      (fun () ->
        Unix.chmod path 0o600;
        Sys.remove path);
  }

let writable_sink () = sink_at 0o600
let unwritable_sink () = sink_at 0o400

(* Writes 4 KiB at a time until the pipe has no room left. It returns only on
   [EAGAIN], so a return is itself the witness that the fifo is full; the byte
   count is returned so the caller can assert the fill did some work rather
   than finding a pipe that refused the very first write. *)
let fill_until_it_would_block fd =
  let block = String.make 4096 'x' in
  let rec loop written =
    match Unix.write_substring fd block 0 (String.length block) with
    | moved -> loop (written + moved)
    | exception Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK), _, _) ->
        written
  in
  loop 0

let drain fd =
  let buffer = Bytes.create 65536 in
  let rec loop read =
    match Unix.read fd buffer 0 (Bytes.length buffer) with
    | 0 -> read
    | moved -> loop (read + moved)
    | exception Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK), _, _) -> read
  in
  loop 0

type fifo = {
  fifo_path : string;
  fill : unit -> int;
  would_block : unit -> bool;
  drained : unit -> int;
}
(** A sink that is a pipe rather than a file, which is what the deployed sink
    is: PID 1's stderr. The reader is held open and never drains on its own, so
    the test decides when the pipe is full and when it is empty. *)

(* Reader first, then writer: a fifo opened O_WRONLY|O_NONBLOCK with no reader
   fails ENXIO, so the order is the fixture's, not a preference. Both
   descriptors and the fifo itself are removed on the failing path as well. *)
let with_fifo body =
  let path = scratch_path "bondi-readiness-fifo" ".fifo" in
  Unix.mkfifo path 0o600;
  Fun.protect
    ~finally:(fun () -> Sys.remove path)
    (fun () ->
      let reader = Unix.openfile path [ Unix.O_RDONLY; Unix.O_NONBLOCK ] 0 in
      Fun.protect
        ~finally:(fun () -> Unix.close reader)
        (fun () ->
          let writer =
            Unix.openfile path [ Unix.O_WRONLY; Unix.O_NONBLOCK ] 0
          in
          Fun.protect
            ~finally:(fun () -> Unix.close writer)
            (fun () ->
              body
                {
                  fifo_path = path;
                  fill = (fun () -> fill_until_it_would_block writer);
                  would_block =
                    (fun () ->
                      match Unix.write_substring writer "x" 0 1 with
                      | _ -> false
                      | exception
                          Unix.Unix_error
                            ((Unix.EAGAIN | Unix.EWOULDBLOCK), _, _) ->
                          true);
                  drained = (fun () -> drain reader);
                })))

(* The fifo owns its own teardown, so the fixture handed to [with_fixtures]
   removes nothing. *)
let fifo_sink fifo () = { path = fifo.fifo_path; remove = (fun () -> ()) }

let read_file path =
  let channel = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in channel)
    (fun () -> really_input_string channel (in_channel_length channel))

type fixtures = { socket : string; spool : string; sink : string }
(** One fixture set per test, every member good unless the test is about that
    member's failure, so the probe under test is the only thing that can move.
*)

(* Nested rather than a teardown list, so that each fixture made is removed on
   the passing path and the failing path alike, and a removal that itself
   fails still leaves the ones outside it to run. *)
let with_fixtures ~socket ~spool ~sink body =
  let socket = socket () in
  Fun.protect ~finally:socket.remove (fun () ->
      let spool = spool () in
      Fun.protect ~finally:spool.remove (fun () ->
          let sink = sink () in
          Fun.protect ~finally:sink.remove (fun () ->
              body
                { socket = socket.path; spool = spool.path; sink = sink.path })))

(* The divergence probe's own arms belong to [test_readiness.ml], which builds
   the two sources it compares. Here both are named as paths nothing made, which
   the probe reads as a host with no crontab and no payload directory -- two
   answers that agree -- so it passes and leaves this file's three subjects the
   only things that can move. *)
let absent_crontab = scratch_path "bondi-absent-crontab" ""
let absent_payload_dir = scratch_path "bondi-absent-payload" ""

let observe ~cron_configured fixtures =
  Readiness.observe ~cron_configured ~docker_socket:fixtures.socket
    ~spool_dir:fixtures.spool ~diagnostic_sink:fixtures.sink
    ~crontab_path:absent_crontab ~payload_dir:absent_payload_dir

let test_an_openable_socket_path_passes () =
  with_fixtures ~socket:listening_socket ~spool:writable_spool
    ~sink:writable_sink (fun fixtures ->
      let observations = observe ~cron_configured:true fixtures in
      check_passed "a socket with a listener on it" Readiness.Docker_socket
        observations)

(* The negative arm names the socket rather than the box: the path is one the
   test made and removed, so the connect fails ENOENT wherever the suite runs.
   The other two probes are asserted to have passed in the same run, so the
   failure is attributed to the socket rather than being a run in which
   everything failed. *)
let test_an_absent_socket_path_fails () =
  with_fixtures ~socket:absent_socket ~spool:writable_spool ~sink:writable_sink
    (fun fixtures ->
      let observations = observe ~cron_configured:true fixtures in
      check_failed_naming "a socket path with nothing at it"
        Readiness.Docker_socket observations ~needle:fixtures.socket;
      check_passed "and the spool probe is unaffected" Readiness.Crontab_spool
        observations;
      check_passed "and so is the sink probe" Readiness.Diagnostic_sink
        observations)

(* A spool the probe can write is a spool the probe leaves as it found it: the
   temporary file it creates has to be gone afterwards, or the next deploy's
   crontab write finds litter it did not put there. [Unix.rmdir] in the
   teardown fails on a non-empty directory, so the leak would surface, but the
   assertion is made here where it names what went wrong. *)
let test_a_writable_spool_passes () =
  with_fixtures ~socket:listening_socket ~spool:writable_spool
    ~sink:writable_sink (fun fixtures ->
      let observations = observe ~cron_configured:true fixtures in
      check_passed "a spool directory that can be written"
        Readiness.Crontab_spool observations;
      check (list string) "and the probe removed what it wrote" []
        (Array.to_list (Sys.readdir fixtures.spool)))

(* The wedge this guards: a run killed between creating the probe file and
   removing it leaves the file behind, and a probe whose name is derived from
   the pid alone chooses that same name again as soon as a pid is reused --
   which inside a long-lived container, where [check] is a short-lived process
   landing on recycled low pids, is ordinary rather than exotic. The spool is
   perfectly writable and would be reported as unwritable.

   The file planted here is the name the pid-derived scheme would have used.
   The probe has to pass over it, and to leave it exactly where it found it:
   [O_EXCL] exists so the probe can never truncate something it did not make,
   and the assertion below is what holds that promise to a file that is in the
   way. *)
let test_a_leftover_probe_file_does_not_wedge_the_spool () =
  with_fixtures ~socket:listening_socket ~spool:writable_spool
    ~sink:writable_sink (fun fixtures ->
      let leftover =
        Filename.concat fixtures.spool
          (Printf.sprintf ".bondi-readiness.%d" (Unix.getpid ()))
      in
      close_out (open_out leftover);
      Fun.protect
        ~finally:(fun () -> Sys.remove leftover)
        (fun () ->
          let observations = observe ~cron_configured:true fixtures in
          check_passed "a spool holding a leftover from an interrupted run"
            Readiness.Crontab_spool observations;
          check (list string)
            "and the probe removed its own file and left the stranger's"
            [ Filename.basename leftover ]
            (Array.to_list (Sys.readdir fixtures.spool))))

let test_an_unwritable_spool_fails () =
  check_not_root ();
  with_fixtures ~socket:listening_socket ~spool:unwritable_spool
    ~sink:writable_sink (fun fixtures ->
      let observations = observe ~cron_configured:true fixtures in
      check_failed_naming "a spool directory with the write bit cleared"
        Readiness.Crontab_spool observations ~needle:fixtures.spool;
      (* The leading dot is load-bearing rather than cosmetic -- cron skips
         spool entries whose name begins with one, so the probe file is never
         read as a crontab in the window it exists -- and it is invisible
         everywhere else, because a passing probe removes the file before
         anything can look at it. This failure names the path it could not
         create, which is the one place the name is observable. *)
      check_failed_naming "and the file it could not create is dot-prefixed"
        Readiness.Crontab_spool observations
        ~needle:(Filename.concat fixtures.spool ".bondi-readiness");
      check_passed "and the socket probe is unaffected" Readiness.Docker_socket
        observations;
      check_passed "and so is the sink probe" Readiness.Diagnostic_sink
        observations)

(* The sink probe establishes that the sink is writable and emits its marker.
   Whether that marker reaches the container log stream is not asserted here
   and is not claimed anywhere: that needs an observer outside the container. *)
let test_a_writable_diagnostic_sink_passes () =
  with_fixtures ~socket:listening_socket ~spool:writable_spool
    ~sink:writable_sink (fun fixtures ->
      let observations = observe ~cron_configured:true fixtures in
      check_passed "a sink that can be opened for writing"
        Readiness.Diagnostic_sink observations;
      let written = read_file fixtures.sink in
      check bool "and the probe wrote a line to it, terminated" true
        (String.length written > 0 && String.ends_with ~suffix:"\n" written))

(* The line the probe appends is the shared one, byte for byte, and not a
   literal kept beside the probe. Two parties match on this string -- the
   process that writes it and a reader outside the container that greps the log
   stream for it -- and a divergence between them is silent at both ends: the
   write succeeds and the reader simply never matches. The terminator is the
   writer's, so the shared value plus one newline is the whole of what lands. *)
let test_the_sink_probe_writes_the_shared_marker () =
  with_fixtures ~socket:listening_socket ~spool:writable_spool
    ~sink:writable_sink (fun fixtures ->
      let observations = observe ~cron_configured:true fixtures in
      check_passed "the sink probe ran" Readiness.Diagnostic_sink observations;
      check string "and wrote the shared marker, terminated"
        (Check_marker.diagnostic_sink ^ "\n")
        (read_file fixtures.sink))

let test_an_unwritable_diagnostic_sink_fails () =
  check_not_root ();
  with_fixtures ~socket:listening_socket ~spool:writable_spool
    ~sink:unwritable_sink (fun fixtures ->
      let observations = observe ~cron_configured:true fixtures in
      check_failed_naming "a sink file with the write bit cleared"
        Readiness.Diagnostic_sink observations ~needle:fixtures.sink;
      check_passed "and the socket probe is unaffected" Readiness.Docker_socket
        observations;
      check_passed "and so is the spool probe" Readiness.Crontab_spool
        observations)

(* The deployed sink is a pipe, and a pipe whose reader is momentarily behind
   refuses a write under PIPE_BUF with [EAGAIN] rather than taking part of it.
   That is the sink being unready for this line, not a sink that cannot be
   written -- the same reading [Diagnostics.write_all] takes, where [EAGAIN] is
   [Not_ready] and the line is dropped rather than the process blocked -- so the
   probe passes.

   Both arms run against one fifo. The drained arm proves the fixture reaches
   the probe at all and that the marker lands in the pipe; without it, a fifo
   that had quietly stopped being probed would pass the full arm for the wrong
   reason. The full arm asserts the pipe is genuinely full at the moment the
   probe is taken rather than trusting the fill to have worked. *)
let test_a_full_diagnostic_sink_is_not_a_failure () =
  with_fifo (fun fifo ->
      with_fixtures ~socket:listening_socket ~spool:writable_spool
        ~sink:(fifo_sink fifo) (fun fixtures ->
          let drained = observe ~cron_configured:true fixtures in
          check_passed "a fifo with a reader on it" Readiness.Diagnostic_sink
            drained;
          check bool "and the marker reached the reader" true
            (fifo.drained () > 0);
          let filled = fifo.fill () in
          check bool "the fill moved bytes into the pipe" true (filled > 0);
          check bool "and the pipe has no room left for the marker" true
            (fifo.would_block ());
          let full = observe ~cron_configured:true fixtures in
          check_passed "a fifo whose reader is behind" Readiness.Diagnostic_sink
            full;
          check bool "so the box is not reported as one to repair" true
            (is_ready (Readiness.plan full))))

(* Two behaviours in one fixture: an unwritable spool fails the check, and the
   spool is not probed at all when cron is unconfigured. The spool is
   unwritable in both runs and the flag is the only thing that differs, so the
   absence below cannot be a fixture that stopped reaching the code: the
   affirmative arm on the same directory produces the observation and the
   verdict that names it.

   This is also the test that composes the real probes with the real [plan] —
   probes checked against a hand-built verdict and a verdict checked against
   hand-built probes would leave the join covered by nothing. *)
let test_the_spool_is_not_probed_when_cron_is_unconfigured () =
  check_not_root ();
  with_fixtures ~socket:listening_socket ~spool:unwritable_spool
    ~sink:writable_sink (fun fixtures ->
      let without_cron = observe ~cron_configured:false fixtures in
      check (list string) "the spool is not among the probes taken"
        [ "docker socket"; "diagnostic sink" ]
        (probe_names without_cron);
      check bool "and a probe not taken is not a probe that failed" true
        (is_ready (Readiness.plan without_cron));
      let with_cron = observe ~cron_configured:true fixtures in
      check (list string) "the same box with cron configured does probe it"
        [
          "docker socket"; "crontab spool"; "cron divergence"; "diagnostic sink";
        ]
        (probe_names with_cron);
      check (list string) "and the unwritable spool is what the verdict names"
        [ "crontab spool" ]
        (failing_probe_names (Readiness.plan with_cron)))

let () =
  run "readiness_probes"
    [
      ( "docker socket",
        [
          test_case "an openable socket path passes" `Quick
            test_an_openable_socket_path_passes;
          test_case "an absent socket path fails" `Quick
            test_an_absent_socket_path_fails;
        ] );
      ( "crontab spool",
        [
          test_case "a writable spool passes" `Quick
            test_a_writable_spool_passes;
          test_case "an unwritable spool fails" `Quick
            test_an_unwritable_spool_fails;
          test_case "a leftover probe file does not wedge the spool" `Quick
            test_a_leftover_probe_file_does_not_wedge_the_spool;
          test_case "the spool is not probed when cron is unconfigured" `Quick
            test_the_spool_is_not_probed_when_cron_is_unconfigured;
        ] );
      ( "diagnostic sink",
        [
          test_case "a writable diagnostic sink passes" `Quick
            test_a_writable_diagnostic_sink_passes;
          test_case "the sink probe writes the shared marker" `Quick
            test_the_sink_probe_writes_the_shared_marker;
          test_case "an unwritable diagnostic sink fails" `Quick
            test_an_unwritable_diagnostic_sink_fails;
          test_case "a full diagnostic sink is not a failure" `Quick
            test_a_full_diagnostic_sink_is_not_a_failure;
        ] );
    ]
