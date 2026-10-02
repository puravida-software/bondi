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

let contains = Test_helpers.contains

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

(* --- generate: relabel rules --- *)

(* These pin the text the generator emits; whether Alloy keeps and drops the
   right containers on those rules is judged by a real Alloy against real
   labelled containers, in test/alloy_real_docker. *)

let keep_rule =
  "source_labels = [\"__meta_docker_container_label_bondi_type\"]\n\
   \t\tregex         = \"^(service|cron)$\"\n\
   \t\taction        = \"keep\""

let logs_drop_rule =
  "source_labels = [\"__meta_docker_container_label_bondi_logs\"]\n\
   \t\tregex         = \"false\"\n\
   \t\taction        = \"drop\""

let test_relabel_keep_rule_only_in_services_only () =
  check bool "services_only keeps service and cron" true
    (contains ~needle:keep_rule
       (R.generate { base_config with collect = Services_only }));
  check bool "all has no keep rule" false
    (contains ~needle:keep_rule (R.generate { base_config with collect = All }))

let test_relabel_logs_drop_rule_in_both_modes () =
  List.iter
    (fun collect ->
      check bool "bondi_logs drop rule present" true
        (contains ~needle:logs_drop_rule
           (R.generate { base_config with collect })))
    [ R.All; R.Services_only ]

let test_relabel_reads_no_dotted_label_names () =
  List.iter
    (fun collect ->
      let river = R.generate { base_config with collect } in
      check bool "no bare bondi.type source" false
        (contains ~needle:"source_labels = [\"bondi.type\"]" river);
      check bool "no bare bondi.logs source" false
        (contains ~needle:"source_labels = [\"bondi.logs\"]" river))
    [ R.All; R.Services_only ]

let test_relabel_container_name_precedes_bondi_name () =
  let river = R.generate base_config in
  let fallback =
    Bondi_common.String_utils.index_of
      ~needle:
        "[\"__meta_docker_container_name\"]\n\t\tregex         = \"/(.*)\""
      river
  in
  let override =
    Bondi_common.String_utils.index_of
      ~needle:"[\"__meta_docker_container_label_bondi_name\"]" river
  in
  match (fallback, override) with
  | Some f, Some o -> check bool "fallback precedes override" true (f < o)
  | _ -> fail "container rules missing"

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
  check bool "uses sys.env() for instance_id" true
    (contains ~needle:"sys.env(\"GRAFANA_CLOUD_INSTANCE_ID\")" river);
  check bool "uses sys.env() for api_key" true
    (contains ~needle:"sys.env(\"GRAFANA_CLOUD_API_KEY\")" river);
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

(* --- env_file_contents --- *)

(* The generated config and the env file that feeds it are two halves of one
   contract, so the expected variable set is read out of [generate]'s own output
   rather than restated here: a name added to one half alone then reddens.

   What this derivation does NOT cover: it sees a variable only where the River
   text spells it [sys.env("NAME")]. A value Alloy picks up by any other route —
   a command-line argument, a file it reads itself, a River builtin other than
   [sys.env] — is invisible to it, and the drift claim above is bounded to that. *)
let sys_env_references river =
  let opener = "sys.env(\"" in
  let len = String.length river in
  let rec collect acc offset =
    if offset >= len then List.rev acc
    else
      let rest = String.sub river offset (len - offset) in
      match Bondi_common.String_utils.index_of ~needle:opener rest with
      | None -> List.rev acc
      | Some i -> (
          let name_start = offset + i + String.length opener in
          let after = String.sub river name_start (len - name_start) in
          match String.index_opt after '"' with
          | None -> List.rev acc
          | Some j -> collect (String.sub after 0 j :: acc) (name_start + j + 1)
          )
  in
  collect [] 0

(* [KEY=VALUE] is the undelimited [field=value] shape a substring assertion
   aliases on — ["...ID=1"] matches ["...ID=10"] — so the env file is parsed into
   whole pairs and compared as a list instead. A line carrying no [=] is mapped
   to a value that cannot be confused with an empty one, so a malformed line
   fails legibly rather than as [("KEY", "")]. *)
let env_file_entries contents =
  String.split_on_char '\n' contents
  |> List.filter (fun line -> line <> "")
  |> List.map (fun line ->
      match String.index_opt line '=' with
      | None -> (line, "<line carries no '='>")
      | Some i ->
          ( String.sub line 0 i,
            String.sub line (i + 1) (String.length line - i - 1) ))

