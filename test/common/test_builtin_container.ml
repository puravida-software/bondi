open Alcotest
module Builtin_container = Bondi_common.Builtin_container

(* The one spelling of the container name. Pinned as a literal rather than read
   back off the module under test, which would agree with any value at all: what
   the hosts actually run is a container called bondi-orchestrator, and a typo
   here is a setup run that cannot find the container it just started. *)
let test_the_orchestrator_container_has_one_name () =
  check string "the name every command on a host uses" "bondi-orchestrator"
    Builtin_container.orchestrator

let () =
  run "Builtin_container"
    [
      ( "orchestrator",
        [
          test_case "the orchestrator container has one name" `Quick
            test_the_orchestrator_container_has_one_name;
        ] );
    ]
