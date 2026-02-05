let cmd =
  let info = Cmdliner.Cmd.info "docker" ~doc:"Docker related commands." in
  Cmdliner.Cmd.group info [ Docker_ps.cmd; Docker_logs.cmd ]
