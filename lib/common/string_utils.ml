let index_of ~needle hay =
  let hay_length = String.length hay and needle_length = String.length needle in
  let rec loop index =
    if index + needle_length > hay_length then None
    else if String.equal (String.sub hay index needle_length) needle then
      Some index
    else loop (index + 1)
  in
  loop 0

let contains ~needle hay = Option.is_some (index_of ~needle hay)

let last_index_of_char value char =
  let rec loop index =
    if index < 0 then None
    else if value.[index] = char then Some index
    else loop (index - 1)
  in
  loop (String.length value - 1)

let single_line message =
  String.split_on_char ' '
    (String.map
       (fun c ->
         match c with
         | ' '
         | '\t'
         | '\n'
         | '\r' ->
             ' '
         | c -> c)
       message)
  |> List.filter (fun part -> not (String.equal part ""))
  |> String.concat " "

let starts_with ~prefix value =
  let len_prefix = String.length prefix in
  String.length value >= len_prefix
  && String.equal (String.sub value 0 len_prefix) prefix
