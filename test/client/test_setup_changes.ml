open Alcotest
module Setup_changes = Bondi_client.Setup_changes
module Setup_phases = Bondi_client.Setup_phases
module Host_answer = Bondi_client.Host_answer

let server = "203.0.113.10"

(* One change and the item it is listed as, one per change setup can make, so that each one is
   seen to render as something an operator can read. Every assertion is on the
   whole line: an exact line is what shows nothing else is in it, a declared
   value included. *)
let items =
  [
    (Setup_changes.Docker_installed, "Docker installed");
    ( Setup_changes.Network_created Bondi_common.Defaults.network_name,
      "network bondi-network created" );
    (Setup_changes.Acme_file_created, "ACME file created");
    ( Setup_changes.Corrected Setup_changes.Acme_file_permissions,
      "ACME file permissions corrected" );
    (Setup_changes.Orchestrator_created "0.30.0", "orchestrator 0.30.0 created");
    ( Setup_changes.Orchestrator_recreated
        (Setup_changes.Version
           { running = Host_answer.of_host_output "0.25.0"; wanted = "0.30.0" }),
      "orchestrator 0.25.0 → 0.30.0" );
    ( Setup_changes.Orchestrator_recreated
        (Setup_changes.Reason Setup_changes.Config_changed),
      "orchestrator recreated (config changed)" );
    ( Setup_changes.Orchestrator_recreated
        (Setup_changes.Reason Setup_changes.No_digest),
      "orchestrator recreated (no config digest)" );
    ( Setup_changes.Orchestrator_recreated
        (Setup_changes.Reason Setup_changes.Image_moved),
      "orchestrator recreated (image moved)" );
    ( Setup_changes.Orchestrator_recreated
        (Setup_changes.Reason Setup_changes.Not_running),
      "orchestrator recreated (not running)" );
    (Setup_changes.Orchestrator_removed, "orchestrator removed");
    (Setup_changes.Orchestrator_stopped, "orchestrator stopped");
    (Setup_changes.Alloy_stopped, "Alloy stopped");
    (Setup_changes.Alloy_config_removed, "Alloy config removed");
    (Setup_changes.Managed_stopped "relay", "relay stopped");
    ( Setup_changes.Corrected Setup_changes.Orchestrator_restart_policy,
      "orchestrator restart policy corrected" );
    (Setup_changes.Journal_provisioned, "journal made persistent");
    (Setup_changes.Alloy_created, "Alloy created");
    ( Setup_changes.Alloy_recreated Setup_changes.Config_changed,
      "Alloy recreated (config changed)" );
    ( Setup_changes.Alloy_recreated Setup_changes.Image_moved,
      "Alloy recreated (image moved)" );
    ( Setup_changes.Alloy_recreated Setup_changes.Not_running,
      "Alloy recreated (not running)" );
    ( Setup_changes.Alloy_recreated Setup_changes.Mounted_file_missing,
      "Alloy recreated (mounted file missing)" );
    ( Setup_changes.Corrected Setup_changes.Alloy_config_mode,
      "Alloy config mode corrected" );
    ( Setup_changes.Corrected Setup_changes.Alloy_env_mode,
      "Alloy credentials mode corrected" );
    (Setup_changes.Alloy_removed, "Alloy removed");
    (Setup_changes.Managed_created "gateway", "gateway created");
    ( Setup_changes.Managed_recreated "gateway",
      "gateway recreated (config changed)" );
    (Setup_changes.Managed_removed "gateway", "gateway removed");
    ( Setup_changes.Alloy_recreated Setup_changes.No_digest,
      "Alloy recreated (no config digest)" );
  ]

let test_every_item_renders () =
  List.iter
    (fun (change, item) ->
      check string item
        ("setup changed on server 203.0.113.10: " ^ item)
        (Setup_changes.closing_line ~server [ change ]))
    items

let test_upgrade_line () =
  check string "the run that upgraded the orchestrator and replaced Alloy"
    "setup changed on server 203.0.113.10: orchestrator 0.25.0 → 0.30.0, Alloy \
     recreated (config changed)"
    (Setup_changes.closing_line ~server:"203.0.113.10"
       [
         Setup_changes.Orchestrator_recreated
           (Setup_changes.Version
              {
                running = Host_answer.of_host_output "0.25.0";
                wanted = "0.30.0";
              });
         Setup_changes.Alloy_recreated Setup_changes.Config_changed;
       ])

let test_hostile_running_version () =
  let line =
    Setup_changes.closing_line ~server
      [
        Setup_changes.Orchestrator_recreated
          (Setup_changes.Version
             {
               running =
                 Host_answer.of_host_output "0.25.0\nforged line\027[2J\127";
               wanted = "0.30.0";
             });
      ]
  in
  check bool "one line, no newline" false (String.contains line '\n');
  check bool "no escape character" false (String.contains line '\027');
  check bool "no DEL" false (String.contains line '\127')

let test_nothing_changed () =
  check string "an empty change set says nothing changed"
    "setup changed nothing on server 203.0.113.10"
    (Setup_changes.closing_line ~server [])

let test_order_is_the_run_order () =
  check string "items in the order given, not sorted"
    "setup changed on server 203.0.113.10: gateway removed, Docker installed, \
     cache created"
    (Setup_changes.closing_line ~server
       [
         Setup_changes.Managed_removed "gateway";
         Setup_changes.Docker_installed;
         Setup_changes.Managed_created "cache";
       ])

(* A change is compared by the item it renders as, which is what an operator
   reads, and by structural equality, which is what tells two changes apart. *)
let change =
  testable
    (Fmt.of_to_string (fun change ->
         Setup_changes.closing_line ~server [ change ]))
    ( = )

