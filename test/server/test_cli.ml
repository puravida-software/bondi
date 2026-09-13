open Alcotest
module Cli = Bondi_server__Cli
module Crontab = Bondi_server__Crontab
module Diagnostics = Bondi_server__Diagnostics
module Docker_client = Bondi_server__Docker__Client
module Handler_error = Bondi_server__Handler_error
module Readiness = Bondi_server__Readiness
module Server_config = Bondi_server__Server_config
module Readiness_exit_code = Bondi_common.Readiness_exit_code
module String_utils = Bondi_common.String_utils

(* The command group is exercised with an explicit argv, an explicit serve
   action and an explicit readiness gather, which is the only way the questions
   these tests ask can be asked at all: [Cli.eval] reads this process's own
   argv -- Alcotest's -- the real serve binds a port and does not return, and
   the real gather probes the Docker socket and PID 1 of whichever box is
   running the suite. The subject is still the group that ships; only its three
   inputs are supplied by the test. *)
(* An observe that fails the case that reaches it. Every term but [check] must
   leave the machine alone, and a term that probed a socket here would be
   asserting about whichever box ran the suite. *)
let unused_observe ~cron_configured:_ =
  fail "no term but check may observe readiness"

let evaluate ?(observe = unused_observe) ~serve argv =
  Cli.eval_argv ~serve ~observe ~argv

(* A serve that records that it ran. The recording is what "which term was
   evaluated" means here: an exit code alone cannot tell a serve that returned
   zero from a group that quietly did nothing. *)
let recording_serve () =
  let evaluated = ref false in
  let serve () =
    evaluated := true;
    Ok ()
  in
  (serve, evaluated)

let test_no_arguments_evaluates_serve () =
  let serve, evaluated = recording_serve () in
  let code = evaluate ~serve [| "bondi-server" |] in
  check bool "empty argv evaluated the serve term" true !evaluated;
  check int "a serve that returned exits zero" 0 code

let test_the_serve_subcommand_evaluates_serve () =
  let serve, evaluated = recording_serve () in
  let code = evaluate ~serve [| "bondi-server"; "serve" |] in
  check bool "the named serve subcommand evaluated the serve term" true
    !evaluated;
  check int "a serve that returned exits zero" 0 code

(* The affirmative arm for this absence is the two cases above: they show the
   group evaluates serve when it should, so a group that evaluated nothing at
   all could not pass the file. The exit code is asserted too, and asserted as
   "not success" rather than against cmdliner's own number, which is a property
   of the library version rather than of this group. *)
let test_an_unknown_subcommand_does_not_evaluate_serve () =
  let serve, evaluated = recording_serve () in
  let code = evaluate ~serve [| "bondi-server"; "not-a-command" |] in
  check bool "an unknown subcommand did not evaluate the serve term" false
    !evaluated;
  check bool "an unknown subcommand does not exit zero" true (code <> 0)

(* A server that cannot read its own port configuration used to print to stderr
   and fall off the end of main, exiting 0 -- a container the runtime would
   treat as having done its job. The code comes from the one failure table. *)
let test_a_configuration_failure_does_not_exit_zero () =
  let serve () = Error (Server_config.Invalid_port "not-a-number") in
  let code = evaluate ~serve [| "bondi-server" |] in
  check int "a port that was wrong as written exits 2" 2 code

(* The subcommands write to this process's own stdout and stderr and read its
   stdin, because their caller is a shell holding file descriptors 0, 1 and 2.
   The descriptors are therefore where the test supplies and captures them, and
   they are restored under [Fun.protect]: a case that raised while fd 1 pointed
   at a temporary file would send every later Alcotest line there. *)
let read_file path = In_channel.with_open_bin path In_channel.input_all

