let contains ~needle hay =
  let len_h = String.length hay in
  let len_n = String.length needle in
  let rec loop idx =
    if idx + len_n > len_h then false
    else if String.sub hay idx len_n = needle then true
    else loop (idx + 1)
  in
  if len_n = 0 then true else loop 0

let starts_with ~prefix value =
  let len_prefix = String.length prefix in
  String.length value >= len_prefix && String.sub value 0 len_prefix = prefix
