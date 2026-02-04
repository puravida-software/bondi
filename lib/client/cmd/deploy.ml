let tag_arg =
  let doc = "Deployment tag." in
  Cmdliner.Arg.(required & pos 0 (some string) None & info [] ~docv:"TAG" ~doc)

let cmd =
  let term =
    Cmdliner.Term.(
      const (fun tag -> print_endline ("hello from deploy " ^ tag)) $ tag_arg)
  in
  let info = Cmdliner.Cmd.info "deploy" ~doc:"Deploy a tagged release." in
  Cmdliner.Cmd.v info term
