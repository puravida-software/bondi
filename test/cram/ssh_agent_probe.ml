(* Drives the one module this directory's agent-lifecycle test is about.

   The client reaches [Ssh_agent] through the session it opens, but nothing it
   does puts a caller where the agent's own lifetime can be observed -- the
   failure arms, the teardown when a body raises, the mode of the directory
   holding the socket -- so a session file that only ran the client would assert
   nothing about any of them. This runs [with_agent] directly, against
   the same stubbed [ssh-agent] and [ssh-add] a real run would find on PATH, and
   prints one line per outcome. It is private: no public name, no package, not
   installed, and run by nothing but the session file that names it. *)

module Private_key = Bondi_client.Private_key
module Ssh_agent = Bondi_client.Ssh_agent

(* What the body does. Two shapes, because the lifetime has two ends worth
   asking about: one that returns and one that leaves by raising. *)
type body = Report_socket | Raise_from_body

exception Body_failed

let body_of = function
  | "report" -> Some Report_socket
  | "raise" -> Some Raise_from_body
  | _ -> None

let render_failure = function
  | Ssh_agent.Not_available { program } -> "not available: " ^ program
  | Ssh_agent.Spawn_failed { reason } -> "spawn failed: " ^ reason
  | Ssh_agent.Passphrase_rejected { output } ->
      "passphrase rejected: " ^ String.trim output

(* The socket's own path is a temporary directory's and differs every run, so
   what is printed is the part that does not: its name, and the mode of the
   directory holding it, which is the whole of who may sign with the key. *)
let describe agent =
  let socket = Ssh_agent.auth_sock agent in
  Printf.sprintf "ok, socket named %s in a directory at mode 0%o"
    (Filename.basename socket)
    (Unix.stat (Filename.dirname socket)).Unix.st_perm

let report ~passphrase ~key_path ~timeout_seconds =
  match
    Ssh_agent.with_agent ~timeout_seconds ~passphrase ~key_path describe
  with
  | Ok description -> print_endline description
  | Error failure -> print_endline (render_failure failure)

let raise_from_body ~passphrase ~key_path ~timeout_seconds =
  match
    Ssh_agent.with_agent ~timeout_seconds ~passphrase ~key_path (fun _ ->
        raise Body_failed)
  with
  | Ok () -> print_endline "the body did not raise"
  | Error failure -> print_endline (render_failure failure)
  | exception Body_failed ->
      print_endline "the body's exception reached the caller"

let usage = "usage: ssh_agent_probe KEY_PATH report|raise"
let passphrase_variable = "BONDI_PROBE_PASSPHRASE"

(* The bound the session would have been opened at, which the identity's life is
   derived from. Named by the scenario rather than fixed here, because what the
   file has to be able to say is that two bounds give two lifetimes; a number
   this file chose would make every scenario agree with it by construction. It
   is required rather than defaulted, so a scenario that forgot it is a scenario
   that says so. *)
let timeout_variable = "BONDI_PROBE_TIMEOUT_SECONDS"

let run ~key_path ~body ~timeout_seconds =
  match
    Option.bind (Sys.getenv_opt passphrase_variable) Private_key.passphrase
  with
  | None ->
      prerr_endline (passphrase_variable ^ " is empty or unset");
      exit 2
  | Some passphrase -> (
      match body with
      | Report_socket -> report ~passphrase ~key_path ~timeout_seconds
      | Raise_from_body ->
          raise_from_body ~passphrase ~key_path ~timeout_seconds)

let () =
  match Sys.argv with
  | [| _; key_path; body |] -> (
      match
        ( body_of body,
          Option.bind (Sys.getenv_opt timeout_variable) int_of_string_opt )
      with
      | Some body, Some timeout_seconds -> run ~key_path ~body ~timeout_seconds
      | Some _, None ->
          prerr_endline (timeout_variable ^ " is not a number or is unset");
          exit 2
      | None, _ ->
          prerr_endline usage;
          exit 2)
  | _ ->
      prerr_endline usage;
      exit 2
