open Alcotest
module D = Bondi_common.Defaults

let test_alloy_image_default () =
  check bool "alloy_image is non-empty" true (String.length D.alloy_image > 0)

let () =
  run "Defaults"
    [
      ( "alloy",
        [
          test_case "alloy_image default is non-empty" `Quick
            test_alloy_image_default;
        ] );
    ]