let with_streams ~stdin_contents f =
  let in_path = Filename.temp_file "bondi_cli_stdin" ".json" in
  Out_channel.with_open_bin in_path (fun oc ->
      Out_channel.output_string oc stdin_contents);
  let out_path = Filename.temp_file "bondi_cli_stdout" ".json" in
  let err_path = Filename.temp_file "bondi_cli_stderr" ".txt" in
  let in_fd = Unix.openfile in_path [ Unix.O_RDONLY ] 0o600 in
  let out_fd = Unix.openfile out_path [ Unix.O_WRONLY; Unix.O_TRUNC ] 0o600 in
  let err_fd = Unix.openfile err_path [ Unix.O_WRONLY; Unix.O_TRUNC ] 0o600 in
  let saved_in = Unix.dup Unix.stdin in
  let saved_out = Unix.dup Unix.stdout in
  let saved_err = Unix.dup Unix.stderr in
  flush stdout;
  flush stderr;
  Unix.dup2 in_fd Unix.stdin;
  Unix.dup2 out_fd Unix.stdout;
  Unix.dup2 err_fd Unix.stderr;
  let restore () =
    flush stdout;
    flush stderr;
    Unix.dup2 saved_in Unix.stdin;
    Unix.dup2 saved_out Unix.stdout;
    Unix.dup2 saved_err Unix.stderr;
    List.iter Unix.close
      [ saved_in; saved_out; saved_err; in_fd; out_fd; err_fd ]
  in
  let value = Fun.protect ~finally:restore f in
  let written_out = read_file out_path in
  let written_err = read_file err_path in
  List.iter Sys.remove [ in_path; out_path; err_path ];
  (value, written_out, written_err)

let run_cli ?observe ~stdin_contents argv =
  let serve () = fail "no payload subcommand may evaluate the serve term" in
  with_streams ~stdin_contents (fun () -> evaluate ?observe ~serve argv)

(* The message carries the offending text as well as the variable's name, and
   that is asserted rather than argued: the operator wrote the value, and a
   sentence naming only [BONDI_SERVER_PORT] leaves an unsubstituted template
   indistinguishable from a typo. The two values below are exactly that pair,
   and each must appear in the sentence its own run produced -- which is what
   makes this an assertion that the value was substituted rather than that the
   sentence mentions a port at all. *)
let test_a_configuration_failure_names_the_value_it_refused () =
  let refuse value () = Error (Server_config.Invalid_port value) in
  let typo_code, typo_out, typo_err =
    with_streams ~stdin_contents:"" (fun () ->
        evaluate ~serve:(refuse "not-a-number") [| "bondi-server" |])
  in
  check int "a port that was wrong as written exits 2" 2 typo_code;
  check string "a failure writes nothing to stdout" "" typo_out;
  check bool "the variable the operator set is named" true
    (String_utils.contains ~needle:"BONDI_SERVER_PORT" typo_err);
  check bool "the value it carried is named beside it" true
    (String_utils.contains ~needle:"not-a-number" typo_err);
  let _, _, template_err =
    with_streams ~stdin_contents:"" (fun () ->
        evaluate ~serve:(refuse "${PORT}") [| "bondi-server" |])
  in
  check bool "an unsubstituted template is not reported as a typo" true
    (String_utils.contains ~needle:"${PORT}" template_err);
  check bool "the other run's value is not in this run's sentence" false
    (String_utils.contains ~needle:"not-a-number" template_err)

(* Both payloads below are refused before the term reaches Docker or Eio: one
   is not JSON at all and the other is JSON whose [image] is a number. That is
   deliberate -- a payload that decoded would deploy against whatever engine the
   suite's machine has. The two produce different sentences, which is what makes
   this an assertion that the bytes on stdin were read rather than that deploy
   fails for any input. *)
let test_deploy_reads_its_payload_from_stdin () =
  let code, written_out, written_err =
    run_cli ~stdin_contents:{|{"image": 5}|} [| "bondi-server"; "deploy" |]
  in
  check int "a payload that was wrong as written exits 2" 2 code;
  check string "a failure writes nothing to stdout" "" written_out;
  check bool "the payload on stdin is what was refused" true
    (String_utils.contains ~needle:"invalid deploy payload" written_err);
  let code, _, written_err =
    run_cli ~stdin_contents:"not json at all" [| "bondi-server"; "deploy" |]
  in
  check int "a body that is not JSON exits 2 as well" 2 code;
  check bool "the other body on stdin produced the other sentence" true
    (String_utils.contains ~needle:"invalid JSON" written_err)

(* The absence this asserts -- that argv is not a payload channel -- has the
   case above as its affirmative arm: stdin demonstrably reaches the decoder,
   and the same bytes in argv demonstrably do not. A payload carries registry
   credentials, and argv is readable by every process on the box. *)
