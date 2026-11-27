open Alcotest
module P = Bondi_common.Proxyless_strategy

let strategy = testable (fun ppf s -> Fmt.string ppf (P.to_string s)) ( = )

(* The token is what the client sends and the server reads, so each reads the
   other's: the round trip, and the tokens that are not strategies. *)
let test_tokens () =
  List.iter
    (fun s ->
      check (option strategy) "a strategy reads back from its token" (Some s)
        (P.of_string (P.to_string s)))
    [ P.Simple; P.Blue_green ];
  check string "blue-green's token" "blue-green" (P.to_string P.Blue_green);
  List.iter
    (fun token ->
      check (option strategy)
        ("not a strategy: " ^ token)
        None (P.of_string token))
    [ "auto"; "Simple"; "BLUE-GREEN"; "blue_green"; ""; " simple" ]

let sentence ~service ~domain s = P.blue_green_refusal ~service ~domain s

(* Blue-green without a domain is the refusal, and nothing else is: the pair is
   what is refused, not either half. *)
let test_refusal () =
  (match sentence ~service:(Some "web") ~domain:None P.Blue_green with
  | None -> fail "expected blue-green without a domain to be refused"
  | Some text ->
      check string "the sentence"
        "service web declares deployment_strategy blue-green and no traefik: \
         block. Blue-green switches traffic through the proxy, so it needs \
         one: declare traefik:, or declare simple or no strategy"
        text);
  (match sentence ~service:None ~domain:None P.Blue_green with
  | None -> fail "expected a request naming no service to be refused"
  | Some text ->
      check bool "it says the request names no service" true
        (String.starts_with ~prefix:"a request that names no service" text));
  check (option string) "with a domain" None
    (sentence ~service:(Some "web") ~domain:(Some "web.example.com")
       P.Blue_green);
  check (option string) "simple without a domain" None
    (sentence ~service:(Some "web") ~domain:None P.Simple);
  check (option string) "simple with a domain" None
    (sentence ~service:(Some "web") ~domain:(Some "web.example.com") P.Simple)

let test_auto_notice () =
  check (option string) "no strategy and no domain"
    (Some "service web has no traefik: block; deploying with simple")
    (P.auto_without_proxy_notice ~service:"web" ~domain:None ~declared:None);
  check (option string) "a domain" None
    (P.auto_without_proxy_notice ~service:"web" ~domain:(Some "d.example.com")
       ~declared:None);
  List.iter
    (fun declared ->
      check (option string)
        ("a declared strategy: " ^ declared)
        None
        (P.auto_without_proxy_notice ~service:"web" ~domain:None
           ~declared:(Some declared)))
    [ "simple"; "blue-green"; "bogus" ];
  check string "the reason the server reports" "no traefik: block"
    P.no_proxy_reason

let () =
  run "Proxyless strategy"
    [
      ( "proxyless strategy",
        [
          test_case "tokens round-trip and others are refused" `Quick
            test_tokens;
          test_case "blue-green without a domain is refused" `Quick test_refusal;
          test_case "auto without a proxy is noticed" `Quick test_auto_notice;
        ] );
    ]
