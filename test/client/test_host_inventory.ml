open Alcotest
module Inventory = Bondi_client.Host_inventory

let contains = Test_helpers.contains

(* --- Fixtures ---

   Both fixtures reproduce what the real commands print, tab-separated, with no
   header line because both carry a --format template. The inspection fixture's
   empty health field is the point: Docker records no health status for a
   container whose check has not run, so the template emits nothing between the
   tabs. A fixture that put a convenient word there would let a "running means
   healthy" implementation pass every test below.

   The declaration field is the other half of that, and it is not decoration: a
   live daemon reports Status "" both for a container that declares no
   healthcheck and for one that declares a check Docker has not run — an exited
   mariadb carries {"Status":"","FailingStreak":0,"Log":null} beside a
   Config.Healthcheck that is plainly there. *)

let listing_of rows =
  rows
  |> List.map (fun (name, image, state) ->
      Printf.sprintf "%s\t%s\t%s" name image state)
  |> String.concat "\n"
  |> fun body -> body ^ "\n"

let inspection_of rows =
  rows
  |> List.map (fun (name, declaration, health, restarts, created) ->
      Printf.sprintf "/%s\t%s\t%s\t%s\t%s" name declaration health restarts
        created)
  |> String.concat "\n"
  |> fun body -> body ^ "\n"

let created = "2026-08-01T10:00:00.123456789Z"

(* The one builder every test below reads through. Each test varies exactly one
   of its two arguments, so a difference in an outcome can only have come from
   the input under test. *)
let inventory
    ?(listing =
      Ok (listing_of [ ("ib-gateway", "ib/gateway:latest", "running") ]))
    ?(inspection =
      Ok (inspection_of [ ("ib-gateway", "declared", "healthy", "0", created) ]))
    () =
  Inventory.of_reads ~listing ~inspection

(* Vary only what the host said about health, over one container that is running
   in every arm. Running is what a naive derivation reads as healthy, so it is
   the state every health test shares. *)
let health_reported ~declaration ~status =
  inventory
    ~inspection:
      (Ok (inspection_of [ ("ib-gateway", declaration, status, "0", created) ]))
    ()

let single_container inventory =
  match inventory with
  | Inventory.Unreadable_listing message ->
      failf "expected an observed inventory, got unreadable: %s" message
  | Inventory.Observed [ container ] -> container
  | Inventory.Observed containers ->
      failf "expected exactly one container, got %d" (List.length containers)

(* --- Tests --- *)

let test_inventory_parses_ps_listing () =
  let listing =
    listing_of
      [
        ("bondi-orchestrator", "mlopez1506/bondi-server:0.10.3", "running");
        ("bondi-traefik", "traefik:v3.0", "running");
        ("legacy-worker", "old/worker:1.2", "exited");
      ]
  in
  let inspection =
    inspection_of
      [
        ("bondi-orchestrator", "undeclared", "", "0", created);
        ("bondi-traefik", "declared", "healthy", "3", created);
        ("legacy-worker", "undeclared", "", "0", created);
      ]
  in
  match inventory ~listing:(Ok listing) ~inspection:(Ok inspection) () with
  | Inventory.Unreadable_listing message ->
      failf "expected an observed inventory, got unreadable: %s" message
  | Inventory.Observed containers ->
      check (list string) "every container is observed, in listing order"
        [ "bondi-orchestrator"; "bondi-traefik"; "legacy-worker" ]
        (List.map (fun (c : Inventory.container) -> c.name) containers);
      check (list string) "each carries the state the host reported"
        [ "running"; "running"; "exited" ]
        (List.map (fun (c : Inventory.container) -> c.state) containers);
      let restarts =
        List.map (fun (c : Inventory.container) -> c.restart_count) containers
      in
      check
        (list (option int))
        "the restart count comes from the inspection" [ Some 0; Some 3; Some 0 ]
        restarts;
      check
        (list (option string))
        "so does the creation time"
        [ Some created; Some created; Some created ]
        (List.map (fun (c : Inventory.container) -> c.created_at) containers)

