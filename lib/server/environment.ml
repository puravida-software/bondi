let with_environment f =
  Eio_main.run @@ fun env ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  (* The Engine API version is gathered here, once per process, because it is a
     property of the daemon this orchestrator was started next to rather than a
     property of any one request. A daemon that cannot be asked is left to fail
     the request that needs it: the version is not what is broken then, and a
     startup that exits on it would replace a legible per-request error with an
     unexplained restart loop. *)
  let client =
    let unnegotiated = Docker.Client.create () in
    match Docker.Client.negotiate unnegotiated ~net with
    | Ok client -> client
    | Error msg ->
        Eio.traceln
          "docker api version not negotiated, using the compiled default: %s"
          msg;
        unnegotiated
  in
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
