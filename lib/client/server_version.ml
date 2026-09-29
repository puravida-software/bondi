(* The floor is the first release whose *server* writes exec lines and run
   files, which is not the same as the first release that can execute one.

   0.15.0 -- tag v0.15.0, commit b2fee6c -- carries the [run] subcommand, so a
   generated line fires against it. But its own crontab writer still emits the
   legacy curl shape and it writes no run file at all; that arrived one release
   later, in daa784e. The deploy that rewrites a box's crontab runs on the box,
   so a floor of 0.15.0 accepted a box that answered every cron deploy with 200
   while replacing a legacy line with an identical legacy line. Observed on the
   estate's one box with a crontab: three consecutive deploys reporting success
   and changing nothing, which is the silent failure this gate exists to
   prevent, produced by the gate itself.

   Keeping it correct is the release recipe's job, not a future reader's: the
   justfile refuses to publish a tag that orders below the highest floor, which
   is the volume floor further down and sits above this one, so a release
   numbered beneath it fails once at the release instead of refusing every cron
   deploy in the estate.

   Held as a pair as well as a string so the comparison below is numeric: "0.9"
   is newer than "0.16" under string ordering and older under the ordering that
   matters.

   The patch level is not read, because this floor's patch is 0 and every 0.16.x
   therefore carries the writer. That also keeps a suffixed tag such as
   "0.16.0-rc1" readable rather than turning it into a refusal. *)
let minimum_major = 0
let minimum_minor = 16
let minimum_for_exec_lines = "0.16.0"

(* The repository the orchestrator is published under. Anything else is a fork,
   a mirror, or a locally built image; see the .mli for why those are answered
   whole rather than guessed at. *)
let published_image_prefix = "mlopez1506/bondi-server:"

let orchestrator_version_of_image image =
  if Bondi_common.String_utils.starts_with ~prefix:published_image_prefix image
  then
    String.sub image
      (String.length published_image_prefix)
      (String.length image - String.length published_image_prefix)
  else image

(* Only the first two components are read, for the reason the constants above
   give. A component that is not a number leaves the version with no ordering in
   it at all, which is a refusal rather than a pass. *)
let ordering_of_version version =
  match String.split_on_char '.' version with
  | major :: minor :: _ -> (
      match (int_of_string_opt major, int_of_string_opt minor) with
      | Some major, Some minor -> Some (major, minor)
      | Some _, None
      | None, Some _
      | None, None ->
          None)
  | []
  | [ _ ] ->
      None

(* The one comparison every floor is decided by, so no two can drift apart
   on what happens exactly at the boundary. *)
let ordering_reaches ~floor_major ~floor_minor (major, minor) =
  major > floor_major || (major = floor_major && minor >= floor_minor)

(* The one shape every floor's refusal takes. [because] names what the command
   does that needs the floor; [unreadable_note] is any extra said only when the
   version could not be read (None for none); [consequence] is what an older
   server does; [retry] ends the advice. Only these vary, so the three wordings
   cannot drift apart. *)
let gate ~floor_major ~floor_minor ~minimum ~because ~unreadable_note
    ~consequence ~retry version =
  match ordering_of_version version with
  | None ->
      let unreadable_note = Option.value unreadable_note ~default:"" in
      Error
        (Printf.sprintf
           "could not read an orchestrator version from the server; \
            bondi-server %s or later is required, because %s%s. The server is \
            running: %s. Set bondi_server.version in bondi.yaml to %s or \
            later, run bondi setup, then %s."
           minimum because unreadable_note (String.trim version) minimum retry)
  | Some ordering ->
      if ordering_reaches ~floor_major ~floor_minor ordering then Ok ()
      else
        Error
          (Printf.sprintf
             "the server is running bondi-server %s, but %s, which requires %s \
              or later. %s Set bondi_server.version in bondi.yaml to %s or \
              later, run bondi setup, then %s."
             version because minimum consequence minimum retry)

let writes_exec_lines version =
  gate ~floor_major:minimum_major ~floor_minor:minimum_minor
    ~minimum:minimum_for_exec_lines
    ~because:
      "a scheduled job's crontab line runs 'bondi-server run' inside the \
       orchestrator"
    ~unreadable_note:None
    ~consequence:
      "An older image ignores the arguments and serves instead, so the job \
       would fail at its next fire rather than now."
    ~retry:"deploy again" version

(* The second floor, and the earlier of the two: the first release whose server
   binary is a group of subcommands at all rather than a single program that
   serves. 0.15.0 -- tag v0.15.0, commit b2fee6c -- is where deploy, run, status
   and check arrived together, which is why one number covers every caller that
   runs one of them.

   It is deliberately a release below minimum_for_exec_lines and not the same
   number. A 0.15.x box answers a deploy and a status correctly; the only thing
   it cannot do is write an exec line into its own crontab, and refusing it here
   would refuse a box that works for the capability actually being used.

   Not read by the release recipe: the recipe refuses a tag below the highest
   floor, and a tag that clears that one clears this one by construction. The
   pair is held separately from the string for the same reason the pair above
   is. *)
let command_surface_major = 0
let command_surface_minor = 15
let minimum_for_command_surface = "0.15.0"

let answers_command_surface version =
  gate ~floor_major:command_surface_major ~floor_minor:command_surface_minor
    ~minimum:minimum_for_command_surface
    ~because:
      "this command runs a 'bondi-server' subcommand inside the orchestrator \
       container"
    ~unreadable_note:None
    ~consequence:
      "An older image has no subcommands: it ignores the arguments and starts \
       a second server against a port already bound, so the command would fail \
       without ever running."
    ~retry:"try again" version

(* The third floor, and the highest: the first release whose server reads a
   service's volumes from the deploy payload and mounts them. A server before it
   reads the payload strictly and refuses the whole deploy over a field it does
   not know, which is loud but arrives after the payload was sent and names a
   field rather than the release that fixes it.

   The release that carries volumes carries the subcommands and the exec-line
   writer by construction, so this is the floor the release recipe reads: a tag
   that clears it clears the other two. The pair is held separately from the
   string for the same reason the pairs above are, and the patch is not read
   because this floor's patch is 0. *)
let volumes_major = 0
let volumes_minor = 23
let minimum_for_volumes = "0.23.0"

let mounts_volumes version =
  gate ~floor_major:volumes_major ~floor_minor:volumes_minor
    ~minimum:minimum_for_volumes ~because:"the service declares volumes"
    ~unreadable_note:(Some ", which only a server from that release mounts")
    ~consequence:
      "An older server does not know the field and refuses the whole deploy."
    ~retry:"deploy again" version
