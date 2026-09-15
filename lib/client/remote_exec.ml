let ( let* ) = Result.bind

type failure =
  | Not_configured of { server : string }
  | Ssh_not_found of { program : string }
  | Local_failure of { reason : string }
  | Ssh_failed of { code : int; output : string }
  | Command_failed of { code : int; output : string }
  | Signalled of { signal : int; output : string }
  | Stopped of { signal : int; output : string }
  | Timed_out of { seconds : int; output : string }
  | Agent_unavailable of { program : string }
  | Key_passphrase_rejected of { output : string }

let ssh_config (server : Config_file.server) =
  match server.Config_file.ssh with
  | None -> Error (Not_configured { server = server.Config_file.ip_address })
  | Some ssh -> Ok ssh

(* The code ssh reserves for its own failures. A remote command exiting it is
   misclassified, and there is nothing in the code or the output that would
   separate the two -- see the interface, which says so where a caller reads. *)
let ssh_own_failure_code = 255

let failure_of_status status ~output =
  match status with
  | Unix.WEXITED 0 -> Ok output
  | Unix.WEXITED code when code = ssh_own_failure_code ->
      Error (Ssh_failed { code; output })
  | Unix.WEXITED code -> Error (Command_failed { code; output })
  | Unix.WSIGNALED signal -> Error (Signalled { signal; output })
  | Unix.WSTOPPED signal -> Error (Stopped { signal; output })

(* Which failures mean the host ran the command is one policy, and every caller
   that words a report around it was asking the same question of the same five
   arms. Asked here, beside the type, so that a sixth constructor is a compile
   error in one place rather than a silent fifth wording. *)
let ran_on_host = function
  | Command_failed _ -> true
  | Not_configured _
  | Ssh_not_found _
  | Local_failure _
  | Ssh_failed _
  | Signalled _
  | Stopped _
  | Timed_out _
  | Agent_unavailable _
  | Key_passphrase_rejected _ ->
      false

let exited_with ~code = function
  | Command_failed { code = actual; _ } -> actual = code
  | Not_configured _
  | Ssh_not_found _
  | Local_failure _
  | Ssh_failed _
  | Signalled _
  | Stopped _
  | Timed_out _
  | Agent_unavailable _
  | Key_passphrase_rejected _ ->
      false

type standard_error = Merged_on_failure | Merged_always

(* What a message may carry of the output it is reporting. The payload is the
   half of a failure worth reading, so it is carried rather than dropped -- but
   the output of a failed [docker logs], or of the orchestrator's own
   [docker logs --tail 50 ... 2>&1], is megabytes, and this text is written to a
   terminal and pasted into a report. Bounded here rather than at one caller,
   because every caller renders through this function and the one that capped
   its own was capping for a different reason. 2 KB is the size the convention
   this follows prescribes: several lines of a stack or a daemon's complaint,
   and nothing that scrolls a terminal away. *)
let message_output_limit = 2048

let carried output =
  let trimmed = String.trim output in
  let length = String.length trimmed in
  if length <= message_output_limit then trimmed
  else
    Printf.sprintf "%s ... (truncated, %d bytes in all)"
      (String.sub trimmed 0 message_output_limit)
      length

let message = function
  | Not_configured { server } ->
      Printf.sprintf "Missing ssh configuration for server %s" server
  | Ssh_not_found { program } ->
      Printf.sprintf
        "%s was not found on this machine's PATH, so no command was run" program
  | Local_failure { reason } ->
      Printf.sprintf "this machine could not run the command: %s" reason
  | Ssh_failed { code; output } ->
      Printf.sprintf "the host was not reached (%d): %s" code (carried output)
  | Command_failed { code; output } ->
      Printf.sprintf "command failed (%d): %s" code (carried output)
  | Signalled { signal; output } ->
      Printf.sprintf "command killed (%d): %s" signal (carried output)
  | Stopped { signal; output } ->
      Printf.sprintf "command stopped (%d): %s" signal (carried output)
  | Timed_out { seconds; output } ->
      Printf.sprintf
        "the command did not finish within %ds and was given up on, and may \
         still be running on the host: %s"
        seconds (carried output)
  | Agent_unavailable { program } ->
      Printf.sprintf
        "%s was not found on this machine's PATH, and the configured key needs \
         a passphrase to sign with, so no command was run"
        program
  | Key_passphrase_rejected { output } ->
      Printf.sprintf
        "ssh.private_key_pass did not unlock the private key in \
         ssh.private_key_contents on this machine, so no command was run: %s"
        (carried output)

