module String_utils = Bondi_common.String_utils

let ( let* ) = Result.bind

type t = { auth_sock : string; public_half : string }

type failure =
  | Not_available of { program : string }
  | Spawn_failed of { reason : string }
  | Passphrase_rejected of { output : string }

let auth_sock agent = agent.auth_sock
let public_half agent = agent.public_half
let agent_program = "ssh-agent"
let add_program = "ssh-add"

(* The name every OpenSSH client reads to find an agent. Spelled once: the
   loading program, the teardown and the client this module exists to serve all
   have to name the same variable, and three literals are three chances for one
   of them to name a different one. *)
let auth_sock_variable = "SSH_AUTH_SOCK"

(* The name the helper reads the secret out of. It is set in the loading
   program's environment, and the helper inherits it from there -- so it is in
   two process environments and in no file, which is what lets the helper itself
   be a file on disk with no secret in it. *)
let passphrase_variable = "BONDI_KEY_PASSPHRASE"

(* The margin between the bound a command is held to and the life of the
   identity it signs with. It covers what happens on either side of the command
   itself -- the identity being loaded, the client being spawned, the connection
   being opened -- so that a command allowed to run to its own deadline is not
   racing the key it needs at the end of it. *)
let identity_margin_seconds = 60

(* How long a loaded identity stays usable. A process killed outright runs no
   teardown, and what is left behind is an agent holding a key that can sign --
   so the identity is given a life of its own rather than the session's.

   Derived from the bound rather than fixed, because the property wanted is that
   the identity outlive the command, and a constant only asserts it: the fifteen
   minutes this used to be was already shorter than [Cmd.Deploy]'s own bound of
   1800 and equal to [Cmd.Setup]'s 900, so the assertion was false in this
   repository on the day it was written.

   NOT covered: a session that issues several commands, whose wall clock can
   exceed the single bound each of them is held to. What this derivation bounds
   is a command, not a session -- a session that spends its whole budget on one
   call and then makes another re-dials against an agent that has dropped the
   identity, and reports it as the host refusing a public key. Widening it would
   mean the session telling the agent how long it intends to live, which is a
   number no caller has. *)
let identity_lifetime_seconds ~timeout_seconds =
  timeout_seconds + identity_margin_seconds

(* [ssh-agent] prints shell assignments; the pid among them is what its own [-k]
   needs to find the agent again. Splitting on both separators it uses leaves
   each assignment alone, and a token that is not a number is not a pid. *)
let agent_pid_marker = "SSH_AGENT_PID="

let agent_pid output =
  String.split_on_char '\n' output
  |> List.concat_map (String.split_on_char ';')
  |> List.map String.trim
  |> List.find_map (fun token ->
      match String_utils.starts_with ~prefix:agent_pid_marker token with
      | false -> None
      | true ->
          int_of_string_opt
            (String.sub token
               (String.length agent_pid_marker)
               (String.length token - String.length agent_pid_marker)))

