open Ppx_yojson_conv_lib.Yojson_conv

type container_status = {
  image_name : string;
  tag : string;
  created_at : string;
  restart_count : int;
  status : string;
}
[@@deriving yojson, show]

let parse_image_and_tag image =
  match String.split_on_char ':' image with
  | [ name ] -> Ok (name, "")
  | [ name; tag ] -> Ok (name, tag)
  | _ -> Error ("invalid image format: " ^ image)

let load_status ~client ~net ~container_name =
  Lwt_eio.run_eio @@ fun () ->
  match Docker.Client.get_container_by_name client ~net ~container_name with
  | None -> Error (`Not_found "Container not found")
  | Some container -> (
      let inspect =
        Docker.Client.inspect_container client ~net ~container_id:container.id
      in
      match parse_image_and_tag container.image with
      | Error msg -> Error (`Internal msg)
      | Ok (image_name, tag) ->
          let status =
            {
              image_name;
              tag;
              created_at = inspect.created_at;
              restart_count = inspect.restart_count;
              status = inspect.state.status;
            }
          in
          Ok status)

let route ~client ~net =
  Dream.get "/status" @@ fun req ->
  let open Lwt.Infix in
  match Dream.query req "service" with
  | None ->
      Dream.respond ~status:`Bad_Request
        "Missing required query parameter: service"
  | Some container_name ->
      Lwt.catch
        (fun () ->
          load_status ~client ~net ~container_name >>= function
          | Ok status ->
              status
              |> yojson_of_container_status
              |> Yojson.Safe.to_string
              |> Dream.json
          | Error (`Not_found msg) -> Dream.respond ~status:`Not_Found msg
          | Error (`Internal msg) ->
              Dream.respond ~status:`Internal_Server_Error msg)
        (fun exn ->
          Dream.respond ~status:`Internal_Server_Error (Printexc.to_string exn))
