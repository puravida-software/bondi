module Server_version = Bondi_client.Server_version

(* Both gates have the same shape, so the two helpers take the gate rather than
   naming one of them. The gate's name travels with it so a failure says which
   floor disagreed. *)
let accepted_by gate ~gate_name version =
  match gate version with
  | Ok () -> ()
  | Error msg ->
      Alcotest.fail
        (Printf.sprintf "expected %s to be accepted by %s, got: %s"
           (String.escaped version) gate_name msg)

let refused_by gate ~gate_name version =
  match gate version with
  | Ok () ->
      Alcotest.fail
        (Printf.sprintf "expected %s to refuse: %s" gate_name
           (String.escaped version))
  | Error msg -> msg

let accepted version =
  accepted_by Server_version.writes_exec_lines ~gate_name:"writes_exec_lines"
    version

let rejection version =
  refused_by Server_version.writes_exec_lines ~gate_name:"writes_exec_lines"
    version

let answered version =
  accepted_by Server_version.answers_command_surface
    ~gate_name:"answers_command_surface" version

let unanswered version =
  refused_by Server_version.answers_command_surface
    ~gate_name:"answers_command_surface" version

let names ~what needle msg =
  Alcotest.(check bool)
    (Printf.sprintf "the refusal names %s (%s): %s" what needle msg)
    true
    (Bondi_common.String_utils.contains ~needle msg)

(* 0.16.0 is the first release whose server writes exec lines and run files, so
   it is accepted and the release before it is not. Asserting the boundary from
   both sides pins the boundary rather than the direction. *)
let test_the_minimum_version_writes_exec_lines () =
  accepted Server_version.minimum_for_exec_lines;
  accepted "0.16.0"

(* Executing the generated line and writing it are separate capabilities, and
   this floor is the second one. 0.15.0 carries the [run] subcommand, so a line
   written against it would fire -- but its own server still writes legacy curl
   lines and no run file, and the deploy that writes them answers 200. Observed
   on the estate's one box with a crontab: three deploys reported success and
   left the crontab on the shape they were meant to replace, which is a silent
   no-op wearing a success message. A floor set at 0.15.0 accepts exactly that
   box. *)
let test_a_release_that_runs_the_line_but_cannot_write_it_is_refused () =
  names ~what:"the version it refused" "0.15.0" (rejection "0.15.0")

let test_a_version_below_the_minimum_is_refused () =
  (* 0.12.0 is what the estate was running when this gate was written. *)
  List.iter
    (fun version ->
      names ~what:"the version it refused" version (rejection version))
    [ "0.15.0"; "0.14.0"; "0.12.0"; "0.9.0" ]

(* The comparison is an ordering, not equality: every one of these is newer than
   the floor, and an equality test would refuse all three. 0.9.0 above is the
   half string ordering gets wrong in the other direction. *)
let test_a_version_above_the_minimum_is_accepted () =
  accepted "0.16.1";
  accepted "0.17.0";
  accepted "1.0.0"

let test_the_refusal_names_the_running_version_and_the_required_one () =
  let msg = rejection "0.12.0" in
  names ~what:"what the box reported" "0.12.0" msg;
  names ~what:"what is required" Server_version.minimum_for_exec_lines msg;
  names ~what:"the command that fixes it" "bondi setup" msg

(* A box whose orchestrator is absent answers with nothing, and a [latest] tag
   carries no version at all. Neither is evidence of an image that can run the
   line, so neither is a pass -- and the refusal quotes what the box said. *)
let test_an_unrecognisable_version_is_a_refusal_not_a_pass () =
  names ~what:"what the box reported" "latest" (rejection "latest");
  (* An empty answer is what a box with no orchestrator gives, and a bare "0"
     is a tag with nothing to order against. Neither can be quoted back into a
     useful assertion, so what is asserted of them is that the refusal still
     tells the operator what is required. *)
  List.iter
    (fun version ->
      names ~what:"what is required" Server_version.minimum_for_exec_lines
        (rejection version))
    [ ""; "0" ]

(* A fork or a locally built image is still the orchestrator by name, and the
   tag it carries is not this project's. The whole image is reported so the
   refusal names something the operator can recognise. *)