let explain ~subject failure =
  if ran_on_host failure then
    Printf.sprintf "%s ran on the host and failed: %s" subject (message failure)
  else message failure

(* Both streams are drained together, waiting on whichever has bytes, rather
   than one to end of file and then the other. Sequentially, a command that
   fills the pipe it is not being read from blocks on the write, so it never
   closes the pipe that is being read and the call never returns -- there is no
   deadline anywhere on this path, so the symptom is a hang.

   Measured on 2026-09-05 through this module's own spawn: a stub writing 200 KB
   to standard error before its first line of standard output did not return
   under the sequential drain and was killed at 60s; the same stub returns
   [Ok "done\n"] under this one, and a stub writing the same 200 KB to standard
   output returns all of it. A Linux pipe holds 64 KB, and [docker logs] on a
   container that writes to its error stream passes far more than that through
   [bondi docker logs].

   Read from the descriptors rather than through the channels, so that neither
   channel's buffering can hold bytes the other is waiting on. Nothing else
   reads these channels, so nothing is missed.

   Each stream is terminated the way the line-at-a-time read this replaces
   terminated it -- a final line the command left unterminated gains the newline
   it did not print. Kept rather than dropped because it is what every caller
   has been handed since before this runner existed, and a drain that changes
   the bytes is a change nobody asked this fix to make. *)
let line_terminated contents =
  if contents = "" || contents.[String.length contents - 1] = '\n' then contents
  else contents ^ "\n"

(* What a drain came back with, and whether it came back because the streams
   ended or because the caller's deadline did. The two are not the same answer:
   an ended stream is the command's own, and a deadline is this client's, so
   they cannot both be reported as a status. *)
type drained =
  | Drained of { standard_output : string; standard_error : string }
  | Deadline_reached of { standard_output : string; standard_error : string }

(* What is still owed to the command's standard input, and how much of it has
   gone. Carried through the drain loop rather than written off before it: a
   command that prints while it reads fills the pipe this client is not reading
   from at the same moment this client fills the pipe the command is not reading
   from, and neither side moves again. There is no size at which that is safe,
   so both directions are waited on in the one [select] and the payload has no
   ceiling. *)
type pending_input = { payload : string; written : int }

(* One write of whatever the pipe will take, and what is owed after it. [None] is
   nothing further owed, and it is the same answer for two different reasons: the
   payload is all gone, or the far end closed its standard input. The second is
   not a failure to report -- a command that exits without draining what it was
   fed is reported by the status it exited with -- so both arms leave through the
   same door and the caller closes the channel.

   [EAGAIN] is a pipe that filled between [select] saying writable and the write
   arriving, and [EINTR] is a signal; neither moved a byte, so the payload is
   still owed exactly as it was. Every other error is the far end gone. The write
   is a single [Unix.single_write_substring] on a non-blocking descriptor rather
   than a channel write, because a channel write of more than the pipe will hold
   is the block this whole shape exists to avoid. *)
let advance_input fd pending =
  let remaining = String.length pending.payload - pending.written in
  if remaining <= 0 then None
  else
    match
      Unix.single_write_substring fd pending.payload pending.written remaining
    with
    | count when pending.written + count >= String.length pending.payload ->
        None
    | count ->
        Some { payload = pending.payload; written = pending.written + count }
    | exception
        Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK | Unix.EINTR), _, _) ->
        Some pending
    | exception Unix.Unix_error _ -> None

