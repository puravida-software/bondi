(* What the real-Alloy script needs from this tree, printed rather than restated:
   the config [Alloy_river.generate] writes, and the image the server deploys.
   The script evaluates exactly this output, so a config it passes is the
   config a server would write, and never a copy that has drifted from it.

   The credentials are dummies and the endpoint is a port nothing listens on:
   the Alloy this feeds pushes nowhere, and the script reads only what its
   discovery and relabel components compute. *)

module R = Bondi_common.Alloy_river

let usage =
  "usage: emit_config.exe image\n\
  \       emit_config.exe fixture-image\n\
  \       emit_config.exe config (all|services_only) [EXCLUDED_NAME...]\n"

(* A small image whose only job is to exist with labels. Pinned so the fixture
   is the same container on every machine. *)
let fixture_image = "busybox:1.37.0"

let config_of collect excluded_containers : R.config =
  {
    grafana_cloud_endpoint = "http://127.0.0.1:1/loki/api/v1/push";
    grafana_cloud_instance_id = "unused-instance-id";
    grafana_cloud_api_key = "unused-api-key";
    collect;
    labels = [];
    excluded_containers;
  }

let fail message =
  prerr_string message;
  exit 2

let () =
  match Array.to_list Sys.argv with
  | [ _; "image" ] -> print_endline Bondi_common.Defaults.alloy_image
  | [ _; "fixture-image" ] -> print_endline fixture_image
  | _ :: "config" :: mode :: excluded -> (
      match R.collect_mode_of_string mode with
      | Ok collect -> print_string (R.generate (config_of collect excluded))
      | Error message -> fail (message ^ "\n" ^ usage))
  | _ -> fail usage
