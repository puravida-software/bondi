let run () =
  match Config_file.read () with
  | Error message ->
      prerr_endline ("Error reading configuration: " ^ message);
      exit 1
  | Ok config -> (
      let outputs =
        List.map
          (fun server ->
            match Docker_common.docker_command_output ~command:"ps" server with
            | Ok output ->
                Ok
                  (Printf.sprintf "[docker ps] Server: %s\n%s"
                     server.Config_file.ip_address output)
            | Error err -> Error err)
          config.user_service.servers
      in
      match
        List.find_opt
          (function
            | Error _ -> true
            | Ok _ -> false)
          outputs
      with
      | Some (Error err) ->
          prerr_endline err;
          exit 1
      | _ ->
          outputs
          |> List.filter_map (function
            | Ok value -> Some value
            | Error _ -> None)
          |> String.concat ""
          |> print_string)

let cmd =
  let term = Cmdliner.Term.(const run $ const ()) in
  let info = Cmdliner.Cmd.info "ps" ~doc:"List Docker containers." in
  Cmdliner.Cmd.v info term
