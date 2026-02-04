let cmd =
  let term =
    Cmdliner.Term.(
      const (fun () -> print_endline "hello from docker ps") $ const ())
  in
  let info = Cmdliner.Cmd.info "ps" ~doc:"List Docker containers." in
  Cmdliner.Cmd.v info term
