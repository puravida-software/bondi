module Image_reference = Bondi_common.Image_reference

let orchestrator_repository = "mlopez1506/bondi-server"

let orchestrator ~version =
  match
    Image_reference.of_name_and_tag ~name:orchestrator_repository ~tag:version
  with
  | Ok reference -> Ok reference
  | Error (Image_reference.Malformed composed) ->
      Error
        (Printf.sprintf
           "bondi_server.version %S does not make an image reference: %S is \
            not one"
           version composed)
  | Error Image_reference.Empty ->
      Error "bondi_server.version is empty, so there is no image to pull"

let alloy ~declared =
  match declared with
  | Some reference -> reference
  | None -> (
      match Image_reference.of_string Bondi_common.Defaults.alloy_image with
      | Ok reference -> reference
      | Error (Image_reference.Empty | Image_reference.Malformed _) ->
          invalid_arg "Defaults.alloy_image is not an image reference")

let pull_command reference =
  "pull " ^ Filename.quote (Image_reference.to_string reference)

let pull_failure reference ~reason =
  Printf.sprintf "could not pull %s: %s"
    (Image_reference.to_string reference)
    reason
