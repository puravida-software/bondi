let cmd =
  let info =
    Cmdliner.Cmd.info "bondi" ~version:"dev" ~doc:"Bondi deployment CLI."
  in
  Cmdliner.Cmd.group info
    [
      Cmd.Init.cmd;
      Cmd.Setup.cmd;
      Cmd.Deploy.cmd;
      Cmd.Status.cmd;
      Cmd.Docker.cmd;
    ]

let run () = exit (Cmdliner.Cmd.eval cmd)