(* Every field is set explicitly rather than by [{ base_config with ... }]: the
   collect mode, the labels and the exclusions all change what [generate] emits,
   and an absence assertion inheriting one of them unseen is an absence that
   might be the fixture's rather than the code's. *)
let credential_config : R.config =
  {
    grafana_cloud_endpoint = "https://logs-prod-eu.grafana.net/loki/api/v1/push";
    grafana_cloud_instance_id = "instance-9182736450";
    grafana_cloud_api_key = "glc_notarealkey_0192837465";
    collect = All;
    labels = [];
    excluded_containers = [];
  }

let test_env_file_contents_supplies_every_referenced_variable () =
  let referenced = sys_env_references (R.generate credential_config) in
  check (list string) "generate reads exactly these variables through sys.env"
    [ "GRAFANA_CLOUD_INSTANCE_ID"; "GRAFANA_CLOUD_API_KEY" ]
    referenced;
  let declared =
    List.map fst (env_file_entries (R.env_file_contents credential_config))
  in
  check (list string) "env file declares exactly the variables generate reads"
    referenced declared

let test_env_file_contents_carries_the_credential_values () =
  check
    (list (pair string string))
    "each variable carries the value configured for it"
    [
      ("GRAFANA_CLOUD_INSTANCE_ID", "instance-9182736450");
      ("GRAFANA_CLOUD_API_KEY", "glc_notarealkey_0192837465");
    ]
    (env_file_entries (R.env_file_contents credential_config))

(* The absence arms below pass against an empty string and against a fixture that
   stopped carrying credentials at all, so the affirmative arms come first and on
   the same fixture: these values do reach the host, by the env file. *)
let test_generated_config_contains_no_credential_value () =
  let river = R.generate credential_config in
  let env_file = R.env_file_contents credential_config in
  check bool "env file carries the instance id" true
    (contains ~needle:credential_config.grafana_cloud_instance_id env_file);
  check bool "env file carries the api key" true
    (contains ~needle:credential_config.grafana_cloud_api_key env_file);
  check bool "generated config carries no instance id value" false
    (contains ~needle:credential_config.grafana_cloud_instance_id river);
  check bool "generated config carries no api key value" false
    (contains ~needle:credential_config.grafana_cloud_api_key river)

(* --- alloy fmt validation --- *)

let run_alloy_fmt river_config =
  let path = Filename.temp_file "bondi-alloy-" ".alloy" in
  Fun.protect
    ~finally:(fun () -> Sys.remove path)
    (fun () ->
      let oc = open_out path in
      output_string oc river_config;
      close_out oc;
      (* [Z] relabels the bind mount for SELinux hosts; without it the
         container cannot read the file. Ignored where SELinux is absent. *)
      let cmd =
        Printf.sprintf
          "docker run --rm -v %s:/tmp/config.alloy:ro,Z grafana/alloy:v1.8.0 \
           fmt --test /tmp/config.alloy 2>&1"
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
      | Unix.WSIGNALED signal ->
          Error (Printf.sprintf "alloy fmt killed by signal %d" signal)
      | Unix.WSTOPPED signal ->
          Error (Printf.sprintf "alloy fmt stopped by signal %d" signal))

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
          test_case "escapes endpoint" `Quick test_generate_escapes_endpoint;
          test_case "uses env() for credentials" `Quick
            test_generate_uses_env_for_credentials;
          test_case "escapes labels" `Quick test_generate_escapes_labels;
          test_case "escapes excluded container regex" `Quick
            test_generate_escapes_excluded_regex;
        ] );
      ( "relabel rules",
        [
          test_case "keep rule only in services_only" `Quick
            test_relabel_keep_rule_only_in_services_only;
          test_case "logs drop rule in both modes" `Quick
            test_relabel_logs_drop_rule_in_both_modes;
          test_case "reads no dotted label names" `Quick
            test_relabel_reads_no_dotted_label_names;
          test_case "container name precedes bondi.name" `Quick
            test_relabel_container_name_precedes_bondi_name;
        ] );
      ( "env_file_contents",
        [
          test_case "supplies every variable the config references" `Quick
            test_env_file_contents_supplies_every_referenced_variable;
          test_case "carries the credential values" `Quick
            test_env_file_contents_carries_the_credential_values;
          test_case "generated config contains no credential value" `Quick
            test_generated_config_contains_no_credential_value;
        ] );
      ( "alloy fmt",
        [
          test_case "all mode passes alloy fmt" `Slow
            test_alloy_fmt_validates_all_mode;
          test_case "services_only with labels passes alloy fmt" `Slow
            test_alloy_fmt_validates_services_only;
        ] );
    ]
