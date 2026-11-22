type verdict = Same | Moved | Unreadable of Host_answer.t

let command ~image ~container =
  Printf.sprintf
    "docker image inspect -f '{{.Id}}' %s && docker container inspect -f \
     '{{.Image}}' %s"
    (Filename.quote (Bondi_common.Image_reference.to_string image))
    (Filename.quote container)

let id_prefix = "sha256:"
let id_hex_length = 64

let is_lowercase_hex = function
  | '0' .. '9'
  | 'a' .. 'f' ->
      true
  | _ -> false

(* An id is checked for its shape, not only for being there. A template prints
   [<no value>] for a field the object lacks, and two of those are equal: read
   as ids, they would keep a container on an image nobody reported. *)
let is_image_id line =
  String.length line = String.length id_prefix + id_hex_length
  && String.starts_with ~prefix:id_prefix line
  && String.for_all is_lowercase_hex
       (String.sub line (String.length id_prefix) id_hex_length)

(* Each line is trimmed on its own, which takes off a carriage return a remote
   shell left on it. Blank lines are dropped before the lines are counted, so
   the newline that ends the answer is not a third line. *)
let ids_of_output output =
  output
  |> String.split_on_char '\n'
  |> List.map String.trim
  |> List.filter (fun line -> line <> "")

let of_output output =
  match ids_of_output output with
  | [ pulled; running ] when is_image_id pulled && is_image_id running ->
      if String.equal pulled running then Same else Moved
  | []
  | [ _ ]
  | [ _; _ ]
  | _ :: _ :: _ :: _ ->
      Unreadable (Host_answer.of_host_output output)

let verdict = function
  | Ok output -> of_output output
  | Error failure -> Unreadable (Host_answer.of_host_output failure)
