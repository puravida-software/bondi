let cmd =
  let term =
    Cmdliner.Term.(
      const (fun () -> print_endline "hello from setup") $ const ())
  in
  let info = Cmdliner.Cmd.info "setup" ~doc:"Set up Bondi for a project." in
  Cmdliner.Cmd.v info term
