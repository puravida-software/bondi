(* Shared by the client (which decides the Docker publish address) and the
   server (which decides the bind address). The two answer different questions
   and only one of them is a security boundary -- see Cmd.Setup -- but "is this
   address confined to the host" has exactly one correct answer, and a security
   predicate that exists twice eventually disagrees with itself. *)

let is_loopback addr =
  match addr with
  | "localhost"
  | "::1"
  | "[::1]" ->
      true
  | _ ->
      (* 127.0.0.0/8 entire, not just 127.0.0.1: 127.0.0.53 is systemd-resolved
         and is just as confined. *)
      String.length addr >= 4 && String.sub addr 0 4 = "127."