let drain_both ~deadline ~input ~to_command from_output from_errors =
  let output_fd = Unix.descr_of_in_channel from_output in
  let errors_fd = Unix.descr_of_in_channel from_errors in
  let input_fd = Unix.descr_of_out_channel to_command in
  let output = Buffer.create 256 in
  let errors = Buffer.create 256 in
  let chunk = Bytes.create 65536 in
  let collected () =
    ( line_terminated (Buffer.contents output),
      line_terminated (Buffer.contents errors) )
  in
  (* The command reaches end of input when this channel closes, so closing it
     belongs to the drain rather than to something that follows it: a command
     that reads to the end before it answers would otherwise be waited on by a
     client that has not yet told it there is no more. It is closed as soon as
     nothing further is owed, and again on every path out, which is safe because
     closing a closed channel does nothing. *)
  let close_input () = close_out_noerr to_command in
  let pending =
    match input with
    | None
    | Some "" ->
        close_input ();
        None
    | Some payload ->
        Unix.set_nonblock input_fd;
        Some { payload; written = 0 }
  in
  let rec drain open_fds pending =
    match open_fds with
    | [] ->
        (* Both of the command's streams ended, so the command is gone and what
           is left of the payload has nowhere to go. *)
        close_input ();
        let standard_output, standard_error = collected () in
        Drained { standard_output; standard_error }
    | _ :: _ ->
        (* The deadline is tested here and nowhere else. A [select] that returns
           nothing ready is either the timeout it was given or a signal, and the
           two are indistinguishable from its result -- so neither is read as the
           deadline having passed, and the next turn of the loop asks the clock
           instead. What is left of the bound is what [select] is given, so a
           stream that keeps producing cannot extend it. *)
        let remaining = deadline -. Unix.gettimeofday () in
        if remaining <= 0.0 then (
          close_input ();
          let standard_output, standard_error = collected () in
          Deadline_reached { standard_output; standard_error })
        else
          (* The write joins the wait rather than preceding it. A descriptor is
             offered to [select] only while something is owed on it, so a
             finished payload does not keep waking the loop on a pipe that is
             always writable. *)
          let writable_fds =
            match pending with
            | None -> []
            | Some _ -> [ input_fd ]
          in
          let ready, ready_to_write =
            match Unix.select open_fds writable_fds [] remaining with
            | ready, ready_to_write, _ -> (ready, ready_to_write)
            (* A signal delivered while waiting is not an end of stream. *)
            | exception Unix.Unix_error (Unix.EINTR, _, _) -> ([], [])
          in
          let pending =
            match pending with
            | None -> None
            | Some owed -> (
                if not (List.mem input_fd ready_to_write) then Some owed
                else
                  match advance_input input_fd owed with
                  | Some owed -> Some owed
                  | None ->
                      close_input ();
                      None)
          in
          let still_open =
            List.filter
              (fun fd ->
                if not (List.mem fd ready) then true
                else
                  match Unix.read fd chunk 0 (Bytes.length chunk) with
                  | 0 -> false
                  | count ->
                      Buffer.add_subbytes
                        (if fd = output_fd then output else errors)
                        chunk 0 count;
                      true
                  | exception Unix.Unix_error (Unix.EINTR, _, _) -> true)
              open_fds
          in
          drain still_open pending
  in
  drain [ output_fd; errors_fd ] pending

(* Standard error is collected apart from standard output and merged into it
   only when the command failed. A failure is reported with whatever the command
   said about why, which is what the output stream alone cannot carry; a success
   is the host answering the question it was asked, and the warnings ssh and
   sudo write alongside that answer are not part of the answer. The callers that
   read these outputs read them by shape -- the first non-empty line of a
   container listing, a whole-output comparison against an expected port binding
   -- so a "Permanently added ... to the list of known hosts" ahead of the
   reading is read as the reading.

   The two streams are drained together rather than one after the other. Draining
   in sequence deadlocks on a command that fills the pipe nobody is reading, and
   both claims that used to stand here in place of that -- that nothing this
   client runs prints a pipe buffer's worth, and that the replaced shapes drained
   in the same order -- were assumed and are false. [docker logs] passes a
   container's whole error stream through this runner, and the shape this one
   replaces ran one pipe (`2>&1` through [Unix.open_process_in]), which is why it
   had no second stream to leave undrained. The deadlock and its absence are both
   measured; see [drain_both].

   [input] is written to the command's standard input rather than embedded in
   the command line, so that a payload carrying credentials never appears in
   argv on either machine. The write is part of the same drain and not a step
   ahead of it: a command that prints while it reads deadlocks against a client
   that writes before it reads, and the payload the largest caller sends carries
   every environment variable a service declares. There is therefore no size a
   caller has to stay under, and none is stated.

   A call with nothing to feed writes nothing and closes, so the command on the
   far side reaches end of input at once. It is not handed this process's own
   standard input: a command on a deploy box has no business reading the
   operator's terminal, and the two shapes this runner replaces disagreed only
   because one of them was built on a spawn that had no input stream to give. *)

