(* PID 1's standard error, reached through procfs. This is the only route by
   which a process entered into a running container puts a line in the
   container's log stream; diagnostics.mli records the run that established
   that, and the conditions under which the open is refused. *)
let pid_one_stderr = "/proc/1/fd/2"
let should_duplicate ~pid = pid <> 1

type sink = {
  path : string;
  (* mutable: justified because giving up on a duplicate sink is a property of
     this process's relationship with that sink for the rest of its life, not of
     the line that discovered it. The refusal is either a uid mismatch between
     this process and PID 1, which does not change while the process runs, or a
     sink with no room, which can clear but whose retry per line is exactly the
     flood the notice is warning about; both are latched the same way and
     diagnostics.mli records that the second outlives its cause. Written once,
     at the moment of the first refusal. Carried by the sink rather than by the
     module so that one sink given up on does not silence another. *)
  mutable given_up : bool;
}

let sink_at ~path = { path; given_up = false }
let pid_one_sink = sink_at ~path:pid_one_stderr

(* Diagnostics may not become the outcome of the operation that emitted them,
   and a stderr that has been closed underneath us is not something a caller can
   be asked to handle, so the last resort is to drop the line. *)
let to_own_stderr line =
  try
    output_string stderr line;
    output_char stderr '\n';
    flush stderr
  with
  | Sys_error _ -> ()

type attempt = Wrote of int | Interrupted | Not_ready
type step = Advance of { offset : int; remaining : int } | Abandon of string

let step_after ~offset ~remaining = function
  | Wrote 0 -> Abandon "the write moved no bytes"
  | Wrote written ->
      Advance { offset = offset + written; remaining = remaining - written }
  | Interrupted -> Advance { offset; remaining }
  | Not_ready -> Abandon "the sink was not ready to accept the line"

(* A single [write] is not obliged to move the whole string: PID 1's stderr is
   usually a pipe, and a line longer than the pipe buffer comes back short. What
   each outcome means is [step_after]'s to say, so that the branch a test cannot
   reach through a file is reachable as a function of numbers; this is the
   syscall and the recursion, and it decides nothing. *)
let rec write_all fd s ~offset ~remaining =
  if remaining <= 0 then Ok ()
  else
    let attempt =
      match Unix.write_substring fd s offset remaining with
      | written -> Wrote written
      | exception Unix.Unix_error (Unix.EINTR, _, _) -> Interrupted
      | exception Unix.Unix_error ((Unix.EAGAIN | Unix.EWOULDBLOCK), _, _) ->
          Not_ready
    in
    match step_after ~offset ~remaining attempt with
    | Advance { offset; remaining } -> write_all fd s ~offset ~remaining
    | Abandon reason -> Error reason

(* O_APPEND rather than a truncating open: PID 1's stderr is a pipe in the
   ordinary case but is a regular file whenever the container's output was
   redirected to one, and opening that for writing without O_APPEND would
   discard everything already logged.

   O_NONBLOCK because the pipe case has a reader -- the engine's log driver, or
   the shipper behind it -- that can stall, and every caller of this runs on the
   single domain that also serves requests. A blocking open or write would
   suspend the server until that reader came back; a line dropped down the
   degradation path below does not. It also turns the pipe-with-no-reader open,
   which would otherwise wait forever, into an ENXIO this reports. *)
let duplicate sink line =
  let payload = line ^ "\n" in
  try
    let fd =
      Unix.openfile sink.path
        [ Unix.O_WRONLY; Unix.O_APPEND; Unix.O_NONBLOCK ]
        0
    in
    Fun.protect
      ~finally:(fun () ->
        try Unix.close fd with
        | Unix.Unix_error _ -> ())
      (fun () ->
        write_all fd payload ~offset:0 ~remaining:(String.length payload))
  with
  | Unix.Unix_error (e, _, _) -> Error (Unix.error_message e)

let write_to sink line =
  to_own_stderr line;
  if should_duplicate ~pid:(Unix.getpid ()) && not sink.given_up then
    match duplicate sink line with
    | Ok () -> ()
    | Error reason ->
        sink.given_up <- true;
        to_own_stderr
          (Printf.sprintf
             "diagnostics: cannot write to %s (%s); diagnostics continue on \
              this process's own stderr and will not reach the container log"
             sink.path reason)

let write line = write_to pid_one_sink line
