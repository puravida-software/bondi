open Alcotest
module Image_cleanup = Bondi_server__Image_cleanup

(* The fixtures model a redeploy from 0.37.0 to 0.37.1 that a running cron pass
   broke: a service and its alert-check cron job, each image tagged by release.
   Ids are full sha256 ids, as [GET /images/json] reports them; the 0.37.0
   service image starts with the short id Docker named in its refusal. *)
let id_0370 =
  "sha256:a44854fbf6b6c0b5d0e4a1d2c3f4e5a6b7c8d9e0f1a2b3c4d5e6f7a8b9c0d1e2"

let id_0371 =
  "sha256:5d1f0c2a9b8e7d6c5b4a39281706f5e4d3c2b1a09f8e7d6c5b4a3928170f6e5d"

let id_0372 =
  "sha256:9e8d7c6b5a4f3e2d1c0b9a8f7e6d5c4b3a2f1e0d9c8b7a6f5e4d3c2b1a0f9e8d"

let id_cron_0371 =
  "sha256:c0ffee0123456789abcdef0123456789abcdef0123456789abcdef0123456789"

let id_cron_0370 =
  "sha256:dec0de0123456789abcdef0123456789abcdef0123456789abcdef0123456789"

(* Docker's 409 for deleting an image a running container uses, prefixed the
   way the client reports a non-2xx status. *)
let recorded_409 =
  {|docker http 409: {"message":"conflict: unable to delete a44854fbf6b6 (cannot be forced) - image is being used by running container 4e37c25a6341"}|}

let action : Image_cleanup.action testable =
  let pp ppf = function
    | Image_cleanup.Remove_image { id } ->
        Format.fprintf ppf "Remove_image %s" id
    | Image_cleanup.Keep_in_use { id } -> Format.fprintf ppf "Keep_in_use %s" id
  in
  let equal a b =
    match (a, b) with
    | ( Image_cleanup.Remove_image { id = a },
        Image_cleanup.Remove_image { id = b } )
    | Image_cleanup.Keep_in_use { id = a }, Image_cleanup.Keep_in_use { id = b }
      ->
        String.equal a b
    | Image_cleanup.Remove_image _, Image_cleanup.Keep_in_use _
    | Image_cleanup.Keep_in_use _, Image_cleanup.Remove_image _ ->
        false
  in
  testable pp equal

let remove id = Image_cleanup.Remove_image { id }
let keep_in_use id = Image_cleanup.Keep_in_use { id }

(* The redeploy to 0.37.1 after the new service container is up: the replaced
   container held 0.37.0, and the new container references 0.37.1. Whether
   anything still references 0.37.0 is the one thing the two tests below
   vary. *)
let redeploy_0371 ~referenced : Image_cleanup.context =
  {
    replaced = [ id_0370 ];
    declared = [ "app:0.37.1"; "app-alert-check:0.37.1" ];
    candidates =
      [
        { id = id_0370; repo_tags = [ "app:0.37.0" ] };
        { id = id_0371; repo_tags = [ "app:0.37.1" ] };
      ];
    referenced;
  }

(* The affirmative arm of the pair: with nothing holding it, the replaced image
   goes, and the new one stays because the new container references it. *)
let test_replaced_unreferenced_is_removed () =
  check (list action) "the replaced image nothing references is removed"
    [ remove id_0370 ]
    (Image_cleanup.plan (redeploy_0371 ~referenced:[ id_0371 ]))

(* The same fixture with an exited cron container still referencing 0.37.0.
   The test above proves this fixture does plan the removal, so the removal's
   absence here is caused by the reference and by nothing else. *)
let test_referenced_by_stopped_container_is_kept () =
  check (list action) "an image any container references is kept"
    [ keep_in_use id_0370 ]
    (Image_cleanup.plan (redeploy_0371 ~referenced:[ id_0371; id_0370 ]))

let id_traefik =
  "sha256:7a3f0e1d2c3b4a5968778695a4b3c2d1e0f9a8b7c6d5e4f3a2b1c0d9e8f7a6b5"

let redeploy_with_traefik ~referenced : Image_cleanup.context =
  { (redeploy_0371 ~referenced) with replaced = [ id_traefik ] }

let test_held_replaced_image_outside_declared_repos_is_silent () =
  check (list action) "unreferenced, it is removed"
    [ remove id_traefik; keep_in_use id_0370 ]
    (Image_cleanup.plan
       (redeploy_with_traefik ~referenced:[ id_0371; id_0370 ]));
  check (list action) "referenced, it is kept without a word"
    [ keep_in_use id_0370 ]
    (Image_cleanup.plan
       (redeploy_with_traefik ~referenced:[ id_0371; id_0370; id_traefik ]))