let test_a_payload_in_argv_is_not_read_as_a_payload () =
  let code, _, written_err =
    run_cli ~stdin_contents:"" [| "bondi-server"; "deploy"; {|{"image": 5}|} |]
  in
  check bool "a payload offered in argv does not exit zero" true (code <> 0);
  check bool "the argv payload never reached the decoder" false
    (String_utils.contains ~needle:"invalid deploy payload" written_err)

let passing probe = { Readiness.probe; outcome = Ok () }
let failing probe reason = { Readiness.probe; outcome = Error reason }

(* Whether the crontab spool is expected to be writable is the deployment's
   answer, not the container's, so it arrives as an argument -- and the
   assertion is that the argument reaches the gather, not that cmdliner parsed
   it. Both values are asserted: false is also the flag's default, so a term
   that dropped the flag would pass an assertion made only on the absent case.
   The ready arm's stdout is asserted here too, because that is the document
   this subcommand ships. *)
let test_check_takes_whether_cron_is_configured_as_an_argument () =
  let recorded = ref None in
  let observe ~cron_configured =
    recorded := Some cron_configured;
    [ passing Readiness.Docker_socket; passing Readiness.Diagnostic_sink ]
  in
  let code, written_out, _ =
    run_cli ~observe ~stdin_contents:"" [| "bondi-server"; "check" |]
  in
  check (option bool) "no flag means the deployment configured no cron"
    (Some false) !recorded;
  check int "a ready box exits zero" 0 code;
  check string "the verdict is on stdout"
    {|{"ready":true,"probes":[{"name":"docker_socket","ok":true},{"name":"diagnostic_sink","ok":true}]}|}
    written_out;
  let code, _, _ =
    run_cli ~observe ~stdin_contents:""
      [| "bondi-server"; "check"; "--cron-configured" |]
  in
  check (option bool) "the flag reaches the gather that runs the spool probe"
    (Some true) !recorded;
  check int "a ready box exits zero with the flag too" 0 code

(* The class check adds to the surface. The message names every failing probe
   rather than the first, because a box with two faults that reports one costs
   a second trip to a machine the operator had to reach.

   The document is on stdout here as well as on the ready arm above, and that
   is the case a program needs: a script polling this subcommand compares the
   document it gets, and a box that cannot serve is the only state it has to
   act on. Writing the reasons to stderr alone would leave the machine-readable
   report of a failure -- every failing probe, named -- reachable from no
   caller at all. *)
let test_check_reports_every_failing_probe_and_exits_three () =
  let observe ~cron_configured:_ =
    [
      failing Readiness.Docker_socket "/var/run/docker.sock: No such file";
      passing Readiness.Crontab_spool;
      failing Readiness.Diagnostic_sink "/proc/1/fd/2: Permission denied";
    ]
  in
  let code, written_out, written_err =
    run_cli ~observe ~stdin_contents:""
      [| "bondi-server"; "check"; "--cron-configured" |]
  in
  check int "a box that cannot serve exits 3" 3 code;
  check string "the failing document is on stdout, every probe included"
    {|{"ready":false,"probes":[{"name":"docker_socket","ok":false,"reason":"/var/run/docker.sock: No such file"},{"name":"crontab_spool","ok":true},{"name":"diagnostic_sink","ok":false,"reason":"/proc/1/fd/2: Permission denied"}]}|}
    written_out;
  check bool "the socket failure is named" true
    (String_utils.contains ~needle:"/var/run/docker.sock: No such file"
       written_err);
  check bool "the sink failure is named too" true
    (String_utils.contains ~needle:"/proc/1/fd/2: Permission denied" written_err)

(* The probe the box can take and the client cannot. What is asserted is that it
   reaches both of the channels [check] answers on: the document a program
   compares, under its own key, and the exit code.

   The code is compared against [Readiness_exit_code.not_ready] rather than
   against the number, and that is the point of the case. The client reads the
   remote status to classify the reading, and a second table here -- even one
   holding the same number today -- is a table that can come to disagree with
   the one the client reads. There is one, and this is the arm that says so.

   The reason is a sentence [Bondi_common.Cron_divergence] writes, which is
   where its wording is pinned; here it is carried through unaltered, so a
   handler that summarised it would be caught. *)
