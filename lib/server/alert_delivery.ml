open Eio.Std
module Alert = Bondi_common.Alert

type https =
  [ `host ] Domain_name.t ->
  Uri.t ->
  [ Eio.Flow.two_way_ty | Eio.Resource.close_ty ] r ->
  [ Eio.Flow.two_way_ty | Eio.Resource.close_ty ] r

type error = Tls_setup of string

let ( let* ) = Result.bind

let make_https () =
  let* authenticator =
    Ca_certs.authenticator ()
    |> Result.map_error (fun (`Msg msg) -> Tls_setup msg)
  in
  let* config =
    Tls.Config.client ~authenticator ()
    |> Result.map_error (fun (`Msg msg) -> Tls_setup msg)
  in
  (* The expected host is threaded in from the validated sink (parsed once at
     construction), so certificate-hostname verification never re-parses the URL
     or falls back to an unverified handshake — the partial [host_exn] path is
     gone entirely. *)
  let handler expected_host _uri raw =
    (Tls_eio.client_of_flow config ~host:expected_host raw
      :> [ Eio.Flow.two_way_ty | Eio.Resource.close_ty ] r)
  in
  Ok handler

(* 2xx is a delivered alert; any other status is a visible delivery failure.
   Bondi ascribes no finer meaning to a sink's response (FR-3) — it only ensures
   a non-2xx is surfaced in the logs rather than silently treated as success. *)
let is_success_status code = code >= 200 && code < 300

(* Fixed infrastructure bound on a single sink POST, not user config — a slow
   sink must not pin a delivery fiber open. *)
let delivery_timeout_seconds = 10.0

let post_one ~https ~net ~clock ~body_str target =
  (* Host only — the full url may embed a credential — used in every log line. *)
  let host = Alert.sink_host target in
  let headers = Cohttp.Header.init_with "Content-Type" "application/json" in
  try
    Eio.Time.with_timeout_exn clock delivery_timeout_seconds (fun () ->
        Eio.Switch.run (fun sw ->
            let handler = https (Alert.sink_host_domain target) in
            let client = Cohttp_eio.Client.make ~https:(Some handler) net in
            (* Build the request body inside the attempt: a [Body.of_string]
               flow is single-consumption. *)
            let body = Cohttp_eio.Body.of_string body_str in
            let uri = Uri.of_string (Alert.sink_url target) in
            let response, response_body =
              Cohttp_eio.Client.call client ~sw ~headers ~body `POST uri
            in
            (* Drain the response so the connection is released. *)
            let (_ : string) =
              Eio.Buf_read.(of_flow ~max_size:max_int response_body |> take_all)
            in
            let code =
              Cohttp.Code.code_of_status (Cohttp.Response.status response)
            in
            if is_success_status code then
              Eio.traceln "alert delivered to %s (HTTP %d)" host code
            else
              Eio.traceln "alert delivery to %s failed: sink returned HTTP %d"
                host code))
  with
  | (Stdlib.Exit | Eio.Cancel.Cancelled _) as exn ->
      (* Control-flow and cancellation must propagate, not be swallowed by the
         best-effort handler, or structured concurrency breaks. *)
      raise exn
  | Eio.Time.Timeout ->
      (* A slow sink is bounded and surfaced, never propagated (FR-6). *)
      Eio.traceln "alert delivery to %s failed: timed out after %.0fs" host
        delivery_timeout_seconds
  | exn ->
      (* Best-effort: log and swallow, so a failing sink never reaches the job
         path (FR-6). *)
      Eio.traceln "alert delivery to %s failed: %s" host
        (Printexc.to_string exn)

let deliver ~https ~net ~clock ~targets ~payload =
  let body_str = Yojson.Safe.to_string (Alert.payload_to_yojson payload) in
  Eio.Fiber.all
    (List.map
       (fun target () -> post_one ~https ~net ~clock ~body_str target)
       targets)
