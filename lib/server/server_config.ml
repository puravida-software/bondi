type t = { port : int }
type error = Invalid_port of string

let load () : (t, error) result =
  let port = Env.read_string_with_default "BONDI_SERVER_PORT" "3030" in
  match int_of_string_opt port with
  | Some port -> Ok { port }
  | None -> Error (Invalid_port port)