(* The process is reaped on every path out of [f], including one [f] leaves by
   raising -- a read that fails part-way is a child nobody waits on and three
   descriptors nobody closes, and setup opens this some thirty-four times per
   server. [Fun.protect] does not fit: the status is the value the caller needs
   and a [~finally] has nowhere to return it. The backtrace is taken before the
   close so that the fault reported is [f]'s own, at the place it happened.

   [f] is handed the shell's process id as well as its channels, because a bound
   on how long a command may run is worth nothing without something to kill when
   it passes. It is the shell this call spawned and not ssh: a simple command is
   exec'd by the shell rather than forked, so in practice they are the same
   process, and where they are not it is the shell that is waited on here.
   [observed -- 2026-09-11] [/bin/sh] here is bash 5.3.15(1)-release through the
   symlink [/bin/sh -> bash]; [/bin/sh -c 'sleep 5'] reported [comm=sleep] and
   no children, so the shell exec'd rather than forked. That is one shell on one
   machine and what [ssh_command] spells today, neither of which this module can
   hold still -- see [give_up_on], which does not rely on it.

   [environment] is the child's whole environment and is taken rather than read
   here, because a variable the client needs set is then set in the child and
   nowhere else. The alternative is a [VAR=value ] prefix on the command string,
   which is a second quoting surface on a line that is already a shell command
   carrying a quoted destination and a quoted remote command -- and a value that
   needed quoting there would be a value this module got wrong once. Taking it
   as a parameter is what [Unix.open_process_full] already offers; nothing is
   built to use it. *)
let with_process ~environment cmd f =
  let channels = Unix.open_process_full cmd environment in
  match f ~pid:(Unix.process_full_pid channels) channels with
  | value -> (Unix.close_process_full channels, value)
  | exception exn ->
      let backtrace = Printexc.get_raw_backtrace () in
      let (_ : Unix.process_status) = Unix.close_process_full channels in
      Printexc.raise_with_backtrace exn backtrace

(* A command that outlived its bound is killed rather than asked to stop: what
   is on the other end of this shell is an ssh client with a connection open,
   and the question this answers is how long this machine waits, not how
   politely the far end is let go. It is killed before it is reaped, because a
   reap of a process still running is the wait the bound exists to end. A kill
   that finds nothing is a process that exited between the deadline and here,
   which is not a failure of anything.

   The group is signalled before the process, because the pid captured at the
   spawn is a wrapper's: a shell that exec'd its command is that command, but a
   shell that forked it is a parent whose death leaves the [ssh] client alive
   with the connection open -- and with [ControlPersist] on the multiplex
   options, a leaked client is a leaked shared master. Whether this shell execs
   is a property of the shell and of what [ssh_command] spells, and neither is
   this module's to hold still, so the group goes first and the pid follows.
   Both are attempted: where the child is not a group leader the group signal
   finds nothing, which is the same not-a-failure as a process that had already
   exited. *)
let give_up_on pid =
  (try Unix.kill (-pid) Sys.sigkill with
  | Unix.Unix_error _ -> ());
  try Unix.kill pid Sys.sigkill with
  | Unix.Unix_error _ -> ()

(* The stdout-only rule on a successful command is setup's: it reads a reading
   by shape, so a warning ssh or sudo wrote alongside the answer would be read as
   the answer. It is wrong for the two pass-through printers, whose whole job is
   to show an operator what the container said -- so the merge is asked for at
   the call rather than assumed either way. *)
let output_of_status status ~policy ~standard_output ~standard_error =
  match policy with
  | Merged_always -> standard_output ^ standard_error
  | Merged_on_failure -> (
      match status with
      | Unix.WEXITED 0 -> standard_output
      | Unix.WEXITED _
      | Unix.WSIGNALED _
      | Unix.WSTOPPED _ ->
          standard_output ^ standard_error)

let run_command ?input ?(policy = Merged_on_failure) ~environment
    ~timeout_seconds cmd =
  (* An absolute instant rather than a budget carried through the loop: a
     deadline taken once at the start is the whole invocation's, and one
     subtracted from at each turn would be the bound of whichever read happened
     to be slowest. *)
  let deadline = Unix.gettimeofday () +. float_of_int timeout_seconds in
  let status, drained =
    with_process ~environment cmd
      (fun ~pid (from_command, to_command, from_command_errors) ->
        (* Writing to a command that has already exited raises SIGPIPE, which at
           its default disposition terminates this process before the status
           below can report anything. Ignoring it is what turns that into the
           [EPIPE] the drain reads as the command having closed its standard
           input -- which the status below reports, so the write failing is not
           itself an error worth surfacing. It is ignored for the whole drain
           rather than for a write ahead of it, because the write is now one of
           the things the drain waits on. Restored afterwards so the disposition
           is not changed program-wide. *)
        let previous_sigpipe = Sys.signal Sys.sigpipe Sys.Signal_ignore in
        let drained =
          Fun.protect
            ~finally:(fun () -> Sys.set_signal Sys.sigpipe previous_sigpipe)
            (fun () ->
              drain_both ~deadline ~input ~to_command from_command
                from_command_errors)
        in
        (match drained with
        | Drained _ -> ()
        | Deadline_reached _ -> give_up_on pid);
        drained)
  in
  match drained with
  | Drained { standard_output; standard_error } ->
      failure_of_status status
        ~output:
          (output_of_status status ~policy ~standard_output ~standard_error)
  | Deadline_reached { standard_output; standard_error } ->
      (* The status of a process this client killed says only that it killed it,
         so the outcome is worded from the deadline instead. Both streams are
         carried: a command given up on is a failure, and what it managed to say
         before the bound passed is the half of it worth reading. *)
      Error
        (Timed_out
           {
             seconds = timeout_seconds;
             output = standard_output ^ standard_error;
           })

