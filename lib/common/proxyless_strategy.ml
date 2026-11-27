type t = Simple | Blue_green

let of_string = function
  | "blue-green" -> Some Blue_green
  | "simple" -> Some Simple
  | _ -> None

let to_string = function
  | Simple -> "simple"
  | Blue_green -> "blue-green"

let valid_values = "blue-green, simple"
let no_proxy_reason = "no traefik: block"

let blue_green_refusal ~service ~domain strategy =
  match (strategy, domain) with
  | Blue_green, None ->
      let subject =
        match service with
        | Some name -> "service " ^ name
        | None -> "a request that names no service"
      in
      Some
        (Printf.sprintf
           "%s declares deployment_strategy blue-green and no traefik: block. \
            Blue-green switches traffic through the proxy, so it needs one: \
            declare traefik:, or declare simple or no strategy"
           subject)
  | Blue_green, Some _
  | Simple, (None | Some _) ->
      None

let auto_without_proxy_notice ~service ~domain ~declared =
  match (declared, domain) with
  | None, None ->
      Some
        (Printf.sprintf "service %s has no traefik: block; deploying with %s"
           service (to_string Simple))
  | None, Some _
  | Some _, (None | Some _) ->
      None
