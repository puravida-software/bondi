module Workload_host_config = Bondi_server__Strategy__Workload_host_config
module Docker = Bondi_server__Docker__Client
module Restart_policy = Bondi_server__Docker__Restart_policy
module Bind_mount = Bondi_common.Bind_mount

let host_config_testable = Server_test_helpers.host_config_testable
let mount_testable = Server_test_helpers.mount_testable
let bind_mount = Test_helpers.bind_mount

(* One read-write and one read-only volume, in an order that is not sorted by
   either path, so a mapping that reordered or dropped the flag would show. *)
let volumes : Bind_mount.t list =
  [
    bind_mount ~host:"/srv/comalito/invoices" ~container:"/app/invoices"
      ~read_only:false;
    bind_mount ~host:"/etc/comalito" ~container:"/app/config" ~read_only:true;
  ]

let test_of_volumes_maps_each_volume_to_a_bind_mount () =
  Alcotest.check
    (Alcotest.option (Alcotest.list mount_testable))
    "one bind mount per volume, in order"
    (Some
       [
         {
           Docker.type_ = "bind";
           source = "/srv/comalito/invoices";
           target = "/app/invoices";
           read_only = false;
         };
         {
           Docker.type_ = "bind";
           source = "/etc/comalito";
           target = "/app/config";
           read_only = true;
         };
       ])
    (Workload_host_config.of_volumes (Some volumes)).mounts

(* The absence arm of the case above, on the same function: with nothing
   declared, the host config is the one every workload got before volumes
   existed, field for field, so the wire request is unchanged. *)
let test_of_volumes_empty_has_no_mounts_and_no_binds () =
  Alcotest.check host_config_testable "the workload host config without volumes"
    {
      binds = None;
      port_bindings = None;
      network_mode = None;
      restart_policy = Some Restart_policy.bondi_managed;
      mounts = None;
    }
    (Workload_host_config.of_volumes None)

let test_of_volumes_keeps_bondi_restart_policy () =
  let host_config = Workload_host_config.of_volumes (Some volumes) in
  Alcotest.check Alcotest.bool "restart policy is Bondi's" true
    (host_config.restart_policy = Some Restart_policy.bondi_managed);
  Alcotest.check Alcotest.bool "no Binds alongside the Mounts" true
    (host_config.binds = None)

let () =
  Alcotest.run "Workload_host_config"
    [
      ( "of_volumes",
        [
          Alcotest.test_case "maps each volume to a bind mount" `Quick
            test_of_volumes_maps_each_volume_to_a_bind_mount;
          Alcotest.test_case "empty has no mounts and no binds" `Quick
            test_of_volumes_empty_has_no_mounts_and_no_binds;
          Alcotest.test_case "keeps Bondi's restart policy" `Quick
            test_of_volumes_keeps_bondi_restart_policy;
        ] );
    ]