let test_a_forks_image_name_is_reported_as_it_stands () =
  let image = "ghcr.io/acme/bondi-server:2024-06-01" in
  Alcotest.(check string)
    "a fork's image is reported whole" image
    (Server_version.orchestrator_version_of_image image);
  Alcotest.(check string)
    "the published image is reported by tag" "0.12.0"
    (Server_version.orchestrator_version_of_image
       "mlopez1506/bondi-server:0.12.0");
  names ~what:"the fork's image" image (rejection image)

(* The second floor: the release whose binary carries subcommands at all. A box
   below it has no [bondi-server deploy] to run, so the command an operator
   typed cannot be answered and the refusal has to name both numbers -- the one
   the box reported and the one required -- or the operator has nothing to pin
   bondi.yaml to. *)
let test_a_box_below_the_command_surface_floor_is_refused () =
  List.iter
    (fun version ->
      let msg = unanswered version in
      names ~what:"the version it refused" version msg;
      names ~what:"what is required" Server_version.minimum_for_command_surface
        msg;
      names ~what:"the command that fixes it" "bondi setup" msg)
    [ "0.14.0"; "0.12.0"; "0.9.0" ]

(* The case that proves the two floors are not one. 0.15.0 carries the
   subcommands and answers a deploy perfectly well; what it cannot do is write
   an exec line, which is the later capability the other floor names. Refusing
   it here would refuse a box that works, so the acceptance is asserted next to
   the refusal the other gate still owes it. *)
let test_a_box_at_the_command_surface_floor_is_accepted_while_below_the_exec_line_floor
    () =
  Alcotest.(check string)
    "the floor is the release the subcommands arrived in" "0.15.0"
    Server_version.minimum_for_command_surface;
  answered Server_version.minimum_for_command_surface;
  answered "0.15.0";
  answered "0.15.3";
  answered "0.16.0";
  answered "1.0.0";
  names ~what:"the version the writer's floor still refuses" "0.15.0"
    (rejection "0.15.0")

(* An answer with no ordering in it is not evidence of a box that can answer a
   subcommand, so it is a refusal rather than a pass -- and what the box said is
   quoted back, because that is the only thing the operator can recognise. *)
let test_an_unreadable_answer_is_a_refusal () =
  names ~what:"what the box reported" "latest" (unanswered "latest");
  let image = "ghcr.io/acme/bondi-server:2024-06-01" in
  names ~what:"the fork's image" image
    (unanswered (Server_version.orchestrator_version_of_image image));
  (* An empty answer is what a box with no orchestrator gives, and a bare "0" is
     a tag with nothing to order against. Neither can be quoted back into a
     useful assertion, so what is asserted of them is that the refusal still
     tells the operator what is required. *)
  List.iter
    (fun version ->
      names ~what:"what is required" Server_version.minimum_for_command_surface
        (unanswered version))
    [ ""; "0" ]

let () =
  Alcotest.run "Server_version"
    [
      ( "writes_exec_lines",
        [
          Alcotest.test_case "the minimum version writes exec lines" `Quick
            test_the_minimum_version_writes_exec_lines;
          Alcotest.test_case
            "a release that runs the line but cannot write it is refused" `Quick
            test_a_release_that_runs_the_line_but_cannot_write_it_is_refused;
          Alcotest.test_case "a version below the minimum is refused" `Quick
            test_a_version_below_the_minimum_is_refused;
          Alcotest.test_case "a version above the minimum is accepted" `Quick
            test_a_version_above_the_minimum_is_accepted;
          Alcotest.test_case
            "the refusal names the running version and the required one" `Quick
            test_the_refusal_names_the_running_version_and_the_required_one;
          Alcotest.test_case
            "an unrecognisable version is a refusal, not a pass" `Quick
            test_an_unrecognisable_version_is_a_refusal_not_a_pass;
          Alcotest.test_case "a fork's image name is reported as it stands"
            `Quick test_a_forks_image_name_is_reported_as_it_stands;
        ] );
      ( "answers_command_surface",
        [
          Alcotest.test_case
            "a box below the command-surface floor is refused, naming both \
             versions"
            `Quick test_a_box_below_the_command_surface_floor_is_refused;
          Alcotest.test_case
            "a box at the command-surface floor is accepted while below the \
             exec-line floor"
            `Quick
            test_a_box_at_the_command_surface_floor_is_accepted_while_below_the_exec_line_floor;
          Alcotest.test_case "an unreadable answer is a refusal" `Quick
            test_an_unreadable_answer_is_a_refusal;
        ] );
    ]
