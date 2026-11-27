open Alcotest
module Network_probe = Bondi_client.Network_probe
module Remote_exec = Bondi_client.Remote_exec

let contains ~needle haystack =
  Bondi_common.String_utils.contains ~needle haystack

let transport_error =
  Remote_exec.message
    (Remote_exec.Ssh_failed
       { code = 255; output = "Connection closed by 203.0.113.9 port 22" })

(* A network that was absent is one this run created, and the closing line lists
   it; one that was present is a check and lists nothing. An answer with neither
   marker is refused rather than read as either. *)
let test_reading () =
  let network = Bondi_common.Defaults.network_name in
  let account answer =
    Network_probe.account ~server:"10.0.0.1" ~network answer
  in
  let changes answer =
    match account answer with
    | Ok (_, changes) ->
        Bondi_client.Setup_changes.closing_line ~server:"10.0.0.1" changes
    | Error message -> "refused: " ^ message
  in
  check string "absent: created"
    "setup changed on server 10.0.0.1: network bondi-network created"
    (changes (Ok (Network_probe.created_marker ^ "\n")));
  check string "present: nothing" "setup changed nothing on server 10.0.0.1"
    (changes (Ok (Network_probe.present_marker ^ "\n")));
  (match account (Ok (Network_probe.present_marker ^ "\n")) with
  | Ok (line, _) ->
      check string "the present line"
        "Network bondi-network is present on server 10.0.0.1" line
  | Error message -> failf "a present network was refused: %s" message);
  (match account (Ok (Network_probe.created_marker ^ "\n")) with
  | Ok (line, _) ->
      check string "the created line"
        "Network bondi-network created on server 10.0.0.1" line
  | Error message -> failf "a created network was refused: %s" message);
  (match account (Ok "") with
  | Ok (line, _) -> failf "silence is not an answer: %s" line
  | Error message ->
      check bool "names the network" true (contains ~needle:network message));
  match account (Error transport_error) with
  | Ok (line, _) -> failf "a command that never ran answered: %s" line
  | Error message ->
      check bool "carries the runner's own text" true
        (contains ~needle:"Connection closed by 203.0.113.9 port 22" message)

let test_command_reports_which () =
  let command = Network_probe.ensure_command ~network:"bondi-network" in
  let carries needle = contains ~needle command in
  check bool "inspects the network" true
    (carries "docker network inspect 'bondi-network'");
  check bool "creates it otherwise" true
    (carries "docker network create 'bondi-network'");
  check bool "says when it was there" true
    (carries Network_probe.present_marker);
  check bool "says when it created it" true
    (carries Network_probe.created_marker)

let () =
  run "network_probe"
    [
      ( "network reading",
        [
          test_case "created is a change, present is not" `Quick test_reading;
          test_case "the command says which" `Quick test_command_reports_which;
        ] );
    ]
