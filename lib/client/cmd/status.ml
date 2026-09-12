let ( let* ) = Result.bind

type output_format = Table | Json

(* How long one remote read may take before this command reports that the box
   did not answer. Every read [status] makes is a listing, a file, or the
   orchestrator's own account of itself: a box that is answering answers them at
   once, and an operator is waiting on the table while it happens. The read of
   the orchestrator's image tag is not among them -- that one is
   [Orchestrator_version]'s and is held to that module's bound, for the reason
   given there. *)
let read_seconds = 60

(* The command the box runs for a status read: the orchestrator's own binary, as
   a subcommand, inside the container it runs in. The selector is an argument
   because a service name is not a credential -- the one payload this client
   sends that is goes on standard input instead, and that is the deploy's.

   [-i] is the shape every command this client runs inside the orchestrator
   takes, so that a caller reading one of them has read all of them. Nothing is
   written on this one's standard input, which the runner closes at once.

   The [docker] is not spelled here. The runner supplies it, so that no call
   site can spell it differently. *)
let status_exec_command ~service_name =
  Printf.sprintf "exec -i %s bondi-server status%s"
    Bondi_common.Builtin_container.orchestrator
    (match service_name with
    | None -> ""
    | Some name -> " --service " ^ Filename.quote name)

(* Every way a remote read can fail leaves the orchestrator unconsulted, and
   that is what is reported -- including a command that ran on the box and
   failed. A [docker exec] that failed is the box's account of why the
   orchestrator could not be reached: the container is not there, the daemon
   refused, the binary knows no such subcommand. None of those is the
   orchestrator having answered.

   [Status_report] classifies its own failed reads the other way, sending a
   command that ran on the host to [Not_understood], and it is right to: what
   failed there is the read of the host, and the host is the source. Here the
   host is the transport and the orchestrator is the source, so the same failure
   means the opposite thing. [Not_understood] is left to a body that arrived and
   could not be read, which is the one an older client against a newer
   orchestrator produces and the one an operator must be able to tell apart. *)
let not_consulted ~subject failure =
  Status_report.Not_consulted (Remote_exec.explain ~subject failure)

(* What the floor below is decided from, as this command's report words a box it
   could not read. The reading itself is [Orchestrator_version]'s, shared with
   the deploy path rather than spelled a second time here: the two commands hold
   their boxes to the same floor, so a box refused by one has to be refused by
   the other from the same answer. What is not shared is this -- a failed read
   is a source that could not be consulted, which is a cell in a table and not
   the sentence a deploy prints. *)
let reported_orchestrator_version ?session (server : Config_file.server) =
  match Orchestrator_version.read ?session server with
  | Error failure ->
      Error (not_consulted ~subject:"the orchestrator listing" failure)
  | Ok version -> Ok version

(* One server's reading from the orchestrator, over the box's own command
   surface.

   The floor is applied before the subcommand is run rather than after it fails,
   because a binary from before there were subcommands does not fail: it ignores
   the arguments and starts a second server against a port already bound, so a
   caller that asked anyway would spend its whole bound on a command that was
   never going to answer and then report a box that did not respond. A refusal
   is a cell in the report and never an exit -- this command reports on every
   configured server, and a run that stopped at the first old box would lose the
   account of the ones that are fine. *)
let orchestrator_reading ?session ~service_name (server : Config_file.server) =
  let* version = reported_orchestrator_version ?session server in
  let* () =
    match Server_version.answers_command_surface version with
    | Ok () -> Ok ()
    | Error message -> Error (Status_report.Not_consulted message)
  in
  match
    Remote_exec.docker_command_output ?session ~timeout_seconds:read_seconds
      ~command:(status_exec_command ~service_name)
      server
  with
  | Error failure ->
      Error (not_consulted ~subject:"the orchestrator's report" failure)
  | Ok body ->
      Orchestrator_status.reading_of_body ~ip_address:server.ip_address body

let run output_format () =
  match Config_file.read () with
  | Error message ->
      prerr_endline ("Error reading configuration: " ^ message);
      exit 1
  | Ok config -> (
      let service_name =
        match config.user_service with
        | Some service -> Some service.name
        | None -> None
      in
      let reports =
        List.map
          (fun (server : Config_file.server) ->
            let reading ?session () =
              Status_gather.gather ?session ~timeout_seconds:read_seconds
                ~fetch:(orchestrator_reading ?session ~service_name)
                server
            in
            (* This command reports a health state and never waits for one: a
               wait costs a bound per component, and an operator asking what is
               running is not asking anyone to hold still while it settles. *)
            Status_gather.report_of_reading ~config ~address:server.ip_address
              ~waits:[]
              (match
                 Remote_exec.with_session ~timeout_seconds:read_seconds server
                   (fun session -> reading ~session ())
               with
              | Ok taken -> taken
              (* A session that could not be staged is a server with no ssh
                 block, no ssh on this machine, or nowhere to write a key, and
                 every read would have answered with that same failure. The body
                 never ran, so taking the reading without a session is what
                 derives it -- once per read, exactly as it was derived before
                 there was a session to open -- rather than reading anything
                 twice. *)
              | Error _ -> reading ()))
          (Config_file.servers config)
      in
      let output =
        match output_format with
        | Table -> Status_report.render_table reports
        | Json -> Status_report.render_json reports
      in
      match String.equal output "" with
      | true -> ()
      | false -> print_string output)

let output_format_arg =
  let formats = [ ("json", Json); ("table", Table) ] in
  let doc = "Output format. $(docv) must be $(b,json) or $(b,table)." in
  Cmdliner.Arg.(
    value & opt (enum formats) Table & info [ "output" ] ~docv:"VAL" ~doc)

let cmd =
  let term = Cmdliner.Term.(const run $ output_format_arg $ const ()) in
  let info =
    Cmdliner.Cmd.info "status"
      ~doc:"Get the status of deployed components on all configured servers."
  in
  Cmdliner.Cmd.v info term
