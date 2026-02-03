module Env = Bondi_server__Env

let ( let* ) = Result.bind

let run () =
  Eio_main.run @@ fun env ->
  let net = Eio.Stdenv.net env in
  let client = Docker.Client.create () in
  let* config = Server_config.load () in
  Ok
    ( Lwt_eio.with_event_loop ~clock:(Eio.Stdenv.clock env) @@ fun _token ->
      Lwt_eio.run_lwt (fun () -> Server.start ~client ~net config) )
