type error = Invalid_key of string | Invalid_value of { key : string }

let check ~key ~value =
  match
    ( String.length key = 0
      || String.contains key '='
      || String_utils.has_control_char key,
      String_utils.has_control_char value )
  with
  | true, _ -> Error (Invalid_key key)
  | false, true -> Error (Invalid_value { key })
  | false, false -> Ok ()

let job_offenders ~job entries =
  List.filter_map
    (fun (key, value) ->
      match check ~key ~value with
      | Ok () -> None
      | Error (Invalid_key key) ->
          Some (Printf.sprintf "job %S has an invalid key %S" job key)
      | Error (Invalid_value { key }) ->
          Some
            (Printf.sprintf "job %S has a control character in the value of %S"
               job key))
    entries

let job_refusal jobs =
  match
    List.concat_map (fun (job, entries) -> job_offenders ~job entries) jobs
  with
  | [] -> None
  | offenders ->
      Some
        (Printf.sprintf
           "cron job secret entries cannot be written to an env file (%s). A \
            key must be non-empty and hold no \"=\" and no control character, \
            and a value must hold no control character, newline included: fix \
            these entries in bondi.yaml"
           (String.concat "; " offenders))
