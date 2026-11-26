(* The `run` subcommand - Execute a cron job.
   Payload on standard input: {"job":"name","image":"...","env_vars":{...}} *)

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
   orchestrator-level failure before/at start yields [Start_failed]. *)
let outcome_of_result : (int, string) result -> Alert.outcome = function
  | Ok exit_code -> Alert.Exited exit_code
  | Error msg -> Alert.Start_failed msg

(* The crontab line carries only the non-secret environment; the rest is read
   from the job's mode-600 file, written at deploy time. A job with no file --
   one deployed before this existed -- runs on what the line carries, rather
   than failing, so the change is not a flag day for already-scheduled jobs. *)
let env_for_job ~job env_vars =
  let plain = Option.value env_vars ~default:[] in
  let secret = Cron_secrets.read_env_file job in
  match Cron_secrets.merge ~plain ~secret with
  | [] -> None
  | entries -> Some entries

let networking_conf_of_network :
    string option -> Docker.Client.networking_config option = function
  | None -> None
  | Some network ->
      let endpoint : Docker.Client.endpoint_config =
        { aliases = None; ipv4_address = None }
      in
      Some { endpoints_config = Some [ (network, endpoint) ] }

(* The image to run, as written, when it parses and pins a tag or a digest. The
   reference is printed back whole, so a registry port and a digest reach the
   container unchanged. A refusal of an image that does not parse names the
   field and restates the grammar, in the deploy decoder's words, without the
   rejected text: it may hold a pasted credential, and the message never
   carries a value from the payload (see [Handler_error.message]). *)
let parse_image image =
  match Bondi_common.Image_reference.of_string image with
  | Error (Bondi_common.Image_reference.Empty | Malformed _) ->
      Error (Payload_codec.image_reference_refusal ~field:"image")
  | Ok reference ->
      Result.map Bondi_common.Image_reference.to_string
        (Payload_codec.require_tag_or_digest reference)

let temp_container_name job =
  let ts = Unix.gettimeofday () |> Float.to_string in
  Printf.sprintf "%s-%s" job ts

let combine_warnings w1 w2 =
  match (w1, w2) with
  | None, None -> None
  | Some w, None
  | None, Some w ->
      Some w
  | Some a, Some b -> Some (a ^ "; " ^ b)

type existing =
  | No_container
  | Own_cron_container of string
  | Foreign of string

(* The labels that make a container this job's own. [run_opts] writes them and
   [existing_of] reads them, from these two bindings, so what a pass leaves
   behind is what the next pass recognises. *)
let cron_type_label = ("bondi.type", "cron")
let job_label_key = "bondi.name"

let existing_of ~job = function
  | None -> No_container
  | Some (container : Docker.Client.container) -> (
      let labels = Option.value container.labels ~default:[] in
      let type_key, type_value = cron_type_label in
      let carries key value =
        Option.equal String.equal (List.assoc_opt key labels) (Some value)
      in
      match (carries type_key type_value, carries job_label_key job) with
      | true, true -> Own_cron_container container.id
      | true, false
      | false, true
      | false, false ->
          Foreign job)

