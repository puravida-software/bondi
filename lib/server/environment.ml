let with_environment f =
  Eio_main.run @@ fun env ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let client = Docker.Client.create () in
  (* Build the outbound TLS handler once at startup; if the trust store cannot
     be loaded, run with delivery disabled rather than [~https:None]. *)
  let deliver =
    match Alert_delivery.make_https () with
    | Ok https -> Alert_delivery.deliver ~https
    | Error (Alert_delivery.Tls_setup msg) ->
        Eio.traceln "alert delivery disabled: outbound TLS setup failed: %s" msg;
        fun ~net:_ ~clock:_ ~targets:_ ~payload:_ -> ()
  in
  f ~net ~clock ~client ~deliver
