type t =
  | Invalid_request of string
  | Orchestrator_failure of string
  | Not_ready of string

let message = function
  | Invalid_request msg
  | Orchestrator_failure msg
  | Not_ready msg ->
      msg

(* The failure class alone picks the status, so no handler carries a decision of
   its own. [Invalid_request] is a value the caller wrote that failed a
   precondition and answers 400; [Orchestrator_failure] is a fault on Bondi's
   side of the call and answers 500. Neither answers 404, which described
   neither. [Not_ready] is neither of those: the box cannot serve at all, which
   is 503. No route returns it today, and the status is still chosen here
   rather than left to whichever handler returns it first. *)
let http_status : t -> Dream.status = function
  | Invalid_request _ -> `Bad_Request
  | Orchestrator_failure _ -> `Internal_Server_Error
  | Not_ready _ -> `Service_Unavailable

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
   would report a failure as a success.

   [Not_ready] takes 3, the first code the fences above leave free. It is not
   folded onto 1 because an operator reading 1 cannot tell a box that failed a
   readiness probe -- a machine to repair -- from a request that failed while
   the box was serving, and the two have different next steps. *)
let exit_code : t -> int = function
  | Invalid_request _ -> 2
  | Orchestrator_failure _ -> 1
  | Not_ready _ -> 3

(* The sentence an operator reads beside a code they have just been left with.
   Matched on the class rather than keyed by the number, so that a class added
   later cannot be documented by omission: the compiler asks for its sentence
   at the same moment it asks for its code and its status. The wording follows
   the form cmdliner uses for the codes it documents for itself, because the
   two sets are rendered in one table. *)
let exit_doc : t -> string = function
  | Invalid_request _ -> "on a request that was wrong as written."
  | Orchestrator_failure _ -> "on a failure to carry out a well-formed request."
  | Not_ready _ -> "on a box that is not in a state to serve."

(* Every class, once. A list is the one thing the compiler cannot check for
   completeness, so the omission is caught by the test that compares this list
   against [exit_code] over the classes it names -- the same file whose
   exhaustive [function] over the variant makes a new constructor a build
   failure there. The messages are empty because neither [exit_code] nor
   [exit_doc] reads one: what is enumerated here is the classes, not any
   failure that occurred. *)
let classes = [ Invalid_request ""; Orchestrator_failure ""; Not_ready "" ]

let exit_documentation =
  List.map (fun failure -> (exit_code failure, exit_doc failure)) classes