let test_inventory_reads_image_and_tag_separately () =
  let listing =
    listing_of
      [
        ("bondi-traefik", "traefik:v3.0", "running");
        ("ib-gateway", "registry.example.com:5000/ib/gateway:latest", "running");
        ("legacy-worker", "old/worker", "exited");
        ("pinned", "old/worker@sha256:abc123", "exited");
      ]
  in
  let inspection =
    inspection_of
      [
        ("bondi-traefik", "undeclared", "", "0", created);
        ("ib-gateway", "undeclared", "", "0", created);
        ("legacy-worker", "undeclared", "", "0", created);
        ("pinned", "undeclared", "", "0", created);
      ]
  in
  match inventory ~listing:(Ok listing) ~inspection:(Ok inspection) () with
  | Inventory.Unreadable_listing message ->
      failf "expected an observed inventory, got unreadable: %s" message
  | Inventory.Observed containers ->
      let pairs =
        List.map (fun (c : Inventory.container) -> (c.image, c.tag)) containers
      in
      check
        (list (pair string string))
        "the tag is split from the image, and a registry port is not a tag"
        [
          ("traefik", "v3.0");
          ("registry.example.com:5000/ib/gateway", "latest");
          ("old/worker", "");
          ("old/worker@sha256:abc123", "");
        ]
        pairs

(* Docker reports nothing at all for a container that declares no healthcheck,
   and a report that turns silence into a positive result is the defect this
   module exists to prevent. *)
let test_inventory_health_absent_is_no_healthcheck () =
  let container =
    single_container (health_reported ~declaration:"undeclared" ~status:"")
  in
  match container.health with
  | Inventory.No_healthcheck -> ()
  | Inventory.Healthy
  | Inventory.Unhealthy _
  | Inventory.Starting
  | Inventory.Not_recorded
  | Inventory.Unreadable _ ->
      fail
        "a container with no healthcheck must not be reported as any verdict \
         about its health"

(* The same silence, from a container that does declare a check. Reported as no
   healthcheck it reads as "nothing to check here" — a false statement about
   exactly the component this report exists to surface: one that declares a
   check and is not passing it. *)
let test_inventory_declared_health_without_a_verdict_is_not_no_healthcheck () =
  let container =
    single_container (health_reported ~declaration:"declared" ~status:"")
  in
  match container.health with
  | Inventory.Not_recorded -> ()
  | Inventory.No_healthcheck ->
      fail
        "a container that declares a healthcheck must not be reported as \
         declaring none"
  | Inventory.Healthy
  | Inventory.Unhealthy _
  | Inventory.Starting
  | Inventory.Unreadable _ ->
      fail "a healthcheck Docker has not run must not be reported as a verdict"

(* "starting" is Docker's own word for a healthcheck that has not answered yet.
   It is neither a pass nor a failure, and reading it as a pass is the same
   error as reading silence as one. *)
let test_inventory_health_starting_is_not_healthy () =
  let container =
    single_container
      (health_reported ~declaration:"declared" ~status:"starting")
  in
  match container.health with
  | Inventory.Starting -> ()
  | Inventory.Healthy
  | Inventory.Unhealthy _
  | Inventory.No_healthcheck
  | Inventory.Not_recorded
  | Inventory.Unreadable _ ->
      fail
        "a healthcheck that has not answered yet must not be reported as \
         healthy"

(* The affirmative arm for the three above: the same fixture, differing only in
   what the host said, does produce a positive verdict. Without it, an
   implementation that never reports health at all passes all of them. *)
let test_inventory_health_healthy_is_healthy () =
  let container =
    single_container (health_reported ~declaration:"declared" ~status:"healthy")
  in
  match container.health with
  | Inventory.Healthy -> ()
  | Inventory.Unhealthy _
  | Inventory.Starting
  | Inventory.No_healthcheck
  | Inventory.Not_recorded
  | Inventory.Unreadable _ ->
      fail "a passing healthcheck must be reported as healthy"

(* A listing that could not be run says nothing
   about the host: read as an empty inventory it claims every declared component
   is absent, which is a claim about the box that nothing supports. *)
