(* How long this client waits for one box before it reports that the box did not
   answer. A [docker ps] on a host that is answering at all is immediate, and an
   operator is sitting in front of this command while it runs, so the bound is
   the patience of the person waiting rather than the cost of the work. *)
let listing_seconds = 60

let run () =
  match Config_file.read () with
  | Error message ->
      prerr_endline ("Error reading configuration: " ^ message);
      exit 1
  | Ok config -> (
      let outputs =
        List.map
          (fun server ->
            match
              (* Pass-through, like [docker logs]: what the operator is shown
                 is what the command said, on either stream. *)
              Remote_exec.docker_command_output_text
                ~standard_error:Remote_exec.Merged_always
                ~timeout_seconds:listing_seconds ~command:"ps" server
            with
            | Ok output ->
                Ok
                  (Printf.sprintf "[docker ps] Server: %s\n%s"
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
      | Some (Ok _)
      | None ->
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
