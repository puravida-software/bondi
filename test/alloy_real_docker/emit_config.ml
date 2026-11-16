(* What the real-Alloy script needs from this tree, printed rather than restated:
   the config [Alloy_river.generate] writes, the image the server deploys, and
   the images the script runs beside it. The script evaluates exactly this
   output, so a config it passes is the config a server would write, and never
   a copy that has drifted from it.

   The endpoint is the script's to give: it names the local Loki the script
   starts, which the script then reads to see what arrived. The credentials are
   dummies; that Loki runs without auth and ignores them.

   Alloy's journal mounts, its state bind and its storage path are printed
   from [Bondi_client.Alloy_run_args], the module that owns them for setup's
   run line, one argument per line, so the script runs Alloy with the
   arguments that ship. Only the host state directory is the script's: it is
   passed in, not edited into the output. The journal path is printed from the
   same module for the script's check that the host keeps a journal. *)

module R = Bondi_common.Alloy_river
module A = Bondi_client.Alloy_run_args

let usage =
  "usage: emit_config.exe image\n\
  \       emit_config.exe fixture-image\n\
  \       emit_config.exe loki-image\n\
  \       emit_config.exe config (all|services_only) ENDPOINT [EXCLUDED_NAME...]\n\
  \       emit_config.exe alloy-run-args (docker|alloy) HOST_STATE_DIR\n\
  \       emit_config.exe journal-path\n\
  \       emit_config.exe cron-log-args JOB\n"

(* A small image whose only job is to exist with labels and print one marker
   line. Pinned so the fixture is the same container on every machine. *)
let fixture_image = "busybox:1.37.0"

(* The Loki the generated config writes to, so the script reads what arrived
   rather than only what Alloy chose to tail. Pinned to an exact tag, as the
   Alloy image is, so every machine runs the same Loki. *)
let loki_image = "grafana/loki:3.7.9"

(* A deployed config carries the project as an external label, and a cron
   stream has to carry the same labels as a service stream. With no label here
   the two streams would agree by both lacking it, which proves nothing. *)
let project_label = ("project", "bondi-alloy-test")

let config_of collect endpoint excluded_containers : R.config =
  {
    grafana_cloud_endpoint = endpoint;
    grafana_cloud_instance_id = "unused-instance-id";
    grafana_cloud_api_key = "unused-api-key";
    collect;
    labels = [ project_label ];
    excluded_containers;
  }

let fail message =
  prerr_string message;
  exit 2

let () =
  match Array.to_list Sys.argv with
  | [ _; "image" ] -> print_endline Bondi_common.Defaults.alloy_image
  | [ _; "fixture-image" ] -> print_endline fixture_image
  | [ _; "loki-image" ] -> print_endline loki_image
  | _ :: "config" :: mode :: endpoint :: excluded -> (
      match R.collect_mode_of_string mode with
      | Ok collect ->
          print_string (R.generate (config_of collect endpoint excluded))
      | Error message -> fail (message ^ "\n" ^ usage))
  | [ _; "journal-path" ] -> print_endline A.journal_path
  | [ _; "alloy-run-args"; "docker"; host_state_dir ] ->
      List.iter print_endline (A.journal ~host_state_dir).docker_options
  | [ _; "alloy-run-args"; "alloy"; host_state_dir ] ->
      List.iter print_endline (A.journal ~host_state_dir).alloy_options
  | [ _; "cron-log-args"; job ] ->
      (* The labels are the four a cron container carries; only their names
         reach the log config. *)
      let c =
        Bondi_server.Run.cron_log_config ~job
          ~labels:
            [
              ("bondi.managed", "");
              ("bondi.type", "");
              ("bondi.logs", "");
              ("bondi.name", "");
            ]
      in
      print_endline ("--log-driver=" ^ c.type_);
      List.iter
        (fun (k, v) -> print_endline ("--log-opt=" ^ k ^ "=" ^ v))
        c.config
  | _ -> fail usage
