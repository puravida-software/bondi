let start ~clock ~client ~net ~deliver (config : Server_config.t) : unit Lwt.t =
  Dream.serve ~interface:config.interface ~port:config.port
  @@ Dream.logger
  @@ Dream.router
       [
         Dream.scope "api" []
           [
             Dream.scope "v1"
               [ Auth.middleware ~token:config.api_token ]
               [
                 Status.route ~client ~net ~clock;
                 Health.route;
                 Deploy.route ~clock ~net;
                 Run.route ~clock ~client ~net ~deliver;
               ];
           ];
       ]

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

let serve () =
  match Server_config.load () with
  | Error error -> Error error
  | Ok config ->
      with_environment (fun ~net ~clock ~client ~deliver ->
          Lwt_eio.with_event_loop ~clock @@ fun _token ->
          Lwt_eio.run_lwt @@ fun () -> start ~clock ~client ~net ~deliver config);
      Ok ()