let test_inventory_unreadable_listing_is_not_empty_inventory () =
  match
    inventory ~listing:(Error "command failed (255): Connection closed") ()
  with
  | Inventory.Observed containers ->
      failf "a failed listing must not be an inventory of %d containers"
        (List.length containers)
  | Inventory.Unreadable_listing message ->
      check bool "carries what went wrong" true
        (Bondi_common.String_utils.contains ~needle:"Connection closed" message)

(* The other half of the pair: the same builder, with a listing that ran and
   found nothing, is an inventory — an empty one. *)
let test_inventory_empty_listing_is_an_empty_inventory () =
  match inventory ~listing:(Ok "") () with
  | Inventory.Unreadable_listing message ->
      failf "an empty listing is an observation, not a failure to observe: %s"
        message
  | Inventory.Observed containers ->
      check int "no containers were observed" 0 (List.length containers)

(* A wait costs a bound, and spending one on a container the host has already
   said has no check to pass is how a run that had nothing to wait for waits
   anyway. The pair is the point: a container that declares none is left out,
   and every other reading — including one that could not be read, where the
   wait is the thing that answers the question rather than a guess at it — is
   in. Every container in the listing is running, so what a name's presence
   turns on here is the health beside it and nothing else; what state does to
   the same list is the test below. *)
let test_inventory_names_only_what_there_is_something_to_wait_for () =
  let listing =
    listing_of
      [
        ("passing", "app:1", "running");
        ("failing", "app:1", "running");
        ("still-starting", "app:1", "running");
        ("not-yet-run", "app:1", "running");
        ("unreadable", "app:1", "running");
        ("no-check", "app:1", "running");
      ]
  in
  let inspection =
    inspection_of
      [
        ("passing", "declared", "healthy", "0", created);
        ("failing", "declared", "unhealthy", "0", created);
        ("still-starting", "declared", "starting", "0", created);
        ("not-yet-run", "declared", "", "0", created);
        ("unreadable", "declared", "a word docker never prints", "0", created);
        ("no-check", "undeclared", "", "0", created);
      ]
  in
  check (list string)
    "every container with a check to answer for, and only those"
    [ "passing"; "failing"; "still-starting"; "not-yet-run"; "unreadable" ]
    (Inventory.health_to_wait_for
       (inventory ~listing:(Ok listing) ~inspection:(Ok inspection) ()))

