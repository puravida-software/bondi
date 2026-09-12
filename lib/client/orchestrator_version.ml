(* [-a] rather than plain [ps]: an orchestrator that died on startup is still on
   the host and still the image the next [bondi setup] would replace, and a
   plain [ps] cannot see it. Only the image is asked for -- what the callers
   need is the version, and a container's state is [Cmd.Setup]'s question. *)
let image_command =
  Printf.sprintf "ps -a --filter name=^/%s$ --format '{{.Image}}'"
    Bondi_common.Builtin_container.orchestrator

(* A read of something already on the box -- the tag of an image that is there
   whether or not anything is running -- so a box that is answering answers it
   at once. A minute is generous for that and short enough that a box which has
   stopped answering is not waited on for the budget of whatever the caller was
   about to do. It is not a caller's parameter because it is not a caller's
   decision: the two callers ask the same question of the same artifact, and a
   knob here would be the third spelling this module exists to prevent. *)
let read_seconds = 60

let read ?session (server : Config_file.server) =
  match
    Remote_exec.docker_command_output ?session ~timeout_seconds:read_seconds
      ~command:image_command server
  with
  | Error failure -> Error failure
  | Ok output ->
      Ok (Server_version.orchestrator_version_of_image (String.trim output))
