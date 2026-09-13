(* A configuration failure is classified here rather than beside the
   configuration, because the class is what both the exit code and, for the
   route-backed subcommands, the HTTP status are chosen from -- and that choice
   belongs with the process boundary that reads it. The value came from whoever
   started the container, not from Bondi, so it is the caller's request that was
   wrong as written. The offending text is carried into the message: it is the
   operator's own environment variable, and a message naming only the variable
   leaves an unsubstituted template indistinguishable from a typo. *)
let handler_error_of_config_error = function
  | Server_config.Invalid_port port ->
      Handler_error.Invalid_request
        (Printf.sprintf "BONDI_SERVER_PORT is not a number: %s" port)

(* The one place an exception that escaped a subcommand's body becomes a failure
   class. The bodies behind the subcommands catch nothing, and say so: under
   Dream an escaping exception was answered by the framework, and classifying it
   there would have changed the body the caller reads.

   A command line has no framework behind it -- it has cmdliner, which for this
   purpose is worse than nothing. [Cmd.eval'] below is called without [~catch]
   and [?catch] defaults to true, so an exception that escapes an evaluated term
   is intercepted and the evaluation returns [Exit.internal_error], which is
   125. [observed -- 2026-09-07] cmdliner 2.1.1's own interface states both: the
   preamble to the evaluation functions lists "[Exit.internal_error] if the
   [~catch] argument is [true] (default) and an uncaught exception is raised",
   and "[internal_error] is [125], an exit status for unexpected internal
   errors" stands beside the code itself; read in
   [_opam/lib/cmdliner/cmdliner.mli] on 2026-09-07. 125 is one of the three
   codes [handler_error.mli] reserves for cmdliner and forbids a failure class
   from taking, because it reports a machine fault as a mistyped command. So the
   uncaught path does not merely leave a misleading code, it leaves one the
   contract says must never occur -- and no failure path may exit with a code
   that was not chosen from its class.

   The class is [Orchestrator_failure], which is what [Deploy.deploy] and
   [Status.report] already answer for the same event, rather than a fourth class
   invented at the boundary. [Eio.Cancel.Cancelled] propagates for the reason
   those two give: a cancelled fiber that returned a value would break
   structured concurrency. [Stdlib.Exit] propagates because an exit taken
   deliberately is not an orchestrator fault; it is not raised by [Stdlib.exit],
   which was checked and does not raise at all.

   The raw backtrace is taken as the handler's first statement, before anything
   that could catch an exception of its own and overwrite it, and is written to
   the diagnostics stream rather than folded into the message: the message is
   returned to the caller and mailed by cron, and a backtrace is for whoever
   reads the container's log. *)
let classified_result body =
  try body () with
  | Eio.Cancel.Cancelled _ as cancelled -> raise cancelled
  | Stdlib.Exit as taken -> raise taken
  | exn ->
      let backtrace = Printexc.get_raw_backtrace () in
      Diagnostics.write
        (Printf.sprintf
           "a subcommand failed with an unhandled exception: %s\n%s"
           (Printexc.to_string exn)
           (Printexc.raw_backtrace_to_string backtrace));
      Error (Handler_error.Orchestrator_failure (Printexc.to_string exn))

(* The whole of a subcommand, classified. [classified_result] covers a body that
   answers a result; this covers everything a term evaluates -- the environment
   [Server.with_environment] builds, which runs [Eio_main.run], creates the
   Docker client and loads the outbound trust store, and the write
   [Cmd_io.status_of] ends with. Neither of those sits inside any body, so a
   wrap that enclosed only the body would leave the same 125 reachable by
   ordinary means.

   That the write can raise at all is [observed -- 2026-09-07] against OCaml
   5.3.0: [print_string] followed by [flush stdout] with file descriptor 1
   closed raises [Sys_error "Bad file descriptor"].

   A reader that goes away used to be a different matter, and no longer is.
   [observed -- 2026-09-11] against this tree, with file descriptors 1 and 2
   pointed at a pipe whose read end had already been closed:
   [print_string "{}"; flush stdout] and
   [prerr_string "boom"; prerr_newline (); flush stderr] each raise
   [Sys_error "Broken pipe"] under [Sys.(set_signal sigpipe Signal_ignore)], and
   each kill the process with shell status 141 -- 128 plus SIGPIPE -- without
   it. The earlier account of this stopped at the second half and concluded that
   a vanished reader was not a code this classification gets to choose. It is
   one now, on every path, because [eval_argv] sets the disposition itself
   rather than inheriting whichever one the action happened to run under.

   The failure is written and its code taken by [Cmd_io.status_of], which is
   where the failure table is already read. The encoder it is given can never be
   applied: the argument is an [Error], so the [Ok] arm is unreachable, and
   [Fun.id] is passed rather than a fabricated encoder for a value that does not
   exist. *)
let classified_status action =
  match classified_result (fun () -> Ok (action ())) with
  | Ok code -> code
  | Error error -> Cmd_io.status_of (Error error) ~encode:Fun.id

(* The failure goes to [Cmd_io.fail] rather than [Cmd_io.status_of], because
   serving has no JSON answer: a success here is a server that ran and stopped,
   and encoding something for it would put bytes on stdout that no caller asked
   for. [Cmd_io.fail] writes stderr and nothing else, so that property survives
   the sharing -- and what is shared is not only the table but the write itself,
   which is the part that would otherwise drift the first time a failure gains a
   prefix or a terminator. *)
let serve_action ~serve () =
  classified_status (fun () ->
      match serve () with
      | Ok () -> 0
      | Error error -> Cmd_io.fail (handler_error_of_config_error error))

let serve_term ~serve = Cmdliner.Term.(const (serve_action ~serve) $ const ())

(* The exit statuses the manual documents. Cmdliner documents its own three and
   no others unless it is handed a list, so without this the only codes an
   operator meets on [--help] are 123 to 125 -- precisely the three
   [handler_error.mli] forbids a failure class from taking, and therefore the
   three this binary never leaves behind on a failure it classified. The rows
   are mapped from [Handler_error.exit_documentation] rather than written here,
   so the numbers in the manual can only be the ones [Handler_error.exit_code]
   chose and a class added later is documented without this file being touched.

   Cmdliner's own rows are kept beside them rather than replaced: a mistyped
   flag is still answered by cmdliner with cmdliner's code, which is what that
   range is reserved for, and [Exit.defaults] is also where 0 is documented. *)
let exits =
  List.map
    (fun (code, doc) -> Cmdliner.Cmd.Exit.info code ~doc)
    Handler_error.exit_documentation
  @ Cmdliner.Cmd.Exit.defaults

(* The version the image was built with. The Dockerfile takes it as a build
   argument, refuses to build without one, and republishes it as [VERSION] in
   the runtime stage, so the running container already carries the one answer to
   "which server is this box running" -- the question the README's recovery
   section is about, and the one an operator asks first. It is read here rather
   than baked into the tree because nothing in the tree holds it: the value
   belongs to the release that built the image, and a second copy kept beside
   the source would be a version this binary claims rather than the one it was
   built from. Outside an image no release built this binary, and the honest
   answer is that the version is not known. *)
let version () = Env.read_string_with_default "VERSION" "unknown"

let serve_cmd ~serve =
  let info =
    Cmdliner.Cmd.info "serve" ~exits
      ~doc:
        "Serve the HTTP API. Also what running the binary with no command does."
  in
  Cmdliner.Cmd.v info (serve_term ~serve)

(* The payload is decoded before any environment is built, and the order is the
   same one [serve] takes with its configuration: a body that cannot be read is
   refused without an Eio runtime, a Docker client and an outbound TLS handler
   having been created for a process that is about to stop. It is also what
   keeps a refusal off the machine entirely, so the refusal path is reachable
   from a test that has no Docker socket to speak of. *)
let deploy_action () =
  classified_status (fun () ->
      match Deploy.decode_input (Cmd_io.read_stdin ()) with
      | Error error ->
          Cmd_io.status_of (Error error)
            ~encode:Deploy.deploy_response_to_yojson
      | Ok input ->
          Server.with_environment (fun ~net ~clock ~client:_ ~deliver:_ ->
              Cmd_io.status_of
                (Deploy.deploy ~clock ~net input)
                ~encode:Deploy.deploy_response_to_yojson))

(* [Run.run] answers a result, so the classification that covers it is
   [classified_result] rather than the whole-term wrap: an exception raised
   while a cron job runs must reach [Cmd_io.status_of] as a failure of the run,
   encoded by the run's own encoder and alerted on like any other, and not as an
   exit code chosen after the encoder was skipped. *)
let run_result ~clock ~client ~net ~deliver body =
  classified_result (fun () -> Run.run ~clock ~client ~net ~deliver body)

(* The body is passed as written, because that is what [Run.run] takes: it
   decodes for itself so that a body which names a job can alert about its own
   refusal. *)
let run_action () =
  classified_status (fun () ->
      let body = Cmd_io.read_stdin () in
      Server.with_environment (fun ~net ~clock ~client ~deliver ->
          Cmd_io.status_of
            (run_result ~clock ~client ~net ~deliver body)
            ~encode:Run.run_response_to_yojson))

(* The selector is an argument rather than a payload: it arrived as a query
   parameter on the route, and a service name is not a credential. Nothing this
   subcommand reads is. *)
let status_action service_name =
  classified_status (fun () ->
      Server.with_environment (fun ~net ~clock ~client ~deliver:_ ->
          Cmd_io.status_of
            (Status.report ~client ~net ~clock ~service_name)
            ~encode:Status.comprehensive_status_to_yojson))

(* Whether the crontab spool is expected to be writable is a property of the
   deployment the caller built this container from, not something the container
   can soundly infer from its own filesystem, so it arrives as an argument.

   The document is written whichever way the verdict went, which is what
   [Cmd_io.diagnostic_of] is for: the three request-answering subcommands write
   stdout on success alone, but the outcome a caller of [check] acts on is the
   failing one, and a script that could only ever read the passing document
   could read nothing it needed. The reasons still go to stderr for the operator
   and the code still comes from [Handler_error], the one table all five ask.
   The gather is a parameter for the reason [readiness.mli] gives: bound to this
   container's paths it reads this container, and bound to a test's paths it
   reads what the test made. *)
let check_action ~observe cron_configured =
  classified_status (fun () ->
      let observations = observe ~cron_configured in
      let verdict =
        match Readiness.error_of_verdict (Readiness.plan observations) with
        | None -> Ok ()
        | Some error -> Error error
      in
      Cmd_io.diagnostic_of verdict
        ~document:(Readiness.observations_to_yojson observations))

let deploy_cmd =
  let info =
    Cmdliner.Cmd.info "deploy" ~exits
      ~doc:"Deploy the payload read on standard input, and write its cron jobs."
  in
  Cmdliner.Cmd.v info Cmdliner.Term.(const deploy_action $ const ())

let run_cmd =
  let info =
    Cmdliner.Cmd.info "run" ~exits
      ~doc:"Run the one cron job described by the payload on standard input."
  in
  Cmdliner.Cmd.v info Cmdliner.Term.(const run_action $ const ())

let service_arg =
  let doc =
    "Report on this service alone. Without it the report covers the box."
  in
  Cmdliner.Arg.(
    value & opt (some string) None & info [ "service" ] ~docv:"NAME" ~doc)

let status_cmd =
  let info =
    Cmdliner.Cmd.info "status" ~exits
      ~doc:"Report what this box is running, as JSON on standard output."
  in
  Cmdliner.Cmd.v info Cmdliner.Term.(const status_action $ service_arg)

let cron_configured_arg =
  let doc =
    "The deployment this container was built from configures cron jobs, so the \
     crontab spool must be writable for the box to be ready."
  in
  Cmdliner.Arg.(value & flag & info [ "cron-configured" ] ~doc)

let check_cmd ~observe =
  let info =
    Cmdliner.Cmd.info "check" ~exits
      ~doc:"Report whether this box is in a state to serve."
  in
  Cmdliner.Cmd.v info
    Cmdliner.Term.(const (check_action ~observe) $ cron_configured_arg)

let group ~serve ~observe =
  let info =
    Cmdliner.Cmd.info "bondi-server" ~exits ~version:(version ())
      ~doc:"The Bondi orchestrator."
  in
  Cmdliner.Cmd.group info ~default:(serve_term ~serve)
    [ serve_cmd ~serve; deploy_cmd; run_cmd; status_cmd; check_cmd ~observe ]

(* The signal disposition every subcommand path runs under, set here because
   here is the single point all of them pass through.

   A client that goes away closes the stream its subcommand was writing to, and
   at SIGPIPE's default disposition the next write kills the process outright:
   the deploy stops wherever it had got to, no failure class is chosen, and
   nothing is left for [bondi status] to recover. Ignoring the signal converts
   that death into a raised [Sys_error] -- which the classification above can
   answer, and which [Diagnostics.write] already swallows. It does not by itself
   make a write harmless, and the two halves are deliberately different: a write
   issued while work is in flight is a diagnostic and is dropped, and the write
   that carries the answer still fails the subcommand, because by then there is
   nothing left to report.

   [observed -- 2026-09-11] against this tree: [Diagnostics.write] into a pipe
   whose read end had already been closed returns normally under
   [Sys.(set_signal sigpipe Signal_ignore)] and kills the process with shell
   status 141 without it. So the disposition, not the writer, was what stood
   between a mid-work diagnostic and a dead process.

   It is not left to [Eio_main.run], which sets the same disposition and never
   restores it -- eio 1.3 does it in both backends, at
   [_opam/lib/eio_posix/eio_posix.ml] line 23 and
   [_opam/lib/eio_linux/eio_linux.ml] line 556, read on 2026-09-11 -- because
   that covers only a path that reaches an environment. [check] builds none;
   [deploy]'s undecodable-payload arm answers before one is built; [serve]'s own
   failure is written after [Eio_main.run] has returned; and cmdliner writes
   [--help], [--version] and its own usage errors before any term is evaluated
   at all.

   Ignored rather than handled, and process-wide rather than set around each
   write, for the reason [diagnostics.mli] gives about itself: the disposition
   is a property of the process, not of a call, and this binary writes from more
   than one fiber. *)
let eval_argv ~serve ~observe ~argv =
  Sys.set_signal Sys.sigpipe Sys.Signal_ignore;
  Cmdliner.Cmd.eval' ~argv (group ~serve ~observe)

(* The paths the container the server runs in actually uses. Each is the one the
   code that owns it exports, never a literal repeated here: the socket the
   Docker client opens, the spool and the crontab file the crontab module
   writes, the stream the diagnostics module duplicates its lines to, and the
   directory the cron payload writer makes a job's files under.

   The gather is taken as an argument rather than named here, and all five paths
   are strings, so a transposed pair type-checks and every unit test that drives
   the group through an injected gather passes -- the fault would surface only
   in the image gate, which needs a Docker Engine and does not run under
   [dune test]. Passing the gather in is what lets a test read back which
   constant landed in which slot. *)
let production_observe ~observe ~cron_configured =
  observe ~cron_configured ~docker_socket:Docker.Client.default_socket_path
    ~spool_dir:Crontab.crontab_spool_dir
    ~diagnostic_sink:Diagnostics.pid_one_stderr
    ~crontab_path:Crontab.crontab_path
    ~payload_dir:Bondi_common.Cron_exec_line.cron_root

let eval () =
  eval_argv ~serve:Server.serve
    ~observe:(production_observe ~observe:Readiness.observe)
    ~argv:Sys.argv