(* A cron job's image before its first pass: pulled, declared, and used by no
   container. Its earlier tag, equally unused, sits beside it in the same
   fixture, so the plan has something to remove and the declared image's
   absence from it is the exclusion at work. *)
let test_declared_image_is_kept () =
  let context : Image_cleanup.context =
    {
      replaced = [];
      declared = [ "app:0.37.1"; "app-alert-check:0.37.1" ];
      candidates =
        [
          { id = id_cron_0370; repo_tags = [ "app-alert-check:0.37.0" ] };
          { id = id_cron_0371; repo_tags = [ "app-alert-check:0.37.1" ] };
        ];
      referenced = [];
    }
  in
  check (list action) "the declared cron image is kept, its earlier tag is not"
    [ remove id_cron_0370 ]
    (Image_cleanup.plan context)

(* The deploy after it: 0.37.2 replaces 0.37.1, and the 0.37.0 image
   a cron pass held through the previous deploy is now referenced by nothing.
   It is no replaced container's image, so only the repository listing finds
   it. Replaced ids come first, then candidates, as [plan] documents. *)
let test_earlier_tag_of_declared_repo_is_removed () =
  let context : Image_cleanup.context =
    {
      replaced = [ id_0371 ];
      declared = [ "app:0.37.2"; "app-alert-check:0.37.2" ];
      candidates =
        [
          { id = id_0370; repo_tags = [ "app:0.37.0" ] };
          { id = id_0371; repo_tags = [ "app:0.37.1" ] };
          { id = id_0372; repo_tags = [ "app:0.37.2" ] };
        ];
      referenced = [ id_0372 ];
    }
  in
  check (list action) "0.37.1 and 0.37.0 go, 0.37.2 stays"
    [ remove id_0371; remove id_0370 ]
    (Image_cleanup.plan context)

(* The replaced service image is also a candidate of its own repository, and
   when the service and a cron job share that repository the listing reports it
   once per declared reference. Removing it more than once would make every
   later attempt fail with a 404 and warn about an image already gone. *)
let test_id_planned_once () =
  let context : Image_cleanup.context =
    {
      replaced = [ id_0370 ];
      declared = [ "app:0.37.1"; "app:0.37.1" ];
      candidates =
        [
          { id = id_0370; repo_tags = [ "app:0.37.0" ] };
          { id = id_0371; repo_tags = [ "app:0.37.1" ] };
          { id = id_0370; repo_tags = [ "app:0.37.0" ] };
          { id = id_0371; repo_tags = [ "app:0.37.1" ] };
        ];
      referenced = [ id_0371 ];
    }
  in
  check (list action) "an id replaced and listed twice is removed once"
    [ remove id_0370 ]
    (Image_cleanup.plan context)

let expected_warning id reason =
  Printf.sprintf "image cleanup warning: could not remove image %s: %s" id
    reason

(* Runs [interpret] with [remove] answering from [answers] and records what it
   was asked and what it warned, in order. The refs are local to one run. *)
let run_interpret ~answers actions =
  let removed = ref [] in
  let warned = ref [] in
  let remove id =
    removed := id :: !removed;
    answers id
  in
  let warn line = warned := line :: !warned in
  Image_cleanup.interpret ~remove ~warn actions;
  (List.rev !removed, List.rev !warned)

let test_409_warns_once_and_continues () =
  let answers id =
    match String.equal id id_0370 with
    | true -> Error recorded_409
    | false -> Ok ()
  in
  let removed, warned =
    run_interpret ~answers [ remove id_0370; remove id_cron_0370 ]
  in
  check (list string) "the removal after the refused one is still attempted"
    [ id_0370; id_cron_0370 ] removed;
  check (list string) "one warning, naming the refused id and Docker's reason"
    [ expected_warning id_0370 recorded_409 ]
    warned

(* A redeploy that a running cron pass interrupted, end to end through plan and interpret: the listing
   showed 0.37.0 unreferenced, so it is planned, and a cron pass started from
   it before the delete, so Docker refuses. That this returns at all is the
   claim; the warning is how the refusal is recorded. *)
let test_plan_interpret_through_409 () =
  let answers _ = Error recorded_409 in
  let removed, warned =
    run_interpret ~answers
      (Image_cleanup.plan (redeploy_0371 ~referenced:[ id_0371 ]))
  in
  check (list string) "the planned removal was attempted" [ id_0370 ] removed;
  check (list string) "and its refusal became one warning"
    [ expected_warning id_0370 recorded_409 ]
    warned

