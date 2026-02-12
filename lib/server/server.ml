let start ~clock ~client ~net (config : Server_config.t) : unit Lwt.t =
  Dream.serve ~interface:"0.0.0.0" ~port:config.port
  @@ Dream.logger
  @@ Dream.router
       [
         Dream.scope "api" []
           [
             Dream.scope "v1" []
               [
                 Status.route ~client ~net;
                 Health.route;
                 Deploy.route ~clock ~net;
                 Run.route ~client ~net;
               ];
           ];
       ]