(* What the refusal says, at either point it is reached. It names the container
   and the labels it lacks, and says it was left alone, because the operator
   reading it in cron's mail has to find that container and decide about it. *)
let foreign_label_clause name =
  Printf.sprintf
    "the container named %s was not made by this job: it does not carry both \
     %s=%s and %s=%s, so it was left untouched"
    name (fst cron_type_label) (snd cron_type_label) job_label_key name

let refusal_before_start name =
  Printf.sprintf "refusing to run cron job %s: %s" name
    (foreign_label_clause name)

let refusal_at_cleanup name =
  Printf.sprintf
    "cron job %s finished, but %s, and the pass kept its temporary name" name
    (foreign_label_clause name)

let start_unless_foreign ~refuse ~lookup ~start =
  match lookup () with
  | Error _ as unread -> unread
  | Ok (No_container | Own_cron_container _) -> start ()
  | Ok (Foreign name) ->
      let msg = refusal_before_start name in
      refuse msg;
      Error msg

let cleanup_of_existing ~refuse ~remove ~rename ~lookup =
  match lookup () with
  | Error msg -> Ok (combine_warnings (Some msg) (rename ()))
  | Ok No_container -> Ok (rename ())
  | Ok (Own_cron_container old_id) ->
      (* Bound in turn, not passed as two arguments: OCaml evaluates arguments
         right to left, and a rename attempted before the removal is refused
         as a conflict, leaving no container under the name. *)
      let removed = remove old_id in
      let renamed = rename () in
      Ok (combine_warnings removed renamed)
  | Ok (Foreign name) ->
      let msg = refusal_at_cleanup name in
      refuse msg;
      Error msg

let settle ~cleaned run_result =
  match cleaned with
  | Error refusal -> (Error refusal, None)
  | Ok warning -> (run_result, warning)

(* The warnings of the two cleanup steps name the job and the container, as the
   lookup's does: they reach cron's mail with nothing else to say whose they
   are. *)
let best_effort_remove ~client ~net ~job ~container_id =
  match Docker.Client.remove_container client ~net ~container_id with
  | Ok () -> None
  | Error msg ->
      Some
        (Printf.sprintf "failed to remove old container %s of cron job %s: %s"
           container_id job msg)

(* The impure half of the verdict: what is under the job's name now. A listing
   that fails names the job it was read for, since the message reaches cron's
   mail with nothing else to say which job's run it came from. *)
let existing_under_name ~client ~net ~job =
  Docker.Client.get_container_by_name client ~net ~container_name:job
  |> Result.map (existing_of ~job)
  |> Result.map_error (fun msg ->
      Printf.sprintf "failed to look up container %s: %s" job msg)

let best_effort_rename ~client ~net ~container_id ~job =
  match
    Docker.Client.rename_container client ~net ~container_id ~new_name:job
  with
  | Ok () -> None
  | Error msg ->
      Some
        (Printf.sprintf "failed to rename container %s of cron job %s: %s"
           container_id job msg)

(* A pass can exit before Alloy's Docker discovery ever lists it, so its lines
   leave through the journal. The tag is the job, for the same reason
   bondi.name is; labels names every label given, so each reaches the journal
   as a field the Alloy relabel rules read. The driver's cache is left on,
   which is what keeps docker logs working. *)
let cron_log_config ~job ~labels : Docker.Client.log_config =
  {
    type_ = "journald";
    config =
      [ ("tag", job); ("labels", String.concat "," (List.map fst labels)) ];
  }

let run_opts ~container_name ~full_image payload :
    Docker.Client.run_image_options =
  let labels =
    [
      ("bondi.managed", "true");
      cron_type_label;
      ("bondi.logs", "true");
      (* The job, not [container_name]: a pass runs under a timestamped
         temporary name, and the log stream must stay one per job. *)
      (job_label_key, payload.job);
    ]
  in
  let config : Docker.Client.container_config =
    {
      image = Some full_image;
      env = env_for_job ~job:payload.job payload.env_vars;
      cmd = None;
      entrypoint = None;
      hostname = None;
      working_dir = None;
      labels = Some labels;
      exposed_ports = None;
    }
  in
  {
    container_name;
    config;
    host_config =
      Some
        {
          binds = None;
          port_bindings = None;
          network_mode = None;
          (* None, not "no": a cron pass is one-shot and states no policy. *)
          restart_policy = None;
          mounts = None;
          log_config = Some (cron_log_config ~job:payload.job ~labels);
        };
    networking_conf = networking_conf_of_network payload.network;
  }

(* Plan the alert for a run outcome, purely. An unconfigured job falls to the
   default map and an unconfigured sink set is empty, so [Alert.plan] emits
   nothing rather than any implied target. Split from [dispatch_alert] so
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

(* The rejected body's keys are named; its values never are. A run payload
   carries env_vars and sink URLs that may embed credentials, and this message
   is returned to whoever ran the subcommand and mailed by cron. Without the
   key list the ppx's message names only the type that failed, which cannot
   distinguish a misspelled field from a missing one — the two most likely ways
   a hand-edited crontab line goes wrong. *)
let decode_payload body =
  match Yojson.Safe.from_string body with
  | exception Yojson.Json_error msg ->
      Error (Handler_error.Invalid_request ("invalid JSON: " ^ msg))
  | json ->
      run_payload_of_yojson json
      |> Result.map_error (fun msg ->
          Handler_error.Invalid_request
            (Printf.sprintf "invalid run payload: %s (keys received: %s)" msg
               (String.concat ", " (top_level_keys json))))

(* Decode the body and require a tagged image before anything is started. A body
   that does not decode names no job and carries no sinks, so it cannot alert —
   the crontab command's non-zero exit is its only failure channel. A
   payload that did decode knows both, so an untagged image dispatches here
   rather than short-circuiting past the dispatch point at the end of [run]. *)
let prepare ~deliver body : (run_payload * string, Handler_error.t) result =
  let* payload = decode_payload body in
  match parse_image payload.image with
  | Error msg ->
      dispatch_alert ~deliver ~payload ~outcome:(outcome_of_result (Error msg));
      Error (Handler_error.Invalid_request msg)
  | Ok full_image -> Ok (payload, full_image)

(* Classify the container lifecycle result: a Docker-level failure is Bondi's
   fault, not the caller's. *)
let response_of_run_result ~warning :
    (int, string) result -> (run_response, Handler_error.t) result = function
  | Ok exit_code -> Ok { exit_code; warning }
  | Error msg -> Error (Handler_error.Orchestrator_failure msg)

(* Whether the post-run cleanup happens, and what it reported. Cleanup runs only
   when the container both started and finished: removing the previous container
   before a failed run has been reported would destroy the only record of what
   ran last, and renaming a container that never started has nothing to rename.
   Taking [cleanup] as a parameter keeps that decision pure and testable, with
   the Docker calls it needs supplied by [run]. *)
let warning_of_run ~cleanup ~started ~run_result =
  match (started, run_result) with
  | Ok container_id, Ok _ -> cleanup container_id
  | Ok _, Error _
  | Error _, Ok _
  | Error _, Error _ ->
      Ok None

(* The whole decision, with no transport named.

   [deliver] arrives in the shape [Environment.with_environment] builds, and the
   resources it needs are bound here rather than by the caller: a caller that
   had to pre-bind [net] and [clock] itself would be reconstructing part of this
   function, which is the thing this signature exists to make unnecessary. The
   pure seams below it take the already-bound form, because none of them has a
   net or a clock to give.

   There is no catch-all here, unlike [Status.report] and [Deploy.deploy]. An
   exception that escapes is classified by [Cli]'s own subcommand boundary,
   which records the raw backtrace on the diagnostics stream before answering
   [Orchestrator_failure]; catching it here would answer the same class with the
   backtrace already lost. *)
let run ~clock ~client ~net ~deliver body =
  let post_alert ~targets ~payload = deliver ~net ~clock ~targets ~payload in
  let* payload, full_image = prepare ~deliver:post_alert body in
  let job = payload.job in
  let container_name = temp_container_name job in
  let opts = run_opts ~container_name ~full_image payload in
  (* Capture either the container's exit code or an orchestrator-start error;
     both classify into an outcome so a job that never ran still alerts. The
     name is read before the start, so a container under it that this job did
     not make refuses the run before anything is started. *)
  let lookup () = existing_under_name ~client ~net ~job in
  let started =
    start_unless_foreign ~refuse:Diagnostics.to_container_log ~lookup
      ~start:(fun () -> Docker.Client.run_image_with_opts client ~net opts)
  in
  let run_result =
    let* container_id = started in
    Docker.Client.wait_container client ~net ~container_id
  in
  (* The name is read again at cleanup: a container that took it while the pass
     ran is judged by the same verdict, and is never removed. *)
  let cleaned =
    warning_of_run ~started ~run_result ~cleanup:(fun container_id ->
        cleanup_of_existing ~refuse:Diagnostics.to_container_log
          ~remove:(fun old_id ->
            best_effort_remove ~client ~net ~job ~container_id:old_id)
          ~rename:(fun () -> best_effort_rename ~client ~net ~container_id ~job)
          ~lookup)
  in
  let finished, warning = settle ~cleaned run_result in
  let response = response_of_run_result ~warning finished in
  (* Delivery is a bounded, best-effort side channel run after the outcome is
     recorded and the container is cleaned up: it cannot change the returned
     outcome, though being synchronous it may delay this response by up to
     one per-sink timeout. *)
  dispatch_alert ~deliver:post_alert ~payload
    ~outcome:(outcome_of_result finished);
  response
