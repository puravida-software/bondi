type t = string

(* What a host's own answer may carry into a line of a report. Bounded because
   the line is printed to a terminal and pasted into reports while its source is
   free text a host chose the length of, and flattened first because a host
   writes on however many lines it likes -- a warning of its own ahead of the
   reading is the ordinary case, and the tail of a two-line answer lands in the
   middle of the sentence built around it.

   The notation a cut is marked with comes from String_utils rather than from
   here, which is how it stays the one an operator reads everywhere else in this
   client's output. The size does not: the payload Remote_exec bounds carries a
   failed `docker logs` and is measured in kilobytes, and this one carries a file
   mode or a restart policy. 240 is a judgement rather than a measurement -- a legitimate answer here is a short token, possibly preceded by
   a line of the host's own that the flattening folds into it, and 240 holds
   several such lines without scrolling a terminal.

   Cut rather than replaced: this is log hygiene and not redaction, and the
   answer is the only thing in the line that says what the box reported. What
   keeps a declared value out of a report is where the values in it come from,
   not this bound. *)
let limit = 240

(* An ASCII control character or DEL in a host's answer would act on the
   terminal the line is printed to, so each is replaced by a space, as the
   flattening does for a newline. Bytes of 0x80 and above are left alone: they
   are the parts of multi-byte characters. *)
let without_controls =
  String.map (fun c ->
      if Char.code c < 0x20 || Char.code c = 0x7f then ' ' else c)

let of_host_output answer =
  Bondi_common.String_utils.bounded ~limit
    (without_controls (Bondi_common.String_utils.single_line answer))

let to_string answer = answer
