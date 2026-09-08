(* The process exits exactly once, here, outside any Eio switch: [Stdlib.exit]
   terminates where it stands and would skip every [Eio.Switch.on_release] a
   switch entered further in still holds. *)
let () = exit (Bondi_server.Cli.eval ())
