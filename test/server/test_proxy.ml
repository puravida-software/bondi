open Alcotest
module Proxy = Bondi_server__Proxy
module Docker = Bondi_server__Docker__Client
module Image_reference = Bondi_common.Image_reference

let proxy_name = "/" ^ Bondi_common.Builtin_container.traefik

let requested : Proxy.input =
  {
    image = Test_helpers.image_reference "traefik:v3.3.0";
    domain_name = "example.com";
    acme_email = "admin@example.com";
    acme_ca_server = None;
    force_redeploy = false;
  }

let pebble =
  match Bondi_common.Acme_ca_server.of_string "https://pebble:14000/dir" with
  | Ok server -> server
  | Error msg -> Alcotest.failf "the fixture URL was refused: %s" msg

let container ~names ~image =
  Server_test_helpers.mk_container ~id:"traefik-1" ~image ~names ()

let decision_string = function
  | Proxy.Keep -> "Keep"
  | Proxy.Create -> "Create"
  | Proxy.Replace (c : Docker.container) -> "Replace(" ^ c.id ^ ")"

let action_string = function
  | Proxy.CreateNetwork { network_name } ->
      "CreateNetwork(" ^ network_name ^ ")"
  | Proxy.PullImage { image } ->
      "PullImage(" ^ Image_reference.to_string image ^ ")"
  | Proxy.StopAndRemove { container_id } ->
      "StopAndRemove(" ^ container_id ^ ")"
  | Proxy.EnsureTraefik { traefik_config } ->
      "EnsureTraefik("
      ^ Option.value ~default:"<no image>" traefik_config.container_config.image
      ^ ")"

let decide input current = decision_string (Proxy.decide input ~current)

let planned input current =
  List.map action_string (Proxy.plan input (Proxy.decide input ~current))

(* The proxy is the container under its reserved name. A container running a
   Traefik image under any other name belongs to someone else: it is neither
   adopted when its version matches nor replaced when it differs, so the proxy
   is created beside it and nothing of it is stopped. The affirmative arm is
   the same container under the reserved name, which is found and decided on. *)
let test_found_by_name_not_image () =
  let elsewhere = [ "/someone-elses-proxy" ] in
  check string "a matching Traefik under another name is not adopted" "Create"
    (decide requested
       (Some (container ~names:elsewhere ~image:"traefik:v3.3.0")));
  check string "a differing Traefik under another name is not replaced" "Create"
    (decide requested (Some (container ~names:elsewhere ~image:"traefik:v2.0")));
  check (list string) "nothing of it is stopped"
    [
      "CreateNetwork(bondi-network)";
      "PullImage(traefik:v3.3.0)";
      "EnsureTraefik(traefik:v3.3.0)";
    ]
    (planned requested
       (Some (container ~names:elsewhere ~image:"traefik:v2.0")));
  check string "the same container under the reserved name is the proxy"
    "Replace(traefik-1)"
    (decide requested
       (Some (container ~names:[ proxy_name ] ~image:"traefik:v2.0")));
  check string "and at the requested version it is kept" "Keep"
    (decide requested
       (Some (container ~names:[ proxy_name ] ~image:"traefik:v3.3.0")))

(* Only the version and a forced redeploy replace the proxy. Its other settings
   are not read back from the running container, so a changed certificate
   server alone keeps it, and reaches Traefik once the redeploy is forced. *)
let test_decide_keep_create_replace () =
  let running image = Some (container ~names:[ proxy_name ] ~image) in
  let with_ca = { requested with acme_ca_server = Some pebble } in
  check string "no proxy is created" "Create" (decide requested None);
  check string "an unchanged proxy is kept" "Keep"
    (decide requested (running "traefik:v3.3.0"));
  check string "a changed image replaces it" "Replace(traefik-1)"
    (decide requested (running "traefik:v2.0"));
  check string "a changed digest replaces it" "Replace(traefik-1)"
    (decide
       {
         requested with
         image =
           Test_helpers.image_reference
             ("traefik:v3.3.0@sha256:" ^ String.make 64 'a');
       }
       (running "traefik:v3.3.0"));
  check string "a changed certificate server alone keeps it" "Keep"
    (decide with_ca (running "traefik:v3.3.0"));
  check string "a changed certificate server with the flag replaces it"
    "Replace(traefik-1)"
    (decide { with_ca with force_redeploy = true } (running "traefik:v3.3.0"));
  check string "a forced redeploy of an unchanged proxy replaces it"
    "Replace(traefik-1)"
    (decide { requested with force_redeploy = true } (running "traefik:v3.3.0"))

(* A digest is a version as a tag is, so a new pin replaces the proxy and the
   same pin keeps it. A bare image id parses, as name [sha256] with the hex as
   its tag, and is replaced like any other version. A new name at the same tag
   is not a new version, so the proxy is kept. *)
