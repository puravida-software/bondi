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
                 Status.route ~client ~net;
                 Health.route;
                 Deploy.route ~clock ~net;
                 Run.route ~clock ~client ~net ~deliver;
               ];
           ];
       ]
