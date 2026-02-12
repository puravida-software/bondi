let container_arg =
  let doc = "Container name." in
  Cmdliner.Arg.(
    required & pos 0 (some string) None & info [] ~docv:"CONTAINER_NAME" ~doc)

let run container_name =
  let container_name = String.trim container_name in
  if container_name = "" then (
    prerr_endline "Error: container name cannot be empty";
    exit 1);
  match Config_file.read () with
  | Error message ->
      prerr_endline ("Error reading configuration: " ^ message);
      exit 1
  | Ok config -> (
      let outputs =
        List.map
          (fun server ->
            match
              Docker_common.docker_command_output
                ~command:("logs " ^ container_name) server
            with
            | Ok output ->
                Ok
                  (Printf.sprintf "[docker logs] Server: %s\n%s"
                     server.Config_file.ip_address output)
            | Error err -> Error err)
          (Config_file.servers config)
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
  let term = Cmdliner.Term.(const run $ container_arg) in
  let info = Cmdliner.Cmd.info "logs" ~doc:"Show Docker container logs." in
  Cmdliner.Cmd.v info term
