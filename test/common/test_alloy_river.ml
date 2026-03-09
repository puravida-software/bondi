open Alcotest
module R = Bondi_common.Alloy_river

let base_config : R.config =
  {
    grafana_cloud_endpoint = "https://logs-prod.grafana.net/loki/api/v1/push";
    grafana_cloud_instance_id = "123456";
    grafana_cloud_api_key = "glc_secret_key";
    collect = All;
    labels = [];
    excluded_containers = [];
  }

let contains ~needle hay = Bondi_common.String_utils.contains ~needle hay

(* --- collect_mode_of_string --- *)

let test_collect_mode_all () =
  check (result bool string) "all parses" (Ok true)
    (Result.map (fun m -> m = R.All) (R.collect_mode_of_string "all"))

let test_collect_mode_services_only () =
  check (result bool string) "services_only parses" (Ok true)
    (Result.map
       (fun m -> m = R.Services_only)
       (R.collect_mode_of_string "services_only"))

let test_collect_mode_invalid () =
  let result = R.collect_mode_of_string "invalid_mode" in
  check bool "returns error" true (Result.is_error result);
  match result with
  | Ok _ -> fail "expected error"
  | Error msg ->
      check bool "error mentions invalid value" true
        (contains ~needle:"invalid_mode" msg);
      check bool "error mentions valid options" true
        (contains ~needle:"services_only" msg)

(* --- generate: bondi.logs drop rule --- *)

let test_generate_includes_logs_drop_rule () =
  let river = R.generate base_config in
  check bool "contains bondi.logs source label" true
    (contains ~needle:"bondi.logs" river);
  check bool "contains drop action for logs=false" true
    (contains ~needle:"\"false\"" river
    && contains ~needle:"\"drop\"" river
    && contains ~needle:"bondi.logs" river)

(* --- generate: escaping --- *)

let test_generate_escapes_endpoint () =
  let config =
    {
      base_config with
      grafana_cloud_endpoint =
        "https://logs.example.com/push?org=\"test\"&key=val";
    }
  in
  let river = R.generate config in
  check bool "endpoint quotes are escaped" true
    (contains ~needle:"\\\"test\\\"" river);
  check bool "does not contain unescaped quotes in URL" false
    (contains ~needle:"?org=\"test\"" river)

let test_generate_uses_env_for_credentials () =
  let river = R.generate base_config in
  check bool "uses env() for instance_id" true
    (contains ~needle:"env(\"GRAFANA_CLOUD_INSTANCE_ID\")" river);
  check bool "uses env() for api_key" true
    (contains ~needle:"env(\"GRAFANA_CLOUD_API_KEY\")" river);
  check bool "does not contain raw instance_id" false
    (contains ~needle:"123456" river);
  check bool "does not contain raw api_key" false
    (contains ~needle:"glc_secret_key" river)

let test_generate_escapes_labels () =
  let config =
    { base_config with labels = [ ("env", "prod\"uction"); ("a\\b", "c") ] }
  in
  let river = R.generate config in
  check bool "label value quotes escaped" true
    (contains ~needle:"prod\\\"uction" river);
  check bool "label key backslash escaped" true
    (contains ~needle:"a\\\\b" river)

let test_generate_escapes_excluded_regex () =
  let config =
    { base_config with excluded_containers = [ "my.service+name" ] }
  in
  let river = R.generate config in
  check bool "regex dot escaped" true
    (contains ~needle:"my\\.service\\+name" river)

(* --- generate: excluded_containers + collect mode integration --- *)

let test_generate_services_only_with_exclusions () =
  let config =
    {
      base_config with
      collect = Services_only;
      excluded_containers = [ "noisy-svc" ];
    }
  in
  let river = R.generate config in
  check bool "has services_only keep rule" true
    (contains ~needle:"^(service|cron)$" river);
  check bool "has exclusion rule" true (contains ~needle:"noisy-svc" river);
  check bool "has bondi.logs drop rule" true
    (contains ~needle:"bondi.logs" river)

(* --- alloy fmt validation --- *)

let run_alloy_fmt river_config =
  let path = Filename.temp_file "bondi-alloy-" ".alloy" in
  Fun.protect
    ~finally:(fun () -> Sys.remove path)
    (fun () ->
      let oc = open_out path in
      output_string oc river_config;
      close_out oc;
      let cmd =
        Printf.sprintf
          "docker run --rm -v %s:/tmp/config.alloy:ro grafana/alloy:v1.8.0 fmt \
           --test /tmp/config.alloy 2>&1"
          (Filename.quote path)
      in
      let ic = Unix.open_process_in cmd in
      let output = Buffer.create 256 in
      (try
         while true do
           Buffer.add_string output (input_line ic);
           Buffer.add_char output '\n'
         done
       with
      | End_of_file -> ());
      match Unix.close_process_in ic with
      | Unix.WEXITED 0 -> Ok ()
      | Unix.WEXITED code ->
          Error
            (Printf.sprintf "alloy fmt exited %d:\n%s" code
               (Buffer.contents output))
      | _ -> Error "alloy fmt killed/stopped")

let docker_available =
  let ic = Unix.open_process_in "docker info >/dev/null 2>&1 && echo ok" in
  let result =
    try String.trim (input_line ic) = "ok" with
    | End_of_file -> false
  in
  ignore (Unix.close_process_in ic);
  result

let test_alloy_fmt_validates_all_mode () =
  if not docker_available then Alcotest.skip ()
  else
    let river = R.generate base_config in
    match run_alloy_fmt river with
    | Ok () -> ()
    | Error msg -> Alcotest.fail msg

let test_alloy_fmt_validates_services_only () =
  if not docker_available then Alcotest.skip ()
  else
    let config =
      {
        base_config with
        collect = Services_only;
        labels = [ ("env", "production"); ("team", "backend") ];
        excluded_containers = [ "noisy-svc" ];
      }
    in
    let river = R.generate config in
    match run_alloy_fmt river with
    | Ok () -> ()
    | Error msg -> Alcotest.fail msg

let () =
  run "Alloy_river"
    [
      ( "collect_mode_of_string",
        [
          test_case "all" `Quick test_collect_mode_all;
          test_case "services_only" `Quick test_collect_mode_services_only;
          test_case "invalid with clear message" `Quick
            test_collect_mode_invalid;
        ] );
      ( "generate",
        [
          test_case "includes bondi.logs drop rule" `Quick
            test_generate_includes_logs_drop_rule;
          test_case "escapes endpoint" `Quick test_generate_escapes_endpoint;
          test_case "uses env() for credentials" `Quick
            test_generate_uses_env_for_credentials;
          test_case "escapes labels" `Quick test_generate_escapes_labels;
          test_case "escapes excluded container regex" `Quick
            test_generate_escapes_excluded_regex;
          test_case "services_only with exclusions" `Quick
            test_generate_services_only_with_exclusions;
        ] );
      ( "alloy fmt",
        [
          test_case "all mode passes alloy fmt" `Slow
            test_alloy_fmt_validates_all_mode;
          test_case "services_only with labels passes alloy fmt" `Slow
            test_alloy_fmt_validates_services_only;
        ] );
    ]