let expected_kept_line id =
  Printf.sprintf "image cleanup: kept image %s because a container uses it" id

let test_held_image_is_named_and_not_removed () =
  let removed, warned =
    run_interpret
      ~answers:(fun _ -> Ok ())
      (Image_cleanup.plan (redeploy_0371 ~referenced:[ id_0371; id_0370 ]))
  in
  check (list string) "no removal is attempted" [] removed;
  check (list string) "one line names the held image"
    [ expected_kept_line id_0370 ]
    warned

let test_kept_line_does_not_stop_later_removals () =
  let removed, warned =
    run_interpret
      ~answers:(fun _ -> Ok ())
      [ keep_in_use id_cron_0370; remove id_0370 ]
  in
  check (list string) "only the removal reaches remove" [ id_0370 ] removed;
  check (list string) "the kept image is named once"
    [ expected_kept_line id_cron_0370 ]
    warned

module Simple = Bondi_server__Strategy__Simple

(* A cron job with only its name and image set; every other field is spelled
   out as absent, so nothing about the job is a default the test did not
   choose. *)
let cron_job ~name ~image : Simple.cron_job =
  {
    name;
    image;
    schedule = "*/5 * * * *";
    network = None;
    env_vars = None;
    secret_env_vars = None;
    registry_user = None;
    registry_pass = None;
    alert_sinks = None;
    exit_code_severities = None;
  }

(* A deploy request carrying [service_name], [image] and [cron_jobs] as given,
   with every other field spelled out. The credentials are set so that a
   declared list that leaked them would show it. *)
let deploy_input ~service_name ~image ~cron_jobs : Simple.deploy_input =
  {
    service_name;
    image;
    port = Some 8080;
    registry_user = Some "deployer";
    registry_pass = Some "s3cret";
    env_vars = Some [ ("API_KEY", "k3y") ];
    traefik_domain_name = Some "app.example.com";
    traefik_image = Some "traefik:v3.3.0";
    traefik_acme_email = Some "ops@example.com";
    force_traefik_redeploy = None;
    cron_jobs;
    drain_grace_period = None;
    deployment_strategy = None;
    health_timeout = None;
    poll_interval = None;
    logs = None;
    volumes = None;
  }

(* A request carrying the service and its alert-check job at 0.37.1, each
   in a repository of its own on a private registry. *)
let test_declared_covers_service_and_cron_images () =
  let input =
    deploy_input ~service_name:(Some "app")
      ~image:(Some "registry.example.com/org/app:0.37.1")
      ~cron_jobs:
        (Some
           [
             cron_job ~name:"alert-check"
               ~image:"registry.example.com/org/app-alert-check:0.37.1";
             cron_job ~name:"digest"
               ~image:"registry.example.com/org/app-digest:0.12.0";
           ])
  in
  check (list string) "the service image, then each cron job's image"
    [
      "registry.example.com/org/app:0.37.1";
      "registry.example.com/org/app-alert-check:0.37.1";
      "registry.example.com/org/app-digest:0.12.0";
    ]
    (Image_cleanup.declared_of_input input)

(* A cron-only request as the client sends it, with no service name and no
   image: only the cron job's image is the deploy's. *)
let test_declared_for_cron_only_deploy () =
  let input =
    deploy_input ~service_name:None ~image:None
      ~cron_jobs:
        (Some
           [
             cron_job ~name:"alert-check"
               ~image:"registry.example.com/org/app-alert-check:0.37.1";
           ])
  in
  check (list string) "only the cron job's image"
    [ "registry.example.com/org/app-alert-check:0.37.1" ]
    (Image_cleanup.declared_of_input input)

(* The service container runs an untagged image as [latest], so [latest] is the
   tag the listing reports for it and the one that must be declared. *)
let test_declared_defaults_untagged_service_to_latest () =
  let input =
    deploy_input ~service_name:(Some "app")
      ~image:(Some "registry.example.com/org/app") ~cron_jobs:None
  in
  check (list string) "the untagged service image as latest"
    [ "registry.example.com/org/app:latest" ]
    (Image_cleanup.declared_of_input input)

(* A service image the parser rejects is declared as written, so a malformed
   reference is never silently dropped from what is kept. *)