let test_of_correction () =
  let found = Host_answer.of_host_output "0644" in
  check (option change) "the journal's correction is the journal provisioned"
    (Some Setup_changes.Journal_provisioned)
    (Setup_changes.of_correction Setup_phases.journal_storage_provisioned);
  check (option change) "the restart policy is corrected at its site"
    (Some (Setup_changes.Corrected Setup_changes.Orchestrator_restart_policy))
    (Setup_changes.of_correction
       (Setup_phases.restart_policy_corrected
          ~found:(Host_answer.of_host_output "no")
          ~applied:"unless-stopped"));
  check (option change) "the config mode is corrected at its site"
    (Some (Setup_changes.Corrected Setup_changes.Alloy_config_mode))
    (Setup_changes.of_correction
       (Setup_phases.config_mode_corrected ~found ~applied:"0640"));
  check (option change) "the credentials mode is corrected at its site"
    (Some (Setup_changes.Corrected Setup_changes.Alloy_env_mode))
    (Setup_changes.of_correction
       (Setup_phases.env_mode_corrected ~found ~applied:"0600"));
  check (option change) "the ACME file is corrected at its site"
    (Some (Setup_changes.Corrected Setup_changes.Acme_file_permissions))
    (Setup_changes.of_correction
       (Setup_phases.acme_permissions_corrected
          ~found:(Host_answer.of_host_output "root:root 644")
          ~applied:"root:root 600"));
  check (option change) "a reading nobody could take changed nothing" None
    (Setup_changes.of_correction
       (Setup_phases.unreadable_reading ~site:Setup_phases.Alloy_config_mode
          ~detail:"ssh: timed out"))

(* A replacement is recorded as a removal and then a recreation of the same
   container, and is said once, by the recreation, which carries the reason. A
   removal nothing recreated stays: the box lost that container. A removal of
   one managed container is not settled by recreating another. *)
let test_settled () =
  let replaced =
    Setup_changes.Orchestrator_recreated
      (Setup_changes.Version
         { running = Host_answer.of_host_output "0.25.0"; wanted = "0.30.0" })
  in
  check (list change) "a completed replacement is said once, with its reason"
    [ replaced; Setup_changes.Alloy_recreated Setup_changes.Config_changed ]
    (Setup_changes.settled
       [
         Setup_changes.Orchestrator_removed;
         replaced;
         Setup_changes.Alloy_removed;
         Setup_changes.Alloy_recreated Setup_changes.Config_changed;
       ]);
  check (list change) "what lies between keeps its place"
    [
      Setup_changes.Corrected Setup_changes.Alloy_config_mode;
      Setup_changes.Alloy_recreated Setup_changes.Config_changed;
    ]
    (Setup_changes.settled
       [
         Setup_changes.Alloy_removed;
         Setup_changes.Corrected Setup_changes.Alloy_config_mode;
         Setup_changes.Alloy_recreated Setup_changes.Config_changed;
       ]);
  check (list change) "a removal nothing recreated is kept"
    [ Setup_changes.Orchestrator_removed ]
    (Setup_changes.settled [ Setup_changes.Orchestrator_removed ]);
  check (list change) "a recreation of another container settles nothing"
    [
      Setup_changes.Managed_removed "relay";
      Setup_changes.Managed_recreated "gateway";
    ]
    (Setup_changes.settled
       [
         Setup_changes.Managed_removed "relay";
         Setup_changes.Managed_recreated "gateway";
       ]);
  check (list change) "a managed replacement is said once"
    [ Setup_changes.Managed_recreated "gateway" ]
    (Setup_changes.settled
       [
         Setup_changes.Managed_removed "gateway";
         Setup_changes.Managed_recreated "gateway";
       ])

(* A stop is the first step of a replacement or a removal and is said by the
   step that completes it. One nothing completed is kept: the container is left
   stopped, which is what an operator needs to be told. *)
let test_settled_stops () =
  check (list change) "a stop the removal completed is said by the removal"
    [ Setup_changes.Alloy_removed ]
    (Setup_changes.settled
       [ Setup_changes.Alloy_stopped; Setup_changes.Alloy_removed ]);
  check (list change) "a stop the recreation completed is said by it"
    [ Setup_changes.Managed_recreated "relay" ]
    (Setup_changes.settled
       [
         Setup_changes.Managed_stopped "relay";
         Setup_changes.Managed_removed "relay";
         Setup_changes.Managed_recreated "relay";
       ]);
  check (list change) "a stop nothing followed is kept"
    [ Setup_changes.Orchestrator_stopped ]
    (Setup_changes.settled [ Setup_changes.Orchestrator_stopped ]);
  check (list change) "another container's removal does not complete it"
    [
      Setup_changes.Managed_stopped "relay";
      Setup_changes.Managed_removed "gateway";
    ]
    (Setup_changes.settled
       [
         Setup_changes.Managed_stopped "relay";
         Setup_changes.Managed_removed "gateway";
       ])

let () =
  run "Setup_changes"
    [
      ( "closing line",
        [
          test_case "every item renders" `Quick test_every_item_renders;
          test_case "the upgrade run's line" `Quick test_upgrade_line;
          test_case "a hostile running version is flattened" `Quick
            test_hostile_running_version;
          test_case "nothing changed" `Quick test_nothing_changed;
          test_case "items keep the run's order" `Quick
            test_order_is_the_run_order;
        ] );
      ( "corrections",
        [
          test_case "a correction maps to its change" `Quick test_of_correction;
        ] );
      ( "replacements",
        [
          test_case "a removal and its recreation are one change" `Quick
            test_settled;
          test_case "a stop is settled by what completes it" `Quick
            test_settled_stops;
        ] );
    ]
