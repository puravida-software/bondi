let ( let* ) = Result.bind

type env_error = Env_not_set of string

let read_string var_name : (string, env_error) result =
  match Sys.getenv_opt var_name with
  | Some value -> Ok value
  | None -> Error (Env_not_set var_name)

let read_string_with_default var_name default : string =
  match Sys.getenv_opt var_name with
  | Some value -> value
  | None -> default
