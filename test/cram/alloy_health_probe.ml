(* Prints the shell [Alloy_health.probe_command] hands to the server, so that a
   cram test can run it with [sh -c] against stand-in [curl] scripts. The shell
   is the part of the module no unit test executes. *)

let () =
  print_string
    (Bondi_client.Alloy_health.probe_command ~port:12345 ~timeout_s:1)