(* A container that is not running has nothing to become. The wait's first act
   is to read the container's state and report it gone, so every stopped
   container on the list costs an SSH session to be told what the listing
   already said — and the verdict it comes back with fails the run.

   This is not a hypothetical shape. A cron job's container sits [exited]
   between runs, which is how the orchestrator has a last run to report at all,
   and a job image built on a stock database or web-server base inherits that
   base's HEALTHCHECK. Waiting on state the host has already reported turns
   every such host into a failed [setup]. Both arms share one listing, so what a
   name's presence turns on is its state and nothing else. *)
let test_inventory_never_waits_on_a_container_that_is_not_running () =
  let listing =
    listing_of
      [
        ("running-with-check", "app:1", "running");
        ("exited-with-check", "job:1", "exited");
        ("created-with-check", "job:1", "created");
      ]
  in
  let inspection =
    inspection_of
      [
        ("running-with-check", "declared", "", "0", created);
        ("exited-with-check", "declared", "", "0", created);
        ("created-with-check", "declared", "", "0", created);
      ]
  in
  check (list string) "only a container that is running is waited on"
    [ "running-with-check" ]
    (Inventory.health_to_wait_for
       (inventory ~listing:(Ok listing) ~inspection:(Ok inspection) ()))

(* [docker inspect] is all-or-nothing over an id list: handed several, it exits
   non-zero if any one of them no longer exists, and prints nothing usable. The
   ids come from a listing taken a moment earlier, so a single container pruned
   in the window between the two reads failed the whole inspection — and every
   container on the host then reported its health as unreadable, on the strength
   of one that had gone.

   Each id is inspected on its own instead, so a container that disappears costs
   its own line and nothing else. That is also what makes this module's promise
   true: the read neither depends on the listing having been taken nor fails
   when a container disappears between the two. *)
let test_inventory_inspection_reads_each_container_on_its_own () =
  let command = Inventory.inspection_command in
  check bool "walks the ids one at a time" true
    (contains ~needle:"while read" command);
  check bool "rather than handing them all to one inspect" false
    (contains ~needle:"xargs" command);
  check bool "and one that has gone does not fail the read" true
    (contains ~needle:"|| true" command)

(* An inspection that named some containers and not others leaves the ones it
   named readable. The pair is the point: the container the inspection reported
   keeps its health, and the one it left out is unreadable rather than assumed
   healthy or dropped from the inventory. *)
let test_inventory_partial_inspection_leaves_the_rest_readable () =
  let listing =
    listing_of
      [ ("survivor", "app:1", "running"); ("pruned", "app:1", "running") ]
  in
  let inspection =
    inspection_of [ ("survivor", "declared", "healthy", "0", created) ]
  in
  match inventory ~listing:(Ok listing) ~inspection:(Ok inspection) () with
  | Inventory.Unreadable_listing message ->
      failf "the listing ran, so this is an inventory: %s" message
  | Inventory.Observed containers -> (
      let health_of name =
        match
          List.find_opt
            (fun (container : Inventory.container) ->
              String.equal container.name name)
            containers
        with
        | Some container -> container.health
        | None -> failf "expected the inventory to hold %s" name
      in
      (match health_of "survivor" with
      | Inventory.Healthy -> ()
      | Inventory.Unhealthy _
      | Inventory.Starting
      | Inventory.No_healthcheck
      | Inventory.Not_recorded
      | Inventory.Unreadable _ ->
          fail
            "a container the inspection did report keeps the health it reported");
      match health_of "pruned" with
      | Inventory.Unreadable _ -> ()
      | Inventory.Healthy
      | Inventory.Unhealthy _
      | Inventory.Starting
      | Inventory.No_healthcheck
      | Inventory.Not_recorded ->
          fail
            "a container the inspection left out has a health nothing read, \
             not one it may be assumed to have")

(* A listing that never ran has not said that no container has a healthcheck. It
   has said nothing, and there is no container to name. *)
let test_inventory_unreadable_listing_names_nothing_to_wait_for () =
  check (list string) "a listing that never ran names no container" []
    (Inventory.health_to_wait_for
       (inventory ~listing:(Error "command failed (255): Connection closed") ()))

let () =
  run "Host_inventory"
    [
      ( "listing",
        [
          test_case "reads every container the host reported" `Quick
            test_inventory_parses_ps_listing;
          test_case "reads the image and its tag as separate fields" `Quick
            test_inventory_reads_image_and_tag_separately;
          test_case "a listing that could not be run is not an empty inventory"
            `Quick test_inventory_unreadable_listing_is_not_empty_inventory;
          test_case "a listing that found nothing is an empty inventory" `Quick
            test_inventory_empty_listing_is_an_empty_inventory;
        ] );
      ( "health",
        [
          test_case "no healthcheck is reported as such" `Quick
            test_inventory_health_absent_is_no_healthcheck;
          test_case "a declared healthcheck Docker has not run is not \"none\""
            `Quick
            test_inventory_declared_health_without_a_verdict_is_not_no_healthcheck;
          test_case "a healthcheck still starting is not healthy" `Quick
            test_inventory_health_starting_is_not_healthy;
          test_case "a passing healthcheck is healthy" `Quick
            test_inventory_health_healthy_is_healthy;
        ] );
      ( "waiting",
        [
          test_case "names only what there is something to wait for" `Quick
            test_inventory_names_only_what_there_is_something_to_wait_for;
          test_case "never names a container that is not running" `Quick
            test_inventory_never_waits_on_a_container_that_is_not_running;
          test_case "a listing that never ran names nothing" `Quick
            test_inventory_unreadable_listing_names_nothing_to_wait_for;
        ] );
      ( "inspection",
        [
          test_case "reads each container on its own" `Quick
            test_inventory_inspection_reads_each_container_on_its_own;
          test_case "a partial inspection leaves the rest readable" `Quick
            test_inventory_partial_inspection_leaves_the_rest_readable;
        ] );
    ]
