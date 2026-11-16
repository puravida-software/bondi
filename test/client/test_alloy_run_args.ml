open Alcotest
module Alloy_run_args = Bondi_client.Alloy_run_args

(* The expected arguments are written out here rather than built from the
   module's constants, so a constant that changes makes this fail instead of
   agreeing with itself. The host directory is deliberately not the shipped
   one, which is how a source that ignored its argument would show. *)
let test_journal_args_name_mounts_state_bind_and_storage_path () =
  let args = Alloy_run_args.journal ~host_state_dir:"/tmp/run-state" in
  check (list string) "docker options"
    [
      "--mount";
      "type=bind,source=/var/log/journal,target=/var/log/journal,readonly";
      "--mount";
      "type=bind,source=/tmp/run-state,target=/var/lib/bondi/alloy";
    ]
    args.docker_options;
  check (list string) "alloy options"
    [ "--storage.path=/var/lib/bondi/alloy" ]
    args.alloy_options;
  check string "shipped host state directory" "/var/lib/bondi/alloy"
    Alloy_run_args.state_dir

let () =
  run "Alloy_run_args"
    [
      ( "journal",
        [
          test_case "journal args name the mounts, state bind and storage path"
            `Quick test_journal_args_name_mounts_state_bind_and_storage_path;
        ] );
    ]
