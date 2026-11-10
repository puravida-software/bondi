type image = { id : string; repo_tags : string list }

type context = {
  replaced : string list;
  declared : string list;
  candidates : image list;
  referenced : string list;
}

type action = Remove_image of { id : string } | Keep_in_use of { id : string }

module Simple = Strategy.Simple

let ( let* ) = Result.bind

let declared_of_input : Simple.deploy_input -> string list =
 fun input ->
  let service =
    match input.image with
    | None -> []
    | Some image -> [ Simple.service_image_reference image ]
  in
  let cron =
    List.map
      (fun (job : Simple.cron_job) -> job.image)
      (Option.value input.cron_jobs ~default:[])
  in
  service @ cron

(* What the plan does with one id: [Skip] a declared image, [Keep_silently] the
   image of a container this deploy did not replace, [Keep_with_line] a
   candidate a container uses, [Remove] the rest. *)
type disposition = Skip | Keep_silently | Keep_with_line | Remove

let plan : context -> action list =
 fun { replaced; declared; candidates; referenced } ->
  let is_declared image =
    List.exists (fun tag -> List.mem tag declared) image.repo_tags
  in
  let kept =
    List.filter_map
      (fun image ->
        match is_declared image with
        | true -> Some image.id
        | false -> None)
      candidates
  in
  let candidate_ids = List.map (fun image -> image.id) candidates in
  let ids = replaced @ candidate_ids in
  let classify id =
    match
      (List.mem id kept, List.mem id referenced, List.mem id candidate_ids)
    with
    | true, _, _ -> Skip
    | false, true, false -> Keep_silently
    | false, true, true -> Keep_with_line
    | false, false, _ -> Remove
  in
  let _, planned =
    List.fold_left
      (fun (seen, planned) id ->
        match List.mem id seen with
        | true -> (seen, planned)
        | false -> (
            match classify id with
            | Skip
            | Keep_silently ->
                (seen, planned)
            | Keep_with_line -> (id :: seen, Keep_in_use { id } :: planned)
            | Remove -> (id :: seen, Remove_image { id } :: planned)))
      ([], []) ids
  in
  List.rev planned

let warning ~id ~reason =
  Printf.sprintf "image cleanup warning: could not remove image %s: %s" id
    reason

let kept_in_use ~id =
  Printf.sprintf "image cleanup: kept image %s because a container uses it" id

let interpret :
    remove:(string -> (unit, string) result) ->
    warn:(string -> unit) ->
    action list ->
    unit =
 fun ~remove ~warn actions ->
  List.iter
    (function
      | Remove_image { id } -> (
          match remove id with
          | Ok () -> ()
          | Error reason -> warn (warning ~id ~reason))
      | Keep_in_use { id } -> warn (kept_in_use ~id))
    actions

(* The repository a declared reference names, which is what the listing's
   [reference] filter is given so that every tag of it is listed. A reference
   that does not parse names no repository and lists nothing: cleanup removes
   less rather than guessing at a name. *)
let repository reference =
  match Simple.parse_image_and_tag reference with
  | Ok (name, _) -> Some name
  | Error _ -> None

let gather ~client ~net ~clock ~replaced ~declared =
  Docker.Client.with_request_bound ~clock ~what:"image cleanup lookups"
  @@ fun () ->
  let repositories =
    List.sort_uniq String.compare (List.filter_map repository declared)
  in
  let rec list_candidates acc = function
    | [] -> Ok (List.concat (List.rev acc))
    | reference :: rest ->
        let* summaries =
          Docker.Client.list_images client ~net ~clock ~reference ()
        in
        let images =
          List.map
            (fun (summary : Docker.Client.Image_summary.t) ->
              { id = summary.id; repo_tags = summary.repo_tags })
            summaries
        in
        list_candidates (images :: acc) rest
  in
  let* candidates = list_candidates [] repositories in
  let* containers = Docker.Client.list_containers client ~net ~all:true () in
  let referenced =
    List.map
      (fun (container : Docker.Client.container) -> container.image_id)
      containers
  in
  Ok { replaced; declared; candidates; referenced }

(* The Docker client raises on a transport failure -- a refused or vanished
   socket -- rather than answering [Error], and an exception escaping cleanup
   would reach [Deploy.deploy]'s catch-all and fail a deploy whose every step
   succeeded. Every exception is therefore an [Error] here, [Stdlib.Exit]
   included: nothing on this path calls [exit], and re-raising it would fail
   the deploy over cleanup. Cancellation and the runtime faults [Out_of_memory] and
   [Stack_overflow] are re-raised: absorbing cancellation would let a cancelled
   fiber return normally, and the faults are not a cleanup failure. *)
let guarded f =
  try f () with
  | (Eio.Cancel.Cancelled _ | Out_of_memory | Stack_overflow) as fatal ->
      raise fatal
  | exn -> Error (Printexc.to_string exn)

(* The two containers whose images a deploy can replace, found by the same
   lookups [Simple.gather_context] uses to decide what it stops, so the image
   recorded here is the one held by the container that is then replaced. *)
let snapshot_replaced ~client ~net ~clock ~service_name =
  let lookup () =
    Docker.Client.with_request_bound ~clock ~what:"image cleanup snapshot"
    @@ fun () ->
    let* traefik =
      Docker.Client.get_container_by_image_name client ~net
        ~image_name:"traefik"
    in
    let* service =
      Docker.Client.get_container_by_name client ~net
        ~container_name:service_name
    in
    Ok
      (List.filter_map
         (Option.map (fun (container : Docker.Client.container) ->
              container.image_id))
         [ service; traefik ])
  in
  match guarded lookup with
  | Ok replaced -> replaced
  | Error reason ->
      Diagnostics.write
        (Printf.sprintf
           "image cleanup warning: could not read the images of the containers \
            this deploy replaces, so cleanup goes ahead without them: %s"
           reason);
      []

let run ~client ~net ~clock ~replaced ~declared =
  match guarded (fun () -> gather ~client ~net ~clock ~replaced ~declared) with
  | Error reason ->
      Diagnostics.write
        ("image cleanup warning: could not read the host's images and \
          containers, so none were removed: " ^ reason)
  | Ok context ->
      let remove image_id =
        guarded (fun () ->
            Docker.Client.remove_image client ~net ~clock ~image_id)
      in
      interpret ~remove ~warn:Diagnostics.write (plan context)
