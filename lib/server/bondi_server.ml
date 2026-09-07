module Env = Bondi_server__Env
module Auth = Bondi_server__Auth
module Server_config = Bondi_server__Server_config
module Cron_secrets = Bondi_server__Cron_secrets
module Diagnostics = Bondi_server__Diagnostics
module Handler_error = Bondi_server__Handler_error
module Health = Bondi_server__Health
module Status = Bondi_server__Status
module Deploy = Bondi_server__Deploy
module Run = Bondi_server__Run
module Crontab = Bondi_server__Crontab
module Docker = Bondi_server__Docker
module Strategy = Bondi_server__Strategy

let ( let* ) = Result.bind

let run () =
  Eio_main.run @@ fun env ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let client = Docker.Client.create () in
  let* config = Server_config.load () in
  (* Build the outbound TLS handler once at startup; if the trust store cannot
     be loaded, run with delivery disabled rather than [~https:None]. *)
  let deliver =
    match Alert_delivery.make_https () with
    | Ok https -> Alert_delivery.deliver ~https
    | Error (Alert_delivery.Tls_setup msg) ->
        Eio.traceln "alert delivery disabled: outbound TLS setup failed: %s" msg;
        fun ~net:_ ~clock:_ ~targets:_ ~payload:_ -> ()
  in
  Ok
    ( Lwt_eio.with_event_loop ~clock @@ fun _token ->
      Lwt_eio.run_lwt @@ fun () ->
      Server.start ~clock ~client ~net ~deliver config )