(* One write-then-delete, used by the two things a session puts on disk. A
   second implementation of it is a second place a file can be left behind, and
   the two below differ only in where the path comes from and what goes in it.
   Private because what a caller is offered is the two named things, not a way
   to write any file at all. *)
let with_written_file ~path ~contents f =
  Fun.protect
    ~finally:(fun () ->
      (* A cleanup that finds nothing to remove is the file already having gone
         -- a sweeper, or an [f] that moved it -- and that is the outcome this
         wanted. Left to raise, [Fun.protect] turns it into
         [Fun.Finally_raised], which reports the cleanup and discards the fault
         the caller was about to be told about. *)
      try Sys.remove path with
      | Sys_error _ -> ())
    (fun () ->
      (* Opening is inside the protected region, so a file that was created and
         then could not be written to is still removed. *)
      let oc = open_out path in
      Fun.protect
        ~finally:(fun () -> close_out_noerr oc)
        (fun () ->
          output_string oc contents;
          close_out oc;
          Unix.chmod path 0o600;
          f ()))

let with_temp_key contents f =
  let decoded = Private_key.decode contents in
  let path = Filename.temp_file "bondi-key-" ".pem" in
  with_written_file ~path ~contents:decoded (fun () -> f path)

(* [ssh] looks for the public half of an identity beside it, under this name and
   no other, which is why the path is derived rather than chosen. *)
let public_half_suffix = ".pub"

let with_public_half ~key_path contents f =
  with_written_file ~path:(key_path ^ public_half_suffix) ~contents f

(* A prompt is a wait with no deadline. The two that were always here refuse to
   take one, and the reason has narrowed rather than gone: there is now an
   attendant on this machine -- the helper that answers the program loading a key
   into an agent -- but it answers that program, before any of this, and never
   [ssh]. What [ssh] would ask over these options is the remote account's
   password and what to do about an unknown host key, and nobody is there for
   either. It is also the bargain an operator who declares no key is held to:
   their own identity has to be usable without being asked for anything.

   The three bounds are the same reasoning applied to the network. A host that
   refuses the connection answers at once; one that accepts it and then drops
   the packets answers never, and [ssh] has no deadline of its own. Both
   commands that read a host print a report at the end of their work, so an
   unbounded read is the report being lost on exactly the failure it exists to
   describe. The keepalive covers the harder half: a session that was
   established and then went quiet, which no connect timeout can reach. *)
let ssh_options =
  [
    "-o BatchMode=yes";
    "-o StrictHostKeyChecking=accept-new";
    "-o ConnectTimeout=10";
    "-o ServerAliveInterval=15";
    "-o ServerAliveCountMax=4";
  ]

(* One SSH connection reused across a command's many round trips.
   `bondi setup` issues 31 separate ssh invocations. Measured against the
   trading box on 2026-09-02: 2.48s each cold, 0.39s multiplexed -- about 77
   seconds of pure handshake per setup, versus about 15. The server side was
   already clean (usedns no, gssapiauthentication no); this was entirely a
   missing client option.

   The socket lives in a private mode-700 directory named after this process,
   not at a predictable path in a shared /tmp. Whoever can open a control socket
   can multiplex onto the connection it holds -- which is root on a deploy box.
   On the runner fleet every agent runs as the same uid, so a shared, guessable
   path would let any repo's job ride another job's deployment connection. The
   directory is removed at exit; a master that outlives it is unreachable and
   expires on ControlPersist. *)
