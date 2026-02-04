let cmd =
  let term =
    Cmdliner.Term.(const (fun () -> print_endline "hello from init") $ const ())
  in
  let info = Cmdliner.Cmd.info "init" ~doc:"Initialize Bondi configuration." in
  Cmdliner.Cmd.v info term