let test_check_reports_the_divergence_in_its_document_and_its_code () =
  let reason =
    Bondi_common.Cron_divergence.remedy
      ~crontab_path:"/var/spool/cron/crontabs/root"
      ~payload_dir:"/etc/bondi/cron"
      (Bondi_common.Cron_divergence.Files_without_a_line { job = "backup" })
  in
  let observe ~cron_configured:_ =
    [
      passing Readiness.Docker_socket;
      passing Readiness.Crontab_spool;
      failing Readiness.Cron_divergence reason;
      passing Readiness.Diagnostic_sink;
    ]
  in
  let code, written_out, written_err =
    run_cli ~observe ~stdin_contents:""
      [| "bondi-server"; "check"; "--cron-configured" |]
  in
  check int
    "the code is the readiness class's, from the one table that holds it"
    Readiness_exit_code.not_ready code;
  check string
    "the document names the probe under its own key and carries its reason"
    (Printf.sprintf
       {|{"ready":false,"probes":[{"name":"docker_socket","ok":true},{"name":"crontab_spool","ok":true},{"name":"cron_divergence","ok":false,"reason":%s},{"name":"diagnostic_sink","ok":true}]}|}
       (Yojson.Safe.to_string (`String reason)))
    written_out;
  check bool "the operator is told what closes it, in the probe's own words"
    true
    (String_utils.contains ~needle:reason written_err)

(* A distinct heap value rather than a nullary exception, so that a propagation
   assertion below can say the exact value came back: a constructor with no
   argument is a shared atom and [==] against it is true even of a value the
   handler took apart and rebuilt. *)
exception Sentinel of string

let sentinel = Sentinel "the body raised"

(* [Cmd.eval'] is called without [~catch] and [?catch] defaults to true, so an
   exception that escapes an evaluated term is intercepted by cmdliner and the
   evaluation returns [Exit.internal_error], which is 125 -- one of the three
   codes [handler_error.mli] reserves for cmdliner and forbids a failure class
   from taking, because it reports a machine fault as a mistyped command. Every
   subcommand's body must therefore be classified before it reaches the group.

   The assertion is the orchestrator-failure code rather than "not 125", so a
   term that swallowed the exception and exited 0 could not pass it either. *)
let test_a_body_that_raises_exits_with_its_class_s_code () =
  let observe ~cron_configured:_ = raise sentinel in
  let code, written_out, written_err =
    run_cli ~observe ~stdin_contents:"" [| "bondi-server"; "check" |]
  in
  check int "an exception that escaped check exits 1" 1 code;
  check string "a failure writes nothing to stdout" "" written_out;
  check bool "the exception is named where the operator reads it" true
    (String_utils.contains ~needle:"the body raised" written_err)

(* Serving is the fifth term and the one the image's entrypoint evaluates, so
   the same classification covers it: a trust store that cannot be loaded or an
   Eio backend that will not start is a machine fault, not a mistyped command. *)
let test_a_serve_that_raises_exits_with_its_class_s_code () =
  let serve () = raise sentinel in
  let code, _, written_err =
    with_streams ~stdin_contents:"" (fun () ->
        evaluate ~serve [| "bondi-server" |])
  in
  check int "an exception that escaped serve exits 1" 1 code;
  check bool "the exception is named where the operator reads it" true
    (String_utils.contains ~needle:"the body raised" written_err)

(* The two cases above reach the classification through the group, which is how
   it ships. The cases below reach it directly, because the arms that make it
   correct are not reachable any other way: a cancellation is raised by an Eio
   scheduler tearing a fiber down and [Stdlib.Exit] by a body that meant to
   stop, and a test that had to arrange either through a real Docker socket
   would be asserting about the machine that ran it. Both are supplied as the
   body instead.

   [with_streams] is used only to keep the diagnostic line and the failure
   message off the suite's own stderr; what is asserted is the value that came
   back. *)
let classify_result body =
  let outcome, _, written_err =
    with_streams ~stdin_contents:"" (fun () ->
        match Cli.classified_result body with
        | Ok () -> `Returned "a value"
        | Error error -> `Returned (Handler_error.message error)
        | exception exn -> `Raised exn)
  in
  (outcome, written_err)

let test_classified_result_answers_an_escaping_exception_as_a_failure () =
  let outcome, written_err = classify_result (fun () -> raise sentinel) in
  (match outcome with
  | `Returned message ->
      check bool "the failure carries the exception's own text" true
        (String_utils.contains ~needle:"the body raised" message)
  | `Raised _ -> fail "an ordinary exception must not escape the classification");
  check bool "the backtrace went to the diagnostics stream" true
    (String_utils.contains ~needle:"unhandled exception" written_err)

(* The exact value is asserted, not merely its shape: a classification that
   caught the cancellation and raised one of its own would satisfy a shape
   assertion while having already broken the fiber's teardown. [Sentinel]
   carries an argument so that it is a distinct heap block and [==] means
   something. *)
let test_classified_result_propagates_a_cancellation () =
  let outcome, _ =
    classify_result (fun () -> raise (Eio.Cancel.Cancelled sentinel))
  in
  match outcome with
  | `Raised (Eio.Cancel.Cancelled cause) ->
      check bool "the cancellation came back carrying its own cause" true
        (cause == sentinel)
  | `Raised exn ->
      fail
        (Printf.sprintf "a cancellation was replaced by %s"
           (Printexc.to_string exn))
  | `Returned message ->
      fail
        (Printf.sprintf
           "a cancelled fiber was answered with %S rather than being torn down"
           message)

let test_classified_result_propagates_a_deliberate_exit () =
  let outcome, _ = classify_result (fun () -> raise Stdlib.Exit) in
  match outcome with
  | `Raised Stdlib.Exit -> ()
  | `Raised exn ->
      fail
        (Printf.sprintf "a deliberate exit was replaced by %s"
           (Printexc.to_string exn))
  | `Returned message ->
      fail
        (Printf.sprintf
           "a deliberate exit was reported as the orchestrator's fault: %S"
           message)

(* The affirmative arm for the three cases below: a wrap that swallowed every
   action and answered a constant would pass the failure cases on its own. *)
let test_classified_status_returns_the_code_the_action_chose () =
  check int "an action that returned keeps its code" 3
    (Cli.classified_status (fun () -> 3))

let test_classified_status_codes_an_escaping_exception_from_its_class () =
  let code, written_out, written_err =
    with_streams ~stdin_contents:"" (fun () ->
        Cli.classified_status (fun () -> raise sentinel))
  in
  check int "the code is the orchestrator-failure code" 1 code;
  check string "a failure writes nothing to stdout" "" written_out;
  check bool "the exception is named where the operator reads it" true
    (String_utils.contains ~needle:"the body raised" written_err)

let test_classified_status_propagates_a_cancellation () =
  let outcome, _, _ =
    with_streams ~stdin_contents:"" (fun () ->
        match
          Cli.classified_status (fun () ->
              raise (Eio.Cancel.Cancelled sentinel))
        with
        | code -> `Returned code
        | exception exn -> `Raised exn)
  in
  match outcome with
  | `Raised (Eio.Cancel.Cancelled cause) ->
      check bool "the cancellation came back carrying its own cause" true
        (cause == sentinel)
  | `Raised exn ->
      fail
        (Printf.sprintf "a cancellation was replaced by %s"
           (Printexc.to_string exn))
  | `Returned code ->
      fail (Printf.sprintf "a cancelled fiber became exit code %d" code)

(* [--help] is where an operator meets the exit table, and cmdliner documents
   only its own three codes unless told otherwise. The assertion iterates
   [Handler_error.exit_documentation] rather than naming 1, 2 and 3, so a class
   added to the failure vocabulary is documented by the same assertion rather
   than owing a new one -- and so the numbers here can only be the ones
   [Handler_error.exit_code] chose.

   Whitespace is collapsed before the match because the man page indents and
   wraps its exit-status entries, and both are cmdliner's own rendering rather
   than anything this group decides. Nothing beyond the code and this project's
   own sentence is asserted: the surrounding section title and the codes
   cmdliner adds for itself change with the library's version.

   Every page in the group is checked, not just the group's own, because a
   caller who ran [bondi-server check] reads [bondi-server check --help]. *)
let test_help_documents_the_codes_a_failure_leaves_behind () =
  let page argv =
    let serve () = fail "asking for help must not evaluate the serve term" in
    with_streams ~stdin_contents:"" (fun () -> evaluate ~serve argv)
  in
  List.iter
    (fun command ->
      let argv =
        Array.of_list (("bondi-server" :: command) @ [ "--help=plain" ])
      in
      let code, written_out, _ = page argv in
      let where = String.concat " " ("bondi-server" :: command) in
      check int (where ^ " --help exits zero") 0 code;
      let rendered = String_utils.single_line written_out in
      List.iter
        (fun (exit_code, doc) ->
          check bool
            (Printf.sprintf "%s --help documents exit %d" where exit_code)
            true
            (String_utils.contains
               ~needle:(Printf.sprintf "%d %s" exit_code doc)
               rendered))
        Handler_error.exit_documentation)
    [ []; [ "serve" ]; [ "deploy" ]; [ "run" ]; [ "status" ]; [ "check" ] ]

(* The version an operator asks for is the one the image was built with, and the
   image publishes it as [VERSION] in the runtime stage. Setting it here is what
   makes this an assertion that the group reads that variable rather than that
   it prints some string: a group that hard-coded a version would report the
   hard-coded one. *)
let test_the_group_reports_the_version_the_image_baked () =
  Unix.putenv "VERSION" "9.9.9-from-the-test";
  let serve () = fail "asking for the version must not evaluate serve" in
  let code, written_out, _ =
    with_streams ~stdin_contents:"" (fun () ->
        evaluate ~serve [| "bondi-server"; "--version" |])
  in
  check int "--version exits zero" 0 code;
  check string "the version the image baked is the version reported"
    "9.9.9-from-the-test" (String.trim written_out)

(* The three probe paths are the reason [Diagnostics.pid_one_stderr] is exported
   at all, and every one of them is a string: a transposed pair type-checks, and
   would be found by nothing under [dune test] -- only by the image gate, which
   needs a Docker Engine and does not run there. The gather is supplied here so
   that what each slot received can be read back and matched against the module
   that owns the path, which is the assertion a transposition fails. *)
let test_production_observe_binds_this_container_s_paths () =
  let recorded = ref None in
  let observe ~cron_configured ~docker_socket ~spool_dir ~diagnostic_sink
      ~crontab_path ~payload_dir =
    recorded :=
      Some
        ( cron_configured,
          docker_socket,
          spool_dir,
          diagnostic_sink,
          crontab_path,
          payload_dir );
    []
  in
  let observations = Cli.production_observe ~observe ~cron_configured:true in
  check int "the gather's own answer is what comes back" 0
    (List.length observations);
  match !recorded with
  | None -> fail "the production gather never reached the readiness gather"
  | Some
      ( cron_configured,
        docker_socket,
        spool_dir,
        diagnostic_sink,
        crontab_path,
        payload_dir ) ->
      check bool "whether cron is configured reaches the gather" true
        cron_configured;
      check string "the socket slot carries the Docker client's own socket"
        Docker_client.default_socket_path docker_socket;
      check string "the spool slot carries the crontab module's own spool"
        Crontab.crontab_spool_dir spool_dir;
      check string "the sink slot carries the stream diagnostics duplicate to"
        Diagnostics.pid_one_stderr diagnostic_sink;
      check string "the crontab slot carries the crontab module's own file"
        Crontab.crontab_path crontab_path;
      check string "the payload slot carries the directory the writer uses"
        Bondi_common.Cron_exec_line.cron_root payload_dir

(* Surviving a client that goes away is a statement about a process, not about
   a value a function returned: a surface that does not survive it is killed
   outright, and "was killed by SIGPIPE" and "exited 1" are only the same kind
   of answer at the process boundary. So both cases below run the group in a
   forked child and read its status. The child leaves through [Unix._exit], never [exit], so that
   it runs none of Alcotest's teardown and flushes no channel the parent still
   owns; the parent flushes both of its own streams before forking so that
   nothing already buffered is written twice. *)
type child = { status : Unix.process_status; reported : string }

let in_a_child body =
  let report_read, report_write = Unix.pipe () in
  flush stdout;
  flush stderr;
  match Unix.fork () with
  | 0 ->
      Unix.close report_read;
      Unix._exit (body ~report:report_write)
  | pid ->
      Unix.close report_write;
      let channel = Unix.in_channel_of_descr report_read in
      let reported = In_channel.input_all channel in
      In_channel.close channel;
      let _, status = Unix.waitpid [] pid in
      { status; reported }

(* The child's evidence comes back on a pipe of its own rather than on either of
   the streams under test, which is the whole point: the work's outcome has to
   be observable somewhere the vanished client never had a hold on. A line this
   short moves in one write, and a partial one would truncate the evidence into
   something the parent would read as a different answer, so it leaves a code no
   completed run produces rather than being silently short. *)
let report_line report line =
  let payload = line ^ "\n" in
  match Unix.write_substring report payload 0 (String.length payload) with
  | written when written = String.length payload -> ()
  | _ -> Unix._exit 71

(* OCaml numbers signals in a scheme of its own rather than the platform's, so
   the number a status carries reads as nothing beside the 141 a shell reports.
   SIGPIPE is the one both cases are about and is named; anything else is left
   as its number, which is enough to tell it apart from the one that matters. *)
let signal_named signal =
  if signal = Sys.sigpipe then "SIGPIPE" else Printf.sprintf "signal %d" signal

(* A [docker exec -i] channel whose client has been killed, reproduced: the read
   end is closed before the write end is installed, so every write to file
   descriptor 2 from here on is a write nobody will ever read. *)
let with_vanished_stderr f =
  let reader, writer = Unix.pipe () in
  Unix.close reader;
  Unix.dup2 writer Unix.stderr;
  Unix.close writer;
  f ()

(* The work is put in the serve action because it is the one action a test can
   fill with arbitrary work without a Docker socket; what is being asserted is
   the disposition and the write, which every subcommand path shares.

   The second report line is the affirmative arm, and it is not decoration: a
   fixture whose stderr was quietly still readable would satisfy "the work ran
   to completion" while proving nothing. It runs after the write under test, as
   a raw [Unix.write] that disturbs no channel, and says what the descriptor
   actually was at that moment. *)
let test_a_write_while_work_is_in_flight_does_not_abort_the_work () =
  let child =
    in_a_child (fun ~report ->
        let serve () =
          Diagnostics.write "halfway through the work the client asked for";
          let reached =
            match Unix.write_substring Unix.stderr "." 0 1 with
            | _ -> "the stream was still accepting bytes"
            | exception Unix.Unix_error (Unix.EPIPE, _, _) ->
                "the stream was a pipe with no reader"
          in
          report_line report reached;
          report_line report "the work ran to completion";
          Ok ()
        in
        with_vanished_stderr (fun () -> evaluate ~serve [| "bondi-server" |]))
  in
  (match child.status with
  | Unix.WEXITED 0 -> ()
  | Unix.WEXITED code ->
      fail
        (Printf.sprintf "the surface exited %d rather than finishing its work"
           code)
  | Unix.WSIGNALED signal ->
      fail
        (Printf.sprintf
           "a write to a stream nobody was reading killed the surface with %s"
           (signal_named signal))
  | Unix.WSTOPPED signal ->
      fail (Printf.sprintf "the surface stopped on %s" (signal_named signal)));
  check bool "the stream the diagnostic went to really had no reader" true
    (String_utils.contains ~needle:"the stream was a pipe with no reader"
       child.reported);
  check bool "the work ran to completion after the write had failed" true
    (String_utils.contains ~needle:"the work ran to completion" child.reported)

(* The other half of the same contract, and a characterisation rather than a
   change: once there is nothing left to report, a write that cannot be made is
   still the orchestrator's failure and still exits 1. [check] is the vehicle
   because it is the only subcommand whose final write is reachable without a
   Docker Engine, and the classification it passes through is the one all five
   share.

   The stream is closed rather than broken. That is deliberate: a closed
   descriptor is the case [cli.mli] already records an observation for, and it
   is the one that must not move while the mid-work arm does.

   The message is asserted as well as the code. Any exception at all classifies
   as an orchestrator failure and exits 1, so the code alone would be satisfied
   by a run that failed for some entirely different reason; naming the write is
   what makes this an assertion about the write. *)
let test_the_final_response_write_keeps_its_classification () =
  let err_path = Filename.temp_file "bondi_cli_closed_stdout" ".txt" in
  let err_fd = Unix.openfile err_path [ Unix.O_WRONLY; Unix.O_TRUNC ] 0o600 in
  let serve () = Ok () in
  let child =
    in_a_child (fun ~report:_ ->
        Unix.dup2 err_fd Unix.stderr;
        Unix.close Unix.stdout;
        evaluate
          ~observe:(fun ~cron_configured:_ -> [])
          ~serve
          [| "bondi-server"; "check" |])
  in
  Unix.close err_fd;
  let written_err = read_file err_path in
  Sys.remove err_path;
  (match child.status with
  | Unix.WEXITED 1 -> ()
  | Unix.WEXITED code ->
      fail
        (Printf.sprintf
           "a write with nothing left to report exited %d rather than 1" code)
  | Unix.WSIGNALED signal ->
      fail
        (Printf.sprintf "the final write killed the surface with %s"
           (signal_named signal))
  | Unix.WSTOPPED signal ->
      fail (Printf.sprintf "the surface stopped on %s" (signal_named signal)));
  check bool "the failure names the write that could not be made" true
    (String_utils.contains ~needle:"Bad file descriptor" written_err)

let () =
  run "cli"
    [
      ( "command group",
        [
          test_case "no arguments evaluates serve" `Quick
            test_no_arguments_evaluates_serve;
          test_case "the serve subcommand evaluates serve" `Quick
            test_the_serve_subcommand_evaluates_serve;
          test_case "an unknown subcommand does not evaluate serve" `Quick
            test_an_unknown_subcommand_does_not_evaluate_serve;
          test_case "a configuration failure does not exit zero" `Quick
            test_a_configuration_failure_does_not_exit_zero;
          test_case "a configuration failure names the value it refused" `Quick
            test_a_configuration_failure_names_the_value_it_refused;
        ] );
      ( "the manual",
        [
          test_case "help documents the codes a failure leaves behind" `Quick
            test_help_documents_the_codes_a_failure_leaves_behind;
          test_case "the group reports the version the image baked" `Quick
            test_the_group_reports_the_version_the_image_baked;
        ] );
      ( "the production binding",
        [
          test_case "production observe binds this container's paths" `Quick
            test_production_observe_binds_this_container_s_paths;
        ] );
      ( "subcommands",
        [
          test_case "deploy reads its payload from stdin" `Quick
            test_deploy_reads_its_payload_from_stdin;
          test_case "a payload in argv is not read as a payload" `Quick
            test_a_payload_in_argv_is_not_read_as_a_payload;
          test_case "check takes whether cron is configured as an argument"
            `Quick test_check_takes_whether_cron_is_configured_as_an_argument;
          test_case "check reports every failing probe and exits three" `Quick
            test_check_reports_every_failing_probe_and_exits_three;
          test_case "check reports the divergence in its document and its code"
            `Quick
            test_check_reports_the_divergence_in_its_document_and_its_code;
        ] );
      ( "failure classification",
        [
          test_case "a body that raises exits with its class's code" `Quick
            test_a_body_that_raises_exits_with_its_class_s_code;
          test_case "a serve that raises exits with its class's code" `Quick
            test_a_serve_that_raises_exits_with_its_class_s_code;
          test_case "an escaping exception is answered as a failure" `Quick
            test_classified_result_answers_an_escaping_exception_as_a_failure;
          test_case "a cancellation propagates" `Quick
            test_classified_result_propagates_a_cancellation;
          test_case "a deliberate exit propagates" `Quick
            test_classified_result_propagates_a_deliberate_exit;
          test_case "an action that returned keeps its code" `Quick
            test_classified_status_returns_the_code_the_action_chose;
          test_case "an escaping exception is coded from its class" `Quick
            test_classified_status_codes_an_escaping_exception_from_its_class;
          test_case "a cancellation propagates through the whole term" `Quick
            test_classified_status_propagates_a_cancellation;
        ] );
      ( "a client that goes away",
        [
          test_case "a write while work is in flight does not abort the work"
            `Quick test_a_write_while_work_is_in_flight_does_not_abort_the_work;
          test_case "the final response write keeps its classification" `Quick
            test_the_final_response_write_keeps_its_classification;
        ] );
    ]
