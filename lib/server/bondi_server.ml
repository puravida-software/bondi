module Env = Bondi_server__Env

let ( let* ) = Result.bind

let run () =
  Eio_main.run @@ fun env ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let client = Docker.Client.create () in
  let* config = Server_config.load () in
  Ok
    ( Lwt_eio.with_event_loop ~clock @@ fun _token ->
      Lwt_eio.run_eio @@ fun () -> Server.start ~clock ~client ~net config )
