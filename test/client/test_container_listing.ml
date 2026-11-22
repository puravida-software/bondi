open Alcotest
open Bondi_client

(* The listings below are read from fixtures/docker_cli/, which holds what a real
   docker CLI printed for [Container_listing.command]'s format, byte for byte.
   Its README names the engine and the commands. The lines written out here
   instead are that same shape with one column changed, for states and
   malformations no capture holds. *)
let captured name =
  let path = Filename.concat "fixtures/docker_cli" name in
  let channel = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr channel)
    (fun () -> really_input_string channel (in_channel_length channel))

let describe = function
  | Container_listing.Absent -> "Absent"
  | Container_listing.Not_running -> "Not_running"
  | Container_listing.Running { image; spec_hash = Some hash } ->
      Printf.sprintf "Running { image = %S; spec_hash = Some %S }" image hash
  | Container_listing.Running { image; spec_hash = None } ->
      Printf.sprintf "Running { image = %S; spec_hash = None }" image
  | Container_listing.Undetermined message ->
      Printf.sprintf "Undetermined %S" message

let check_reading message ~expected output =
  check string message (describe expected)
    (describe (Container_listing.of_probe (Ok output)))

(* The label column is the configuration the container was created with. Read
   wrong, every later comparison against it is wrong in the same direction. *)
let test_running_with_label () =
  check_reading "the reference and the label"
    ~expected:
      (Container_listing.Running
         { image = "localhost:45123/obsimg:t"; spec_hash = Some "abc123" })
    (captured "ps_labelled_running.out");
  check_reading "after the tag moved, the short image id and the label"
    ~expected:
      (Container_listing.Running
         { image = "66a6306db78b"; spec_hash = Some "abc123" })
    (captured "ps_labelled_after_tag_moved.out")

(* A container with no such label prints an empty last column, not a missing
   one: the tab before it is still there. Trimming the line before splitting it
   takes that tab away and leaves two columns, which is the same line a listing
   that never asked for the label prints. *)
let test_running_without_label () =
  check_reading "the reference and no label"
    ~expected:
      (Container_listing.Running
         { image = "localhost:45123/obsimg:t"; spec_hash = None })
    (captured "ps_unlabelled_running.out");
  check_reading "after the tag moved, the short image id and no label"
    ~expected:
      (Container_listing.Running { image = "66a6306db78b"; spec_hash = None })
    (captured "ps_unlabelled_after_tag_moved.out")

(* Every one of these holds the container's name and none of them is ready, so
   all of them are a container to replace. The affirmative arm is the same line
   with the state "running", which shows the line reaches the state column at
   all. *)
let test_every_non_running_state_is_not_running () =
  check_reading "created, as captured" ~expected:Container_listing.Not_running
    (captured "ps_unlabelled_created.out");
  List.iter
    (fun state ->
      check_reading
        (state ^ " is not running")
        ~expected:Container_listing.Not_running
        (Printf.sprintf "%s\tlocalhost:45123/obsimg:t\tabc123\n" state))
    [ "created"; "restarting"; "paused"; "exited"; "removing"; "dead" ];
  check_reading "the same line, running"
    ~expected:
      (Container_listing.Running
         { image = "localhost:45123/obsimg:t"; spec_hash = Some "abc123" })
    "running\tlocalhost:45123/obsimg:t\tabc123\n"

(* A line that does not split into three columns is not a reading of any
   container: calling it not running plans a removal on a guess. It is
   undetermined, and the message quotes the line it could not decode. The first
   case is the two-column line a listing that never asked for the label prints,
   which must not pass for a running container with no label. The affirmative
   arm is the same container in three columns. *)
let test_malformed_line_is_undetermined () =
  List.iter
    (fun (label, line) ->
      check_reading label
        ~expected:
          (Container_listing.Undetermined
             (Printf.sprintf
                "could not decode the container listing line %S: expected \
                 three tab-separated columns"
                (String.sub line 0 (String.length line - 1))))
        line)
    [
      ("two columns", "running\tlocalhost:45123/obsimg:t\n");
      ("one column", "running\n");
      ("four columns", "running\tlocalhost:45123/obsimg:t\tabc123\textra\n");
    ];
  check_reading "three columns"
    ~expected:
      (Container_listing.Running
         { image = "localhost:45123/obsimg:t"; spec_hash = Some "abc123" })
    "running\tlocalhost:45123/obsimg:t\tabc123\n"

(* A [ps] for a name no container holds prints nothing at all and exits 0. *)
let test_empty_listing_is_absent () =
  check_reading "nothing printed" ~expected:Container_listing.Absent "";
  check_reading "only a blank line" ~expected:Container_listing.Absent "\n"

(* A listing that never ran says nothing about the box, and the runner's own
   words are kept for the message that refuses on it. The affirmative arm is a
   listing that answered, through the same function. *)
let test_failed_probe_is_undetermined () =
  let failure =
    "the host was not reached (255): Connection closed by 203.0.113.9 port 22"
  in
  check string "a failed listing is undetermined"
    (describe (Container_listing.Undetermined failure))
    (describe (Container_listing.of_probe (Error failure)));
  check string "a listing that answered is read"
    (describe
       (Container_listing.Running
          { image = "localhost:45123/obsimg:t"; spec_hash = Some "abc123" }))
    (describe
       (Container_listing.of_probe (Ok (captured "ps_labelled_running.out"))))

(* The listing is run on the host by name, so the name is what the filter and
   the label column are built from. *)
let test_command_filters_by_name () =
  check string "the orchestrator's listing"
    "ps -a --filter name=^/bondi-orchestrator$ --format \
     '{{.State}}\t{{.Image}}\t{{.Label \"bondi.spec-hash\"}}'"
    (Container_listing.command ~name:"bondi-orchestrator")

let () =
  run "container listing"
    [
      ( "reading one named container",
        [
          test_case "running with the label" `Quick test_running_with_label;
          test_case "running without the label" `Quick
            test_running_without_label;
          test_case "every non-running state is not running" `Quick
            test_every_non_running_state_is_not_running;
          test_case "a malformed line is undetermined" `Quick
            test_malformed_line_is_undetermined;
          test_case "an empty listing is absent" `Quick
            test_empty_listing_is_absent;
          test_case "a failed probe is undetermined" `Quick
            test_failed_probe_is_undetermined;
          test_case "the command filters by name" `Quick
            test_command_filters_by_name;
        ] );
    ]
