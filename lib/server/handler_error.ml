type t = Invalid_request of string | Orchestrator_failure of string

let message = function
  | Invalid_request msg
  | Orchestrator_failure msg ->
      msg

(* The failure class alone picks the status, so no handler carries a decision of
   its own. [Invalid_request] is a value the caller wrote that failed a
   precondition and answers 400; [Orchestrator_failure] is a fault on Bondi's
   side of the call and answers 500. Neither answers 404, which described
   neither. *)
let http_status : t -> Dream.status = function
  | Invalid_request _ -> `Bad_Request
  | Orchestrator_failure _ -> `Internal_Server_Error

(* The shell's numbering: 2 for a request that was wrong as written, 1 for a
   general failure. Both are clear of what the client already reads as something
   else -- 255 as ssh's own failure, 128 plus n as a signal, each measured and
   recorded in [Bondi_client.Remote_exec]'s interface -- and clear of cmdliner's
   123 to 125, which the client returns for its own argument errors. That last
   range is [observed]: cmdliner 2.1.1's own interface documents
   [Cmdliner.Cmd.Exit.some_error] as 123, [cli_error] as 124 and
   [internal_error] as 125, and names them as what [Cmd.eval] returns for a
   parse error, an [Error msg] evaluation and an internal error; read in
   [_opam/lib/cmdliner/cmdliner.mli] on 2026-09-05. 0 is excluded because it
   would report a failure as a success. *)
let exit_code : t -> int = function
  | Invalid_request _ -> 2
  | Orchestrator_failure _ -> 1
