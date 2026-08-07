type component_status = {
  name : string;
  image_name : string;
  tag : string;
  status : string;
  restart_count : int option; [@default None]
  created_at : string option; [@default None]
}
[@@deriving yojson]

type infrastructure_status = {
  orchestrator : component_status option; [@default None]
  traefik : component_status option; [@default None]
  alloy : component_status option; [@default None]
  managed : component_status list; [@default []]
}
[@@deriving yojson]

type comprehensive_status = {
  service : component_status option; [@default None]
  cron_jobs : component_status list;
  infrastructure : infrastructure_status;
  errors : string list;
}
[@@deriving yojson]

let component_of_status (c : component_status) : Status_report.component =
  {
    name = c.name;
    observation =
      {
        image = c.image_name;
        tag = c.tag;
        state = c.status;
        health = None;
        wait = None;
        restart_count = c.restart_count;
        created_at = c.created_at;
      };
  }

let components_of (status : comprehensive_status) =
  let optional = function
    | Some component -> [ component ]
    | None -> []
  in
  List.map component_of_status
    (optional status.service
    @ status.cron_jobs
    @ optional status.infrastructure.orchestrator
    @ optional status.infrastructure.traefik
    @ optional status.infrastructure.alloy
    @ status.infrastructure.managed)

(* Enough of the body to recognise what answered — a wrong service on the port,
   an HTML error page, a response from a version that has since changed shape —
   without turning one unreadable answer into a screen of output. *)
let excerpt_length = 300

let excerpt body =
  let flattened = Bondi_common.String_utils.single_line body in
  match String.length flattened > excerpt_length with
  | false -> flattened
  | true -> String.sub flattened 0 excerpt_length ^ "…"

let not_understood ~ip_address ~detail body =
  Status_report.Not_understood
    (Printf.sprintf "%s answered with something this could not read: %s: %s"
       ip_address detail (excerpt body))

let reading_of_body ~ip_address body =
  (* [Yojson.Safe.from_string] raises on a body that is not JSON at all, which
     is the ordinary shape of "something other than an orchestrator answered on
     that port". Catching it here rather than letting it reach a handler around
     the request is what keeps it a fact about the answer instead of a fact
     about the call. *)
  match Yojson.Safe.from_string body with
  | exception Yojson.Json_error detail ->
      Error (not_understood ~ip_address ~detail body)
  | json -> (
      match comprehensive_status_of_yojson json with
      | Error detail -> Error (not_understood ~ip_address ~detail body)
      | Ok status ->
          Ok
            {
              Status_gather.components = components_of status;
              warnings = status.errors;
            })
