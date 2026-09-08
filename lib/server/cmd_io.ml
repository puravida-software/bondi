let read_stdin () = In_channel.input_all stdin

let emit json =
  print_string (Yojson.Safe.to_string json);
  flush stdout

(* No match over [Handler_error.t] here, deliberately. The class already answers
   both "what does this exit with" and "what does this answer over HTTP", and a
   second match in this module would be a second table that agrees today and
   drifts the first time a class is added. This makes no decision: it asks the
   class. *)
let fail error =
  prerr_string (Handler_error.message error);
  prerr_newline ();
  flush stderr;
  Handler_error.exit_code error

let status_of result ~encode =
  match result with
  | Ok value ->
      emit (encode value);
      0
  | Error error -> fail error

(* The document is written before the verdict is looked at, because it is not
   the verdict's to withhold: it is what the subcommand observed, and the arm a
   program most needs it on is the failing one. The streams stay apart -- the
   document on stdout, the reasons on stderr -- and [emit] flushes before [fail]
   writes, so the two cannot interleave. *)
let diagnostic_of verdict ~document =
  emit document;
  match verdict with
  | Ok () -> 0
  | Error error -> fail error
