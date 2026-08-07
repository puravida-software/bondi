let contains ~needle hay = Bondi_common.String_utils.contains ~needle hay

(* Padding both ends turns "at either end of the value" into the same case as
   "between two spaces", so the search itself has one shape rather than three. *)
let contains_word ~word hay =
  let padded = " " ^ Bondi_common.String_utils.single_line hay ^ " " in
  contains ~needle:(" " ^ word ^ " ") padded
