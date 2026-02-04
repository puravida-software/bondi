let () =
  match Bondi_server.run () with
  | Ok _ -> ()
  (* TODO: improve the namespace here *)
  | Error (Bondi_server__Server_config.Invalid_port msg) ->
      Printf.eprintf "Error: %s\n" msg
