open Alcotest
module Acme_ca_server = Bondi_common.Acme_ca_server

(* Let's Encrypt staging's directory, and the directory of a Pebble reached by
   its container name on a Docker network, as Traefik was pointed at it. Each
   prints back exactly as written. *)
let test_acme_ca_server_accepts_https () =
  List.iter
    (fun url ->
      match Acme_ca_server.of_string url with
      | Error msg -> failf "%S was refused: %s" url msg
      | Ok server ->
          check string
            (Printf.sprintf "%S prints back unchanged" url)
            url
            (Acme_ca_server.to_string server))
    [
      "https://acme-staging-v02.api.letsencrypt.org/directory";
      "https://pebble:14000/dir";
    ]

(* An ACME directory is served over HTTPS, so a plain-http URL, a URL with no
   scheme, a relative path, a URL naming no host, and the empty string are each
   refused, quoting what was rejected. *)
let test_acme_ca_server_refuses () =
  List.iter
    (fun url ->
      match Acme_ca_server.of_string url with
      | Ok _ -> failf "%S was accepted" url
      | Error msg ->
          check bool
            (Printf.sprintf "the refusal of %S quotes it (got %S)" url msg)
            true
            (Bondi_common.String_utils.contains
               ~needle:(Printf.sprintf "%S" url) msg))
    [
      "http://pebble:14000/dir";
      "pebble:14000/dir";
      "/dir";
      "https://";
      "";
      "https://exa mple.com";
      "https://example.com/dir\n";
      "https://example.com/\tdir";
      "https:///dir";
      (* The scheme is matched as written: Traefik is handed the text as is. *)
      "HTTPS://example.com/dir";
    ]

let () =
  run "Acme_ca_server"
    [
      ( "Acme_ca_server",
        [
          test_case "accepts https" `Quick test_acme_ca_server_accepts_https;
          test_case "refuses" `Quick test_acme_ca_server_refuses;
        ] );
    ]
