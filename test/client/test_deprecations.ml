open Alcotest
module Config_file = Bondi_client.Config_file
module Deprecations = Bondi_client.Deprecations

let contains ~needle s = Test_helpers.contains ~needle s

(* Every field is named at each call rather than defaulted, so a case says which
   configuration it is about and no field reaches the function unnoticed. *)
let server ~bind_address ~api_token : Config_file.bondi_server =
  { version = "0.1.0"; bind_address; api_token }

let only_message ~case messages =
  match messages with
  | [ message ] -> message
  | messages ->
      failf "%s: expected one message, got %d: [%s]" case (List.length messages)
        (String.concat " | " messages)

let test_bind_address_declared_yields_one_message_naming_it () =
  let message =
    only_message ~case:"bind_address"
      (Deprecations.messages
         (server ~bind_address:(Some "0.0.0.0") ~api_token:None))
  in
  check bool "names the field" true
    (contains ~needle:"bondi_server.bind_address" message);
  check bool "says what to do with it" true (contains ~needle:"Remove" message);
  check bool "names the declared binding" true
    (contains ~needle:"0.0.0.0" message);
  (* A stale knob is not a stale credential: the rotation sentence belongs to
     the token's message alone, and a single shared message would pass every
     other assertion here. *)
  check bool "does not tell the operator to rotate a binding" false
    (contains ~needle:"rotate" message)

let test_api_token_declared_yields_one_message_saying_rotate () =
  let message =
    only_message ~case:"api_token"
      (Deprecations.messages
         (server ~bind_address:None ~api_token:(Some "s3cret")))
  in
  check bool "names the field" true
    (contains ~needle:"bondi_server.api_token" message);
  check bool "says what to do with it" true (contains ~needle:"Remove" message);
  check bool "says to rotate it" true (contains ~needle:"rotate" message);
  (* The message is printed to a terminal, a CI log and a scrollback, all of
     which are poorer places for a secret than the file it came from. *)
  check bool "does not echo the token" false (contains ~needle:"s3cret" message)

let test_both_declared_yields_both_messages () =
  let messages =
    Deprecations.messages
      (server ~bind_address:(Some "127.0.0.1") ~api_token:(Some "s3cret"))
  in
  check int "one message per declared field" 2 (List.length messages);
  check bool "one names the binding" true
    (List.exists (contains ~needle:"bondi_server.bind_address") messages);
  check bool "one names the token" true
    (List.exists (contains ~needle:"bondi_server.api_token") messages)

(* The case a constant-[[]] implementation passes, which is why it is asserted
   beside the populated ones rather than alone: the same record constructor is
   shown producing messages above, so an empty answer here can only mean the
   fields were read. *)
let test_neither_declared_yields_no_messages () =
  check (list string) "nothing to say" []
    (Deprecations.messages (server ~bind_address:None ~api_token:None))

let () =
  run "Deprecations"
    [
      ( "messages",
        [
          test_case "a declared bind_address yields one message naming it"
            `Quick test_bind_address_declared_yields_one_message_naming_it;
          test_case "a declared api_token yields one message saying to rotate"
            `Quick test_api_token_declared_yields_one_message_saying_rotate;
          test_case "both declared yields both" `Quick
            test_both_declared_yields_both_messages;
          test_case "neither declared yields none" `Quick
            test_neither_declared_yields_no_messages;
        ] );
    ]