let test_declared_keeps_unparsable_service_image_as_written () =
  let input =
    deploy_input ~service_name:(Some "app") ~image:(Some "host:5000/app:1.0")
      ~cron_jobs:None
  in
  check (list string) "declared as written" [ "host:5000/app:1.0" ]
    (Image_cleanup.declared_of_input input)

(* A declared tag keeps a replaced id even when it arrives through [replaced]
   and the redeploy reuses the tag, with nothing referencing it yet. *)
let test_declared_tag_keeps_replaced_id () =
  let context tag : Image_cleanup.context =
    {
      replaced = [ id_0371 ];
      declared = [ "app:0.37.1" ];
      candidates = [ { id = id_0371; repo_tags = [ tag ] } ];
      referenced = [];
    }
  in
  check (list action) "declared tag: nothing planned" []
    (Image_cleanup.plan (context "app:0.37.1"));
  check (list action) "undeclared tag: removal planned"
    [ remove id_0371 ]
    (Image_cleanup.plan (context "app:0.37.0"))

(* [run] is where the real gather and removal are wrapped in [guarded]; the
   claim that cleanup cannot fail a deploy lives here. *)
exception Docker_unreachable

let unreachable_net exn =
  let net = Eio_mock.Net.make "docker" in
  Eio_mock.Net.on_getaddrinfo net [ `Raise exn ];
  Eio_mock.Net.on_connect net [ `Raise exn ];
  net

let run_cleanup net =
  let clock = Eio_mock.Clock.make () in
  let client = Bondi_server__Docker__Client.create () in
  Image_cleanup.run ~client ~net ~clock ~replaced:[ id_0370 ]
    ~declared:[ "app:0.37.1" ]

let test_run_survives_an_unreachable_docker () =
  Eio_mock.Backend.run @@ fun () ->
  run_cleanup (unreachable_net Docker_unreachable)

let test_run_propagates_cancellation () =
  Eio_mock.Backend.run @@ fun () ->
  match run_cleanup (unreachable_net (Eio.Cancel.Cancelled Exit)) with
  | () -> Alcotest.fail "cancellation must propagate out of run"
  | exception Eio.Cancel.Cancelled _ -> ()

let test_snapshot_survives_an_unreachable_docker () =
  Eio_mock.Backend.run @@ fun () ->
  let clock = Eio_mock.Clock.make () in
  let client = Bondi_server__Docker__Client.create () in
  check (list string) "no ids, no raise" []
    (Image_cleanup.snapshot_replaced ~client
       ~net:(unreachable_net Docker_unreachable)
       ~clock ~service_name:"app")

let () =
  run "image_cleanup"
    [
      ( "declared",
        [
          test_case "declared covers service and cron images" `Quick
            test_declared_covers_service_and_cron_images;
          test_case "declared for cron-only deploy" `Quick
            test_declared_for_cron_only_deploy;
          test_case "declared defaults untagged service to latest" `Quick
            test_declared_defaults_untagged_service_to_latest;
          test_case "declared keeps unparsable service image as written" `Quick
            test_declared_keeps_unparsable_service_image_as_written;
        ] );
      ( "plan",
        [
          test_case "replaced unreferenced is removed" `Quick
            test_replaced_unreferenced_is_removed;
          test_case "referenced by stopped container is kept" `Quick
            test_referenced_by_stopped_container_is_kept;
          test_case "declared image is kept" `Quick test_declared_image_is_kept;
          test_case "earlier tag of declared repo is removed" `Quick
            test_earlier_tag_of_declared_repo_is_removed;
          test_case "id planned once" `Quick test_id_planned_once;
          test_case "held replaced image outside declared repos is silent"
            `Quick test_held_replaced_image_outside_declared_repos_is_silent;
          test_case "declared tag keeps replaced id" `Quick
            test_declared_tag_keeps_replaced_id;
        ] );
      ( "interpret",
        [
          test_case "409 warns once and continues" `Quick
            test_409_warns_once_and_continues;
          test_case "plan then interpret through 409" `Quick
            test_plan_interpret_through_409;
          test_case "held image is named and not removed" `Quick
            test_held_image_is_named_and_not_removed;
          test_case "kept line does not stop later removals" `Quick
            test_kept_line_does_not_stop_later_removals;
        ] );
      ( "run",
        [
          test_case "survives an unreachable docker" `Quick
            test_run_survives_an_unreachable_docker;
          test_case "propagates cancellation" `Quick
            test_run_propagates_cancellation;
          test_case "snapshot survives an unreachable docker" `Quick
            test_snapshot_survives_an_unreachable_docker;
        ] );
    ]
