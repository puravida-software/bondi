open Alcotest
module D = Bondi_common.Defaults

let test_alloy_image_default () =
  check bool "alloy_image is non-empty" true (String.length D.alloy_image > 0)

let test_restart_policy_is_unless_stopped () =
  check string "bondi_restart_policy is unless-stopped" "unless-stopped"
    D.bondi_restart_policy

let () =
  run "Defaults"
    [
      ( "alloy",
        [
          test_case "alloy_image default is non-empty" `Quick
            test_alloy_image_default;
        ] );
      ( "restart policy",
        [
          test_case "shared policy name is unless-stopped" `Quick
            test_restart_policy_is_unless_stopped;
        ] );
    ]
