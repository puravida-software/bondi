open Alcotest
module Ssh_agent = Bondi_client.Ssh_agent
module String_utils = Bondi_common.String_utils

(* The variable is spelled out here rather than asked of the module, because
   what these cases are about is that the module names this one and no other.
   A test that read the name from the code under test would pass whatever the
   code renamed it to. *)
let variable = "SSH_AUTH_SOCK"
let assignments environment = Array.to_list environment

let named_entries environment =
  List.filter
    (fun entry -> String_utils.starts_with ~prefix:(variable ^ "=") entry)
    (assignments environment)

let test_an_environment_without_the_variable_gains_exactly_one () =
  let result =
    Ssh_agent.client_environment ~auth_sock:"/run/bondi/s"
      [| "PATH=/bin"; "HOME=/home/deploy" |]
  in
  check (list string) "one assignment, naming the agent this run raised"
    [ "SSH_AUTH_SOCK=/run/bondi/s" ]
    (named_entries result);
  check (list string) "and the rest is carried through in the order it came in"
    [ "PATH=/bin"; "HOME=/home/deploy"; "SSH_AUTH_SOCK=/run/bondi/s" ]
    (assignments result)

(* The property the module argues hardest for. A second assignment of the same
   name is not an override -- the C library answers with the first it finds --
   so an implementation that appended would leave the operator's own agent
   first in the array and this run's key unreachable. *)
let test_an_inherited_assignment_is_replaced_not_appended () =
  let result =
    Ssh_agent.client_environment ~auth_sock:"/run/bondi/s"
      [|
        "PATH=/bin";
        "SSH_AUTH_SOCK=/tmp/the-operators-own-agent";
        "HOME=/home/deploy";
      |]
  in
  check (list string) "exactly one, and it is this run's"
    [ "SSH_AUTH_SOCK=/run/bondi/s" ]
    (named_entries result);
  check bool "the inherited socket is gone rather than shadowed" false
    (List.exists
       (fun entry -> entry = "SSH_AUTH_SOCK=/tmp/the-operators-own-agent")
       (assignments result));
  check (list string) "and nothing else was disturbed"
    [ "PATH=/bin"; "HOME=/home/deploy"; "SSH_AUTH_SOCK=/run/bondi/s" ]
    (assignments result)

(* The removal matches a whole name, not a prefix of one. A variable whose name
   merely begins the same way belongs to whoever set it. *)
let test_a_name_that_only_starts_the_same_is_left_alone () =
  let result =
    Ssh_agent.client_environment ~auth_sock:"/run/bondi/s"
      [| "SSH_AUTH_SOCKET=/tmp/somebody-elses"; "SSH_AUTH=/tmp/other" |]
  in
  check (list string) "both survive, and the one this module sets is added"
    [
      "SSH_AUTH_SOCKET=/tmp/somebody-elses";
      "SSH_AUTH=/tmp/other";
      "SSH_AUTH_SOCK=/run/bondi/s";
    ]
    (assignments result)

(* A value that happens to contain the name is a value. The split is at the
   first [=], so what is compared is the name and never the whole entry. *)
let test_a_value_containing_the_name_is_not_a_setting_of_it () =
  let result =
    Ssh_agent.client_environment ~auth_sock:"/run/bondi/s"
      [| "BONDI_NOTE=SSH_AUTH_SOCK=/tmp/decoy" |]
  in
  check (list string) "the note survives untouched"
    [ "BONDI_NOTE=SSH_AUTH_SOCK=/tmp/decoy"; "SSH_AUTH_SOCK=/run/bondi/s" ]
    (assignments result)

(* An entry with no [=] is not an assignment and is nobody's to interpret. It is
   carried through rather than dropped, because an environment this module
   shortened is an environment the spawned client is missing something from. *)
let test_an_entry_that_is_not_an_assignment_is_carried_through () =
  let result =
    Ssh_agent.client_environment ~auth_sock:"/run/bondi/s" [| "MALFORMED" |]
  in
  check (list string) "kept as it stands"
    [ "MALFORMED"; "SSH_AUTH_SOCK=/run/bondi/s" ]
    (assignments result)

let () =
  run "Ssh_agent"
    [
      ( "client_environment",
        [
          test_case "an environment without the variable gains exactly one"
            `Quick test_an_environment_without_the_variable_gains_exactly_one;
          test_case "an inherited assignment is replaced, not appended" `Quick
            test_an_inherited_assignment_is_replaced_not_appended;
          test_case "a name that only starts the same is left alone" `Quick
            test_a_name_that_only_starts_the_same_is_left_alone;
          test_case "a value containing the name is not a setting of it" `Quick
            test_a_value_containing_the_name_is_not_a_setting_of_it;
          test_case "an entry that is not an assignment is carried through"
            `Quick test_an_entry_that_is_not_an_assignment_is_carried_through;
        ] );
    ]
