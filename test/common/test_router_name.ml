open Alcotest
module Router_name = Bondi_common.Router_name

(* Every expected value below was observed against the pinned Traefik v3.6.8
   and Docker Engine on 2026-11-19, one busybox container per name, labelled
   with the name as the router and service segment. *)

(* Each of these was served by its own container, with its router and service
   listed under the name, and Docker accepted it as a container name. *)
let test_router_name_accepts () =
  List.iter
    (fun name ->
      check (result string string)
        (Printf.sprintf "%S is accepted" name)
        (Ok name)
        (Result.map Router_name.to_string
           (Router_name.of_string ~field:"service.name" name)))
    [ "a_b"; "a-b"; "9a"; "az9_-z"; "acme-http2"; "acme" ]

(* Traefik dropped the container's whole configuration for a name holding [.]
   and served nothing. Docker refused the one-character names and the names
   whose first character, or any character, falls outside
   [[a-zA-Z0-9][a-zA-Z0-9_.-]]. The empty name names no router at all. *)
let test_router_name_refuses () =
  List.iter
    (fun name ->
      match Router_name.of_string ~field:"service.name" name with
      | Ok _ -> failf "%S was accepted" name
      | Error msg ->
          check bool
            (Printf.sprintf "the refusal of %S names the field (got %S)" name
               msg)
            true
            (Bondi_common.String_utils.contains ~needle:"service.name" msg);
          check bool
            (Printf.sprintf "the refusal of %S quotes it (got %S)" name msg)
            true
            (Bondi_common.String_utils.contains
               ~needle:(Printf.sprintf "%S" name) msg))
    [
      "a.b";
      "az9_.-z";
      "Api";
      "aZ9_-z";
      "acme-http";
      "A";
      "a";
      "_a";
      "-a";
      ".a";
      "a b";
      "a/b";
      "a:b";
      "\xc3\xa9";
      "";
    ]

(* Traefik's reference says "Labels are case-insensitive", and the name is a
   segment of a label key, so [Api] and [api] would be one router. The refusal
   says so. *)
let test_uppercase_refusal_says_why () =
  match Router_name.of_string ~field:"service.name" "Api" with
  | Ok _ -> fail "Api was accepted"
  | Error msg ->
      check bool "the refusal says labels are case-insensitive" true
        (Bondi_common.String_utils.contains ~needle:"case-insensitive" msg)

(* Every name Bondi's own Traefik container defines is refused, and the refusal
   says why. *)
let test_reserved_names_refused_with_reason () =
  List.iter
    (fun name ->
      match Router_name.of_string ~field:"service.name" name with
      | Ok _ -> failf "%S was accepted" name
      | Error msg ->
          check bool
            (Printf.sprintf "the refusal of %S says it is reserved" name)
            true
            (Bondi_common.String_utils.contains ~needle:"reserved" msg))
    Router_name.reserved

let () =
  run "Router_name"
    [
      ( "Router_name",
        [
          test_case "accepts" `Quick test_router_name_accepts;
          test_case "refuses" `Quick test_router_name_refuses;
          test_case "uppercase refusal says why" `Quick
            test_uppercase_refusal_says_why;
          test_case "reserved refusal says why" `Quick
            test_reserved_names_refused_with_reason;
        ] );
    ]
