let () =
  match Bondi_server.run () with
  | Ok _ -> ()
  | Error (Bondi_server.Server_config.Invalid_port msg) ->
      Printf.eprintf "Error: %s\n" msg