let test_version_by_tag_and_digest_not_name () =
  let running image = Some (container ~names:[ proxy_name ] ~image) in
  let pin hex = "traefik@sha256:" ^ String.make 64 hex in
  let pinned =
    { requested with image = Test_helpers.image_reference (pin 'b') }
  in
  check string "a new digest replaces it" "Replace(traefik-1)"
    (decide pinned (running (pin 'a')));
  check string "the same digest keeps it" "Keep"
    (decide pinned (running (pin 'b')));
  check string "a bare image id is replaced" "Replace(traefik-1)"
    (decide requested (running ("sha256:" ^ String.make 64 'a')));
  check string "another name at the same tag is kept" "Keep"
    (decide requested (running "registry:5000/proxy:v3.3.0"))

(* The Engine API reads an empty [tag] on an image pull as every tag of the
   repository, so an untagged proxy image is pulled as [latest], which is what
   the engine creates the container from. *)
let test_untagged_proxy_pulls_latest () =
  let untagged =
    { requested with image = Test_helpers.image_reference "traefik" }
  in
  check
    (list (pair string string))
    "pulled at latest, never with an empty tag"
    [ ("traefik", "latest") ]
    (List.filter_map
       (function
         | Proxy.PullImage { image } ->
             Some (Image_reference.name image, Image_reference.pull_tag image)
         | Proxy.CreateNetwork _
         | Proxy.StopAndRemove _
         | Proxy.EnsureTraefik _ ->
             None)
       (Proxy.plan untagged (Proxy.decide untagged ~current:None)))

(* A proxy image that cannot be pulled must leave the running proxy serving, so
   every plan that stops one pulls its successor first, and the new proxy is
   created last. Each plan is pinned whole. Keep is the twin: nothing is pulled
   or stopped. *)
let test_pull_precedes_stop () =
  let running image = Some (container ~names:[ proxy_name ] ~image) in
  let replaced =
    [
      "CreateNetwork(bondi-network)";
      "PullImage(traefik:v3.3.0)";
      "StopAndRemove(traefik-1)";
      "EnsureTraefik(traefik:v3.3.0)";
    ]
  in
  check (list string) "create"
    [
      "CreateNetwork(bondi-network)";
      "PullImage(traefik:v3.3.0)";
      "EnsureTraefik(traefik:v3.3.0)";
    ]
    (planned requested None);
  check (list string) "replace on a changed image" replaced
    (planned requested (running "traefik:v2.0"));
  check (list string) "replace on a forced redeploy" replaced
    (planned
       { requested with force_redeploy = true }
       (running "traefik:v3.3.0"));
  let forced_with_ca =
    { requested with acme_ca_server = Some pebble; force_redeploy = true }
  in
  check (list string) "replace on a changed certificate server, forced" replaced
    (planned forced_with_ca (running "traefik:v3.3.0"));
  check (list string) "keep"
    [ "CreateNetwork(bondi-network)" ]
    (planned requested (running "traefik:v3.3.0"))

(* The certificate server reaches the Traefik the plan creates. *)
let test_replacement_carries_the_certificate_server () =
  let forced_with_ca =
    { requested with acme_ca_server = Some pebble; force_redeploy = true }
  in
  let commands =
    List.filter_map
      (function
        | Proxy.EnsureTraefik { traefik_config } ->
            traefik_config.container_config.cmd
        | Proxy.CreateNetwork _
        | Proxy.PullImage _
        | Proxy.StopAndRemove _ ->
            None)
      (Proxy.plan forced_with_ca
         (Proxy.decide forced_with_ca
            ~current:
              (Some (container ~names:[ proxy_name ] ~image:"traefik:v3.3.0"))))
  in
  check (list bool) "the one created Traefik is sent the server" [ true ]
    (List.map
       (List.mem
          "--certificatesResolvers.bondi_resolver.acme.caServer=https://pebble:14000/dir")
       commands)

let () =
  run "Proxy"
    [
      ( "decide",
        [
          test_case "found by name, not by image" `Quick
            test_found_by_name_not_image;
          test_case "keep, create or replace" `Quick
            test_decide_keep_create_replace;
          test_case "version by tag and digest, not name" `Quick
            test_version_by_tag_and_digest_not_name;
        ] );
      ( "plan",
        [
          test_case "an untagged proxy pulls latest" `Quick
            test_untagged_proxy_pulls_latest;
          test_case "the pull precedes the stop" `Quick test_pull_precedes_stop;
          test_case "the replacement carries the certificate server" `Quick
            test_replacement_carries_the_certificate_server;
        ] );
    ]