let control_dir =
  lazy
    (let dir =
       Filename.concat
         (Filename.get_temp_dir_name ())
         (Printf.sprintf "bondi-ssh-%d" (Unix.getpid ()))
     in
     (try Unix.mkdir dir 0o700 with
     | Unix.Unix_error (Unix.EEXIST, _, _) -> ());
     (* A directory that has already gone, or one this process may no longer
        write to, is the outcome the cleanup wanted; anything else -- an
        [Out_of_memory] on the way out, an interrupt -- is not the cleanup's to
        swallow, so the two the filesystem raises are named rather than
        everything. *)
     at_exit (fun () ->
         (try
            Array.iter
              (fun f ->
                try Unix.unlink (Filename.concat dir f) with
                | Unix.Unix_error _
                | Sys_error _ ->
                    ())
              (Sys.readdir dir)
          with
         | Unix.Unix_error _
         | Sys_error _ ->
             ());
         try Unix.rmdir dir with
         | Unix.Unix_error _
         | Sys_error _ ->
             ());
     dir)

(* The socket is named per connection and not only per process, and [ssh] is
   what names it: this client spells one option set for a whole run, and which
   box a call is for is not known where the option is written. Left as ssh's own
   token so the answer is ssh's definition of the same connection rather than a
   second one of this client's.

   One name for the whole process is one connection for every server the process
   talks to. `bondi init` scaffolds two servers and every command loops them
   inside one process, well inside [ControlPersist] -- so the second server's
   command runs down the first server's connection, past the [-i], the
   [IdentitiesOnly=yes] and the agent that were each chosen for the second.

   [%C] rather than [%h-%p-%r] because it is 40 characters whatever the host is
   called, and the path this goes in has about 104 bytes to spend before the
   master stops starting at all. *)
let connection_token = "%C"

(* Kept apart from [ssh_options] because taking these is not free: the first
   call forces [control_dir], which creates a mode-700 directory. [ssh_options]
   is a constant anyone may read; this is a function because calling it does
   something. *)
let multiplex_options () =
  let dir = Lazy.force control_dir in
  [
    "-o ControlMaster=auto";
    Printf.sprintf "-o ControlPath=%s"
      (Filename.quote (Filename.concat dir connection_token));
    "-o ControlPersist=30";
  ]

(* What was staged for a server, and nothing about how a command line spells it.
   The three arms are the three things the resolution of the configured key can
   ask for: nothing at all, a file [ssh] can read, and a file whose decrypted
   form lives in an agent this client raised. A record with an unconditional
   path had nothing to put in the first arm's field, and nothing anywhere to put
   the third arm's socket.

   Kept as the facts rather than as the options and the environment they produce
   because the two derivations below are the only readers, and a session that
   already held their answers could not be asked what it actually staged -- which
   is the question the key's lifetime and the agent's teardown both turn on. *)
type staging =
  | No_identity
  | Staged of { key_path : string }
  | Agent_held of { key_path : string; auth_sock : string }

(* The options that name an identity to [ssh], kept here because [ssh_options] is
   the one place options are spelled and a second spelling elsewhere is a second
   answer to how this client connects. A function rather than a constant for
   [multiplex_options]' reason -- producing it does something, here quoting a
   path this module chose -- and because what it produces is a property of the
   server being connected to rather than of the client.

   A manifest that declared no key names no identity at all: the operator's own
   configuration is what authenticates, and an [-i] here would be this client
   inserting itself into it. An agent-held key is still named, because the file
   carries the public half [ssh] offers and the agent is what signs for it.

   A declared identity is also the only one allowed to answer. Named without
   that, it is merely the first thing offered, and whatever an ambient agent
   happens to hold is offered after it -- so a declared key that cannot sign
   connects anyway, on a credential nobody wrote down, and the two outcomes this
   client distinguishes are not distinguishable at the host. What the
   restriction removes is other identities, not other signers: its own manual
   puts it as using only the configured identity files even when an agent offers
   more, so the staged file is still offered and the agent that holds its
   private half is still what signs -- which is what keeps the agent arm
   working. Nothing is restricted where nothing was declared -- there the
   operator's configuration is the whole mechanism, and a client that narrowed
   it to the identity files on a command line naming none would leave [ssh]
   nothing at all to offer. *)
let identity_options = function
  | No_identity -> []
  | Staged { key_path }
  | Agent_held { key_path; _ } ->
      [ "-i " ^ Filename.quote key_path; "-o IdentitiesOnly=yes" ]

(* Assembled as words and joined, rather than as a format string with a slot per
   group, so that a group contributing nothing contributes no separator either.
   A format string cannot express that: an empty slot leaves the two spaces
   around it behind. *)
let ssh_command ~user ~host ~identity_words cmd =
  let destination = user ^ "@" ^ host in
  String.concat " "
    (("ssh" :: identity_words)
    @ ssh_options
    @ multiplex_options ()
    @ [ Filename.quote destination; "--"; Filename.quote cmd ])

