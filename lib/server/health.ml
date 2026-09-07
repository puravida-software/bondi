(* Ported verbatim from the route body: the handler is empty and answers 204,
   so the transport-free form answers [Ok ()]. The liveness check the operator
   actually wants is a later feature's; inventing one here would change what
   the endpoint reports without anything asking it to. *)
let health () : (unit, Handler_error.t) result = Ok ()

let route =
  Dream.get "/health" @@ fun _req ->
  match health () with
  | Ok () -> Dream.empty `No_Content
  | Error err ->
      Dream.respond
        ~status:(Handler_error.http_status err)
        (Handler_error.message err)