(* A name already in the inherited environment is replaced rather than appended
   to. A second assignment of the same name is not an override: the C library
   answers with the first it finds, so appending would leave an operator's own
   [SSH_AUTH_SOCK] pointing the loading program at somebody else's agent. *)
let with_variables assignments environment =
  let named = List.map fst assignments in
  let inherited =
    Array.to_list environment
    |> List.filter (fun entry ->
        match String.index_opt entry '=' with
        | None -> true
        | Some at -> not (List.mem (String.sub entry 0 at) named))
  in
  Array.of_list
    (inherited @ List.map (fun (name, value) -> name ^ "=" ^ value) assignments)

(* What a client has to be spawned in to reach the agent this module raised.
   Here rather than at the caller because the two facts it needs are this
   module's: which variable names an agent, and that an inherited one has to be
   removed rather than shadowed. A caller that appended its own assignment would
   leave the operator's own agent first in the array, and the C library answers
   with the first it finds. *)
let client_environment ~auth_sock environment =
  with_variables [ (auth_sock_variable, auth_sock) ] environment

let exit_code = function
  | Unix.WEXITED code -> code
  | Unix.WSIGNALED signal -> 128 + signal
  | Unix.WSTOPPED signal -> 128 + signal

(* Both streams are merged by the shell rather than read as two, and standard
   input is closed before the program is given a chance to want it. A reader
   that drained one pipe to the end while the other filled would deadlock, and
   the programs run here answer on whichever stream they feel like; a credential
   tool that blocked on a prompt nobody is reading is the failure this whole
   feature exists to stop producing. *)
let run_with_environment ~environment command =
  let channels =
    Unix.open_process_full (command ^ " </dev/null 2>&1") environment
  in
  let from_output, to_input, _from_errors = channels in
  close_out_noerr to_input;
  let collected = Buffer.create 256 in
  let chunk = Bytes.create 4096 in
  let rec drain () =
    let read = input from_output chunk 0 (Bytes.length chunk) in
    if read > 0 then (
      Buffer.add_subbytes collected chunk 0 read;
      drain ())
  in
  drain ();
  (Unix.close_process_full channels, Buffer.contents collected)

(* This machine's own work -- a temporary directory that is not there or not
   writable, no descriptors left to spawn with -- described rather than raised.
   The body a caller hands to [with_agent] is never run inside this, so a fault
   of the caller's own is never reported as a failure to raise an agent. *)
let as_spawn_failure f =
  match f () with
  | outcome -> outcome
  | exception Sys_error reason -> Error (Spawn_failed { reason })
  | exception Unix.Unix_error (code, callee, argument) ->
      Error
        (Spawn_failed
           {
             reason =
               Printf.sprintf "%s %s: %s" callee argument
                 (Unix.error_message code);
           })

let present program =
  if Program.found_on_path program then Ok ()
  else Error (Not_available { program })

(* The mode is named at creation rather than left to a default and then
   corrected, because the mode is the whole of the protection and a directory
   that is private one call later was not private: whoever can open the socket
   inside can sign with every key the agent holds, which on a deploy box is
   root. This is the reasoning the control socket's directory already carries,
   applied to a socket that is strictly more dangerous. *)
let private_directory () = Filename.temp_dir ~perms:0o700 "bondi-agent-" ""

(* The helper holds no secret of its own: it is a file on disk that prints an
   environment variable. Bondi sets that variable in the loading program's
   environment, and the helper is spawned by that program and inherits it -- so
   the secret is in two process environments rather than one. Said as it is
   rather than narrowed: both are readable through [/proc] by anything running
   as this uid, which is the same attacker the control socket's own note already
   declines to defend against, and neither is a file, a command line or a
   crontab line.

   It answers once. [observed], OpenSSH_10.5p1: a helper that keeps answering
   makes [ssh-add] retry a wrong passphrase indefinitely and the call never
   returns, while a helper that refuses the second prompt turns the same wrong
   passphrase into a refusal the caller can report. The marker is written before
   the secret is printed, so an interrupted first answer still spends the one
   answer there is. *)
let askpass_script ~served =
  Printf.sprintf
    "#!/bin/sh\n\
     if [ -e %s ]; then exit 1; fi\n\
     : > %s\n\
     printf '%%s\\n' \"$%s\"\n"
    (Filename.quote served) (Filename.quote served) passphrase_variable

let write_askpass ~directory =
  let path = Filename.concat directory "askpass" in
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc)
    (fun () ->
      output_string oc
        (askpass_script ~served:(Filename.concat directory "served"));
      close_out oc);
  Unix.chmod path 0o700;
  path

let spawn_agent ~socket =
  let status, output =
    run_with_environment ~environment:(Unix.environment ())
      (Printf.sprintf "%s -a %s" agent_program (Filename.quote socket))
  in
  match exit_code status with
  | 0 -> (
      match agent_pid output with
      | Some pid -> Ok pid
      | None ->
          Error
            (Spawn_failed
               {
                 reason =
                   Printf.sprintf "%s started and reported no pid: %s"
                     agent_program (String.trim output);
               }))
  | code ->
      Error
        (Spawn_failed
           {
             reason =
               Printf.sprintf "%s exited %d: %s" agent_program code
                 (String.trim output);
           })

(* [SSH_ASKPASS_REQUIRE] is what makes a modern ssh-add consult the helper even
   when it could have prompted on a terminal instead. [observed],
   OpenSSH_10.5p1, which is the one series this tree is ever run against.

   [DISPLAY] is what an older ssh-add requires before it will consult a helper
   at all. [assumed] -- no series older than the above has been run here, and
   nothing in this repository exercises that arm. It is set anyway because
   setting a variable an older client wants costs nothing and which series is in
   force is the host's business, not this client's. *)
let load_identity ~socket ~askpass ~passphrase ~key_path ~timeout_seconds =
  let status, output =
    run_with_environment
      ~environment:
        (with_variables
           [
             (auth_sock_variable, socket);
             ("SSH_ASKPASS", askpass);
             ("SSH_ASKPASS_REQUIRE", "force");
             ("DISPLAY", ":0");
             (passphrase_variable, Private_key.expose_to_askpass passphrase);
           ]
           (Unix.environment ()))
      (Printf.sprintf "%s -t %d %s" add_program
         (identity_lifetime_seconds ~timeout_seconds)
         (Filename.quote key_path))
  in
  match exit_code status with
  | 0 -> Ok ()
  | _ -> Error (Passphrase_rejected { output })

(* What the agent holds, in the one line [ssh] reads a public key out of. Asked
   of the agent because at this moment the agent is the only thing on this
   machine that can answer: the key on disk is encrypted, and deriving its
   public half from there needs the passphrase that this module has just taken
   trouble to keep off every command line.

   Wanted at all because a container that is not OpenSSH's -- a traditional PEM,
   a PKCS#8 -- hides its public half inside the encryption, so [ssh] cannot read
   one off the staged file and under [BatchMode=yes] cannot ask. Named with
   [IdentitiesOnly=yes] and no public half beside it, the identity is skipped
   and this agent is never consulted: the key loads, and the host answers
   "Permission denied (publickey)" for a fault that is entirely local.

   No passphrase is in this call's environment. It is a separate invocation from
   the loading one for that reason as much as for order -- the secret's two
   process environments stay the two that [load_identity] names, and this is not
   a third. *)
let list_identity ~socket =
  let status, output =
    run_with_environment
      ~environment:
        (with_variables [ (auth_sock_variable, socket) ] (Unix.environment ()))
      (add_program ^ " -L")
  in
  match exit_code status with
  | 0 -> Ok output
  | _ ->
      Error
        (Spawn_failed
           {
             reason =
               Printf.sprintf "%s would not say what the agent holds: %s"
                 add_program (String.trim output);
           })

(* Teardown runs from [Fun.protect]'s finaliser, where an exception is not the
   fault the caller is about to be told about but does replace it. So the two
   the filesystem and the process layer raise are swallowed here, and nothing
   else is: an [Out_of_memory] on the way out is not the cleanup's to eat. *)
let discard exceptions_swallowed =
  try exceptions_swallowed () with
  | Unix.Unix_error _
  | Sys_error _ ->
      ()

let discard_agent ~socket ~pid =
  discard (fun () ->
      let (_ : Unix.process_status * string) =
        run_with_environment
          ~environment:
            (with_variables
               [
                 (auth_sock_variable, socket);
                 ("SSH_AGENT_PID", string_of_int pid);
               ]
               (Unix.environment ()))
          (agent_program ^ " -k")
      in
      ())

let discard_directory directory =
  discard (fun () ->
      Array.iter
        (fun entry ->
          discard (fun () -> Unix.unlink (Filename.concat directory entry)))
        (Sys.readdir directory);
      Unix.rmdir directory)

let with_agent ~timeout_seconds ~passphrase ~key_path f =
  let* () = present agent_program in
  let* () = present add_program in
  let* directory = as_spawn_failure (fun () -> Ok (private_directory ())) in
  Fun.protect
    ~finally:(fun () -> discard_directory directory)
    (fun () ->
      let socket = Filename.concat directory "s" in
      let* askpass =
        as_spawn_failure (fun () -> Ok (write_askpass ~directory))
      in
      let* pid = as_spawn_failure (fun () -> spawn_agent ~socket) in
      Fun.protect
        ~finally:(fun () -> discard_agent ~socket ~pid)
        (fun () ->
          let* () =
            as_spawn_failure (fun () ->
                load_identity ~socket ~askpass ~passphrase ~key_path
                  ~timeout_seconds)
          in
          let* public_half =
            as_spawn_failure (fun () -> list_identity ~socket)
          in
          Ok (f { auth_sock = socket; public_half })))
