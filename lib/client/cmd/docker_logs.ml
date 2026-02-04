let container_arg =
  let doc = "Container name." in
  Cmdliner.Arg.(
    required & pos 0 (some string) None & info [] ~docv:"CONTAINER_NAME" ~doc)

let cmd =
  let term =
    Cmdliner.Term.(
      const (fun name -> print_endline ("hello from docker logs " ^ name))
      $ container_arg)
  in
  let info = Cmdliner.Cmd.info "logs" ~doc:"Show Docker container logs." in
  Cmdliner.Cmd.v info term