(* Whether there is an [ssh] to spawn is asked before spawning, because after
   the spawn the answer is unrecoverable: a local shell that cannot find the
   command exits 127, which is exactly what the host's own shell exits when the
   remote command is missing. Setup reads that code as the host reporting Docker
   absent and installs Docker -- so an operator with no ssh client would have a
   box changed on the strength of a message from their own machine.

   PATH is read rather than resolved into the command line: what [ssh_command]
   spells is asserted on elsewhere, and a check is all this needs to be. *)
let ssh_program = "ssh"

let ssh_client_present () =
  if Program.found_on_path ssh_program then Ok ()
  else Error (Ssh_not_found { program = ssh_program })

(* What a session holds is how a call made over it authenticates, not where the
   key went. The two are the same thing today -- the options are an [-i] naming
   the staged path -- and they stop being the same as soon as a key that cannot
   sign as a file has to be reached through something else. A field spelled
   [key_path] would then be a field with nothing to put in it, and the runners
   would each have to decide what to do about that; a session that already
   carries the options and the environment leaves them nothing to decide. *)
type session = {
  staging : staging;
  environment : string array;
  timeout_seconds : int;
}

(* The environment a call over this session is spawned in. The session carries
   this process's own, unchanged, and the one arm that changes anything changes
   it here rather than at the staging, so that what a call runs in is derived
   from what was staged rather than remembered alongside it. *)
let session_environment session =
  match session.staging with
  | No_identity
  | Staged _ ->
      session.environment
  | Agent_held { auth_sock; _ } ->
      Ssh_agent.client_environment ~auth_sock session.environment

(* [with_temp_key] and the body it is handed raise the same two exceptions, and
   nothing in either one says which of them raised it. The body's fault is
   tagged on the way out so the two arms below stay the staging's alone: a body
   that failed is the caller's to handle at the place it happened, and reporting
   it as this machine's failure to make the call would name the wrong fault and
   would let a caller that re-derives its answer from a failed session run the
   body a second time. Private to this module; no caller ever sees it. *)
exception Body_raised of exn * Printexc.raw_backtrace

(* Writing the key and spawning the process are this machine's own work, and
   both fail in ordinary ways -- a temporary directory that is not there or not
   writable, no descriptors left. Those are failures this module can describe,
   so they are arms rather than exceptions a caller would have to catch to
   discover it had a result type for nothing. Named once because the staging and
   the runner both reach them, and a second spelling is a second wording for the
   same fault. *)
let as_local_failure f =
  match f () with
  | outcome -> outcome
  | exception Sys_error reason -> Error (Local_failure { reason })
  | exception Unix.Unix_error (code, callee, argument) ->
      Error
        (Local_failure
           {
             reason =
               Printf.sprintf "%s %s: %s" callee argument
                 (Unix.error_message code);
           })

(* The agent's failures said in this module's words. Two of the three are faults
   nothing else here can produce and are their own arms; the third is this
   machine failing at its own work -- no directory to put a socket in, no
   descriptors left -- which is what [Local_failure] already means, so it is not
   given a second name.

   None of the three is a host's answer, and the rendering below says so. The
   fault that prompted all of this was a local signing failure wearing the host's
   authorization error, and an arm that arrived here and then rendered as a
   command the box refused would be the same defect one layer further in. *)
let of_agent_failure = function
  | Ssh_agent.Not_available { program } -> Agent_unavailable { program }
  | Ssh_agent.Spawn_failed { reason } -> Local_failure { reason }
  | Ssh_agent.Passphrase_rejected { output } ->
      Key_passphrase_rejected { output }

(* The one call to [with_temp_key] this module makes. Every remote call reaches
   the key through a session, so how long key material is on disk is a decision
   taken once for a server's whole run rather than once per command -- and a
   call made without one opens a session of its own, which is that same decision
   with a lifetime of one command. *)
