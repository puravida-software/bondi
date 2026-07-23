(* POST /api/v1/run - Execute a cron job.
   Request body: {"job":"name","image":"...","env_vars":{...}} *)

open Json_helpers
module Alert = Bondi_common.Alert

let ( let* ) = Result.bind

type run_payload = {
  job : string;
  image : string;
  network : string option; [@default None]
  env_vars : string_map option; [@default None]
  alert_sinks : Alert.sinks option; [@default None]
  exit_code_severities : Strategy.Simple.exit_code_severities option;
      [@default None]
}
[@@deriving yojson]

type run_response = { exit_code : int; warning : string option [@default None] }
[@@deriving yojson]

(* Classify how the run ended: a completed container yields its exit code, an
   orchestrator-level failure before/at start yields [Start_failed] (FR-2). *)
let outcome_of_result : (int, string) result -> Alert.outcome = function
  | Ok exit_code -> Alert.Exited exit_code
  | Error msg -> Alert.Start_failed msg

let env_vars_to_list = function
  | None -> None
  | Some env -> Some (List.map (fun (k, v) -> k ^ "=" ^ v) env)

let networking_conf_of_network :
    string option -> Docker.Client.networking_config option = function
  | None -> None
  | Some network ->
      let endpoint : Docker.Client.endpoint_config =
        { aliases = None; ipv4_address = None }
      in
      Some { endpoints_config = Some [ (network, endpoint) ] }

let parse_image image = Strategy.Simple.require_image_and_tag image

let temp_container_name job =
  let ts = Unix.gettimeofday () |> Float.to_string in
  Printf.sprintf "%s-%s" job ts

let best_effort_remove_old ~client ~net ~job =
  match Docker.Client.get_container_by_name client ~net ~container_name:job with
  | Error msg -> Some ("failed to look up old container: " ^ msg)
  | Ok None -> None
  | Ok (Some old) -> (
      match Docker.Client.remove_container client ~net ~container_id:old.id with
      | Ok () -> None
      | Error msg -> Some ("failed to remove old container: " ^ msg))

let best_effort_rename ~client ~net ~container_id ~job =
  match
    Docker.Client.rename_container client ~net ~container_id ~new_name:job
  with
  | Ok () -> None
  | Error msg -> Some ("failed to rename container: " ^ msg)

let combine_warnings w1 w2 =
  match (w1, w2) with
  | None, None -> None
  | Some w, None
  | None, Some w ->
      Some w
  | Some a, Some b -> Some (a ^ "; " ^ b)

let run_opts ~container_name ~full_image payload :
    Docker.Client.run_image_options =
  let config : Docker.Client.container_config =
    {
      image = Some full_image;
      env = env_vars_to_list payload.env_vars;
      cmd = None;
      entrypoint = None;
      hostname = None;
      working_dir = None;
      labels =
        Some
          [
            ("bondi.managed", "true");
            ("bondi.type", "cron");
            ("bondi.logs", "true");
          ];
      exposed_ports = None;
    }
  in
  {
    container_name;
    config;
    host_config = None;
    networking_conf = networking_conf_of_network payload.network;
  }

(* Plan the alert for a run outcome, purely. An unconfigured job falls to the
   default map and an unconfigured sink set is empty, so [Alert.plan] emits
   nothing rather than any implied target (NFR-2). Split from [dispatch_alert] so
   the defaulting and routing are testable without a clock or a deliverer. *)
let plan_for_payload payload outcome ~timestamp =
  let severity_map =
    Option.value payload.exit_code_severities
      ~default:Alert.default_severity_map
  in
  let sinks =
    Option.value payload.alert_sinks
      ~default:{ Alert.critical = []; failure = [] }
  in
  Alert.plan severity_map outcome sinks ~job:payload.job ~timestamp

(* Classify the run outcome and, when it routes to sinks, hand the planned alert
   to the injected deliverer. *)
let dispatch_alert ~deliver ~payload ~outcome =
  match plan_for_payload payload outcome ~timestamp:(Unix.gettimeofday ()) with
  | None -> ()
  | Some ({ targets; payload = alert_payload } : Alert.dispatch) ->
      deliver ~targets ~payload:alert_payload

let run ~client ~net ~deliver body =
  let* payload =
    match Yojson.Safe.from_string body with
    | exception Yojson.Json_error msg -> Error ("invalid JSON: " ^ msg)
    | json ->
        run_payload_of_yojson json
        |> Result.map_error (fun msg -> "invalid run payload: " ^ msg)
  in
  let* image_name, tag = parse_image payload.image in
  let full_image = image_name ^ ":" ^ tag in
  let container_name = temp_container_name payload.job in
  let opts = run_opts ~container_name ~full_image payload in
  (* Capture either the container's exit code or an orchestrator-start error;
     both classify into an outcome so a job that never ran still alerts (FR-2). *)
  let started = Docker.Client.run_image_with_opts client ~net opts in
  let run_result =
    let* container_id = started in
    Docker.Client.wait_container client ~net ~container_id
  in
  let response =
    match (started, run_result) with
    | Ok container_id, Ok exit_code ->
        let w1 = best_effort_remove_old ~client ~net ~job:payload.job in
        let w2 =
          best_effort_rename ~client ~net ~container_id ~job:payload.job
        in
        Ok { exit_code; warning = combine_warnings w1 w2 }
    | Error msg, _ -> Error msg
    | _, Error msg -> Error msg
  in
  (* Delivery is a bounded, best-effort side channel run after the outcome is
     recorded and the container is cleaned up: it cannot change the returned
     outcome (FR-6), though being synchronous it may delay this response by up to
     one per-sink timeout. *)
  dispatch_alert ~deliver ~payload ~outcome:(outcome_of_result run_result);
  response

let route ~clock ~client ~net ~deliver =
  Dream.post "/run" @@ fun req ->
  let%lwt body = Dream.body req in
  let post_alert ~targets ~payload = deliver ~net ~clock ~targets ~payload in
  match run ~client ~net ~deliver:post_alert body with
  | Ok response ->
      response |> run_response_to_yojson |> Yojson.Safe.to_string |> Dream.json
  | Error msg -> Dream.respond ~status:`Not_Found ("Run failed: " ^ msg)
