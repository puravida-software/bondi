open Alcotest
module Builtin_image = Bondi_client.Builtin_image
module Image_reference = Bondi_common.Image_reference

let test_pull_command_quotes_a_bracketed_ipv6_reference () =
  let reference = Test_helpers.image_reference "[::1]:5000/app:1" in
  check string "the bracket is quoted against the host's glob"
    "pull '[::1]:5000/app:1'"
    (Builtin_image.pull_command reference)

let test_pull_failure_sentence () =
  check string "the sentence the server also uses"
    "could not pull grafana/alloy:v1.8.0: no route to host"
    (Builtin_image.pull_failure
       (Test_helpers.image_reference "grafana/alloy:v1.8.0")
       ~reason:"no route to host")

let test_orchestrator_for_an_empty_version () =
  match Builtin_image.orchestrator ~version:"" with
  | Ok _ -> fail "an empty version made a reference"
  | Error message ->
      (* An empty version composes "repo:", which is malformed; the [Empty]
         arm is reached only by an empty repository, which is a constant. *)
      check string "names the field and echoes the composed text"
        (Printf.sprintf
           "bondi_server.version \"\" does not make an image reference: %S is \
            not one"
           (Builtin_image.orchestrator_repository ^ ":"))
        message

let test_orchestrator_composes_the_repository_and_version () =
  match Builtin_image.orchestrator ~version:"1.0.0" with
  | Error message -> fail message
  | Ok reference ->
      check string "repository and tag"
        (Builtin_image.orchestrator_repository ^ ":1.0.0")
        (Image_reference.to_string reference)

let test_alloy_defaults_when_undeclared () =
  check string "the default image" Bondi_common.Defaults.alloy_image
    (Image_reference.to_string (Builtin_image.alloy ~declared:None))

let test_alloy_keeps_a_declared_image () =
  let declared = Test_helpers.image_reference "registry.example.com/alloy:v2" in
  check string "the declared image" "registry.example.com/alloy:v2"
    (Image_reference.to_string (Builtin_image.alloy ~declared:(Some declared)))

let () =
  run "Builtin_image"
    [
      ( "builtin_image",
        [
          test_case "pull command quotes bracketed IPv6" `Quick
            test_pull_command_quotes_a_bracketed_ipv6_reference;
          test_case "pull failure sentence" `Quick test_pull_failure_sentence;
          test_case "orchestrator, empty version" `Quick
            test_orchestrator_for_an_empty_version;
          test_case "orchestrator composition" `Quick
            test_orchestrator_composes_the_repository_and_version;
          test_case "alloy default" `Quick test_alloy_defaults_when_undeclared;
          test_case "alloy declared" `Quick test_alloy_keeps_a_declared_image;
        ] );
    ]