let with_session ~timeout_seconds (server : Config_file.server) f =
  let* ssh = ssh_config server in
  let* () = ssh_client_present () in
  (* The body, run over whatever was staged. The two fields beside the staging
     are the same on every arm: this process's own environment, read once for
     the session rather than once per call so that every call made over one
     connection is made in the same one, and the bound the session was opened
     at. Each is named here rather than defaulted, so an arm cannot acquire a
     different one by omission. *)
  let over staging =
    let session =
      { staging; environment = Unix.environment (); timeout_seconds }
    in
    match f session with
    | value -> value
    | exception exn -> raise (Body_raised (exn, Printexc.get_raw_backtrace ()))
  in
  (* Only the arms the resolution built from a declared key reach this, because
     it answers [Ambient] for every manifest that carries none. The default is
     unreachable and is here because the resolution's own type does not carry
     the string it classified. *)
  let declared =
    Option.value ~default:"" ssh.Config_file.private_key_contents
  in
  (* The resolution is asked for once, here, because this is the one place a
     server's key is acted on. [Refused] is answered before anything is staged
     or dialled, in the sentence the configuration reader already refuses on --
     said again rather than trusted to that reader, because a server value built
     without passing through it can still arrive here, and a key that cannot
     sign must not be offered to a host that would then report the failure as
     its own. *)
  let staged () =
    match
      Private_key.identity ~contents:ssh.Config_file.private_key_contents
        ~passphrase:ssh.Config_file.private_key_pass
    with
    | Private_key.Refused { reason } ->
        Error
          (Local_failure
             {
               reason =
                 Private_key.refusal_message
                   ~server:server.Config_file.ip_address ~reason;
             })
    | Private_key.Ambient -> as_local_failure (fun () -> Ok (over No_identity))
    | Private_key.Staged_key ->
        as_local_failure (fun () ->
            Ok
              (with_temp_key declared (fun key_path ->
                   over (Staged { key_path }))))
    | Private_key.Own_agent { passphrase } ->
        (* The public half is written beside the staged key, out of the agent
           that now holds the decrypted one. Without it an encrypted container
           that is not OpenSSH's -- a traditional PEM, a PKCS#8 -- is an
           identity [ssh] cannot read a public key out of and, under
           [BatchMode=yes], cannot ask about; named with [IdentitiesOnly=yes]
           it is then skipped, this agent is never consulted, and the host
           answers "Permission denied (publickey)" for a fault that never left
           this machine. An OpenSSH container carries its public half in clear
           and needs none of this, and gets it anyway: one arm here is one thing
           to be true of every key that signs through an agent. *)
        as_local_failure (fun () ->
            with_temp_key declared (fun key_path ->
                Result.map_error of_agent_failure
                  (Ssh_agent.with_agent ~timeout_seconds ~passphrase ~key_path
                     (fun agent ->
                       with_public_half ~key_path (Ssh_agent.public_half agent)
                         (fun () ->
                           over
                             (Agent_held
                                {
                                  key_path;
                                  auth_sock = Ssh_agent.auth_sock agent;
                                }))))))
  in
  match staged () with
  | outcome -> outcome
  | exception Body_raised (exn, backtrace) ->
      Printexc.raise_with_backtrace exn backtrace

let command_output ?session ?input ?standard_error ~timeout_seconds ~command
    (server : Config_file.server) =
  let* ssh = ssh_config server in
  let* () = ssh_client_present () in
  (* The bound in force is the call's own. What a session contributes to a call
     made over it is the key, not the clock: a read that asks for a minute
     inside a session a deploy opened for half an hour is asking for a minute,
     and a session that overrode it would hold a read of a box that has stopped
     answering to the deploy's whole budget -- which is the wait the bound
     exists to end. A call that arrives without a session opens one, and what it
     opens it at is that same number, so a session's own bound is the bound of
     the call it was opened for.

     Said once, in the session the run is made over: the caller's session is
     stamped with this call's number rather than the number being carried
     alongside it, so there is one place a reader looks for what a run is held
     to. *)
  let over session =
    as_local_failure (fun () ->
        run_command ?input ?policy:standard_error
          ~environment:(session_environment session)
          ~timeout_seconds:session.timeout_seconds
          (ssh_command ~user:ssh.Config_file.user ~host:server.ip_address
             ~identity_words:(identity_options session.staging)
             command))
  in
  match session with
  | Some session -> over { session with timeout_seconds }
  | None -> Result.join (with_session ~timeout_seconds server over)

let docker_command_output ?session ?input ?standard_error ~timeout_seconds
    ~command server =
  command_output ?session ?input ?standard_error ~timeout_seconds
    ~command:("docker " ^ command) server

let command_output_text ?session ?input ?standard_error ~timeout_seconds
    ~command server =
  Result.map_error message
    (command_output ?session ?input ?standard_error ~timeout_seconds ~command
       server)

let docker_command_output_text ?session ?input ?standard_error ~timeout_seconds
    ~command server =
  Result.map_error message
    (docker_command_output ?session ?input ?standard_error ~timeout_seconds
       ~command server)
