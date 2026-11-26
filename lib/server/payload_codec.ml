module Image_reference = Bondi_common.Image_reference

let image_reference_refusal ~field =
  Printf.sprintf "%s: not a valid image reference. A reference is %s" field
    Image_reference.grammar

let require_tag_or_digest reference =
  match (Image_reference.tag reference, Image_reference.digest reference) with
  | None, None ->
      let name = Image_reference.name reference in
      Error
        (Printf.sprintf
           "image %s has no tag — specify an explicit tag (e.g. %s:v1.0.0)" name
           name)
  | Some _, _
  | None, Some _ ->
      Ok reference

let reference_of_yojson ~field json =
  Image_reference.of_yojson json
  |> Result.map_error (fun (_ : string) -> image_reference_refusal ~field)

let service_name_of_yojson json =
  Bondi_common.Router_name.of_yojson ~field:"service_name" json
  |> Result.map_error (fun (_ : string) ->
      "service_name: not a valid Traefik router name. A router name is "
      ^ Bondi_common.Router_name.grammar)

let service_image_of_yojson json =
  match reference_of_yojson ~field:"image" json with
  | Error _ as e -> e
  | Ok reference -> (
      match
        (Image_reference.tag reference, Image_reference.digest reference)
      with
      | None, None ->
          Error
            "image: has neither a tag nor a digest. Specify an explicit tag or \
             digest, e.g. myapp:v1.0.0"
      | Some _, _
      | None, Some _ ->
          Ok reference)

let traefik_image_of_yojson = reference_of_yojson ~field:"traefik_image"
let cron_image_of_yojson = reference_of_yojson ~field:"cron_jobs[].image"

let cron_schedule_of_yojson ~job json =
  Bondi_common.Cron_schedule.of_yojson json
  |> Result.map_error (fun e ->
      Printf.sprintf "cron_jobs[].schedule: job %s: %s" job
        (Bondi_common.Cron_schedule.json_error_to_string e))

let traefik_acme_ca_server_of_yojson json =
  Bondi_common.Acme_ca_server.of_yojson json
  |> Result.map_error (fun (_ : string) ->
      "traefik_acme_ca_server: not a valid ACME directory URL. It is "
      ^ Bondi_common.Acme_ca_server.grammar)
