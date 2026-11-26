open Alcotest
module Cron_job_name = Bondi_common.Cron_job_name
module Builtin_container = Bondi_common.Builtin_container
module Router_name = Bondi_common.Router_name

let pp_holder ppf = function
  | Cron_job_name.Builtin n -> Format.fprintf ppf "Builtin %S" n
  | Cron_job_name.Service n -> Format.fprintf ppf "Service %S" n
  | Cron_job_name.Blue_green_candidate n ->
      Format.fprintf ppf "Blue_green_candidate %S" n
  | Cron_job_name.Managed n -> Format.fprintf ppf "Managed %S" n
  | Cron_job_name.Cron_job n -> Format.fprintf ppf "Cron_job %S" n

let holder_equal a b =
  match (a, b) with
  | Cron_job_name.Builtin a, Cron_job_name.Builtin b
  | Cron_job_name.Service a, Cron_job_name.Service b
  | Cron_job_name.Blue_green_candidate a, Cron_job_name.Blue_green_candidate b
  | Cron_job_name.Managed a, Cron_job_name.Managed b
  | Cron_job_name.Cron_job a, Cron_job_name.Cron_job b ->
      String.equal a b
  | ( ( Cron_job_name.Builtin _ | Cron_job_name.Service _
      | Cron_job_name.Blue_green_candidate _ | Cron_job_name.Managed _
      | Cron_job_name.Cron_job _ ),
      _ ) ->
      false

let holder = testable pp_holder holder_equal

let pp_collision ppf { Cron_job_name.job; holder } =
  Format.fprintf ppf "{ job = %S; holder = %a }" job pp_holder holder

let collision =
  testable pp_collision (fun a b ->
      String.equal a.Cron_job_name.job b.Cron_job_name.job
      && holder_equal a.holder b.holder)

let service_named name =
  match Router_name.of_string ~field:"service" name with
  | Ok service -> service
  | Error message -> fail message

let web = Some (service_named "web")
let builtin_names = Builtin_container.[ orchestrator; traefik; alloy ]

let test_reserved_lists_every_class () =
  check (list holder) "built-ins, then the service and candidate, then managed"
    [
      Cron_job_name.Builtin Builtin_container.orchestrator;
      Cron_job_name.Builtin Builtin_container.traefik;
      Cron_job_name.Builtin Builtin_container.alloy;
      Cron_job_name.Service "web";
      Cron_job_name.Blue_green_candidate "web-new";
      Cron_job_name.Managed "bondi-db";
    ]
    (Cron_job_name.reserved ~service:web ~managed:[ "bondi-db" ])

let collisions_of jobs =
  Cron_job_name.collisions ~service:web ~managed:[ "bondi-db" ] jobs

let test_collision_per_holder () =
  let case label jobs expected =
    check (list collision) label expected (collisions_of jobs)
  in
  case "a job named after the service" [ "web" ]
    [ { job = "web"; holder = Cron_job_name.Service "web" } ];
  case "a job named after the candidate" [ "web-new" ]
    [
      { job = "web-new"; holder = Cron_job_name.Blue_green_candidate "web-new" };
    ];
  case "a job named after a built-in" [ "bondi-traefik" ]
    [
      {
        job = "bondi-traefik";
        holder = Cron_job_name.Builtin Builtin_container.traefik;
      };
    ];
  case "a job named after a managed container" [ "bondi-db" ]
    [ { job = "bondi-db"; holder = Cron_job_name.Managed "bondi-db" } ];
  case "two jobs of one name report once, on the second" [ "x"; "x" ]
    [ { job = "x"; holder = Cron_job_name.Cron_job "x" } ];
  case "every collision is reported, in job order"
    [ "bondi-db"; "free"; "web" ]
    [
      { job = "bondi-db"; holder = Cron_job_name.Managed "bondi-db" };
      { job = "web"; holder = Cron_job_name.Service "web" };
    ]

(* The absence arm's affirmative twin is the candidate case above: the same job
   name collides once there is a service. *)
let test_no_service_reserves_no_candidate () =
  check (list holder) "only the built-ins are reserved"
    (List.map (fun n -> Cron_job_name.Builtin n) builtin_names)
    (Cron_job_name.reserved ~service:None ~managed:[]);
  check (list collision) "a -new job collides with nothing" []
    (Cron_job_name.collisions ~service:None ~managed:[] [ "web-new" ])

let contains ~needle hay = Bondi_common.String_utils.contains ~needle hay

let test_message_names_both_entries () =
  let case job holder ~class_ ~holder_name =
    let message = Cron_job_name.collision_to_string { job; holder } in
    check bool
      (Printf.sprintf "%S names the job %S" message job)
      true
      (contains ~needle:job message);
    check bool
      (Printf.sprintf "%S names the class %S" message class_)
      true
      (contains ~needle:class_ message);
    check bool
      (Printf.sprintf "%S names the holder %S" message holder_name)
      true
      (contains ~needle:holder_name message)
  in
  (* The holder's name differs from the job's in every case but the cron one,
     so a message naming only the job fails the holder check. *)
  case "a" (Cron_job_name.Builtin "bondi-alloy") ~class_:"built-in container"
    ~holder_name:"bondi-alloy";
  case "b" (Cron_job_name.Service "web") ~class_:"service" ~holder_name:"web";
  case "c" (Cron_job_name.Blue_green_candidate "web-new")
    ~class_:"blue-green candidate" ~holder_name:"web-new";
  case "d" (Cron_job_name.Managed "bondi-db") ~class_:"managed container"
    ~holder_name:"bondi-db";
  case "e" (Cron_job_name.Cron_job "x") ~class_:"another cron job"
    ~holder_name:"x"

(* Names of the shapes real manifests use. *)
let test_realistic_names_accepted () =
  check (list collision) "app" []
    (Cron_job_name.collisions
       ~service:(Some (service_named "app"))
       ~managed:[] [ "alert-check" ]);
  check (list collision) "app" []
    (Cron_job_name.collisions
       ~service:(Some (service_named "app-server"))
       ~managed:[ "bondi-app-db" ] [ "app-backup" ]);
  check (list collision) "cron-trading-systems" []
    (Cron_job_name.collisions ~service:None ~managed:[] [ "canary-paper" ])

module Gen = QCheck2.Gen

(* Names over a three-letter alphabet, so random names clash with each other
   often. Each is in the router-name grammar and none is a reserved router
   name. *)
let small_name =
  Gen.string_size ~gen:(Gen.oneof_list [ 'a'; 'b'; '0' ]) (Gen.int_range 2 3)

(* [small_name] is in the router-name grammar and is not a reserved router
   name, so the refusal cannot happen. *)
let router_name s =
  match Router_name.of_string ~field:"service" s with
  | Ok r -> r
  | Error e -> failwith ("generator: unreachable — small_name is valid: " ^ e)

let payload =
  let open Gen in
  let* service = option small_name in
  let* managed =
    list_size (int_range 0 3) (map (fun n -> "bondi-" ^ n) small_name)
  in
  let seeded =
    List.concat
      [
        builtin_names;
        (match service with
        | None -> []
        | Some s -> [ s; s ^ "-new" ]);
        managed;
      ]
  in
  let+ jobs =
    list_size (int_range 0 6) (oneof [ oneof_list seeded; small_name ])
  in
  (Option.map router_name service, managed, jobs)

let print_payload (service, managed, jobs) =
  let service = Option.map Router_name.to_string service in
  let strings xs = String.concat "; " (List.map (Printf.sprintf "%S") xs) in
  Printf.sprintf "service=%s managed=[%s] jobs=[%s]"
    (match service with
    | None -> "None"
    | Some s -> Printf.sprintf "%S" s)
    (strings managed) (strings jobs)

(* Written from the rule, without the module: compare each job against every
   fixed holder and every earlier job, pair by pair. A job equal to several
   earlier jobs clashes with the cron class once. *)
let oracle ~service ~managed jobs =
  let fixed =
    List.concat
      [
        List.map (fun n -> (n, Cron_job_name.Builtin n)) builtin_names;
        (match service with
        | None -> []
        | Some s ->
            [
              (s, Cron_job_name.Service s);
              (s ^ "-new", Cron_job_name.Blue_green_candidate (s ^ "-new"));
            ]);
        List.map (fun n -> (n, Cron_job_name.Managed n)) managed;
      ]
  in
  List.concat
    (List.mapi
       (fun i job ->
         let with_fixed =
           List.filter_map
             (fun (name, h) ->
               match String.equal name job with
               | true -> Some { Cron_job_name.job; holder = h }
               | false -> None)
             fixed
         in
         let earlier =
           List.filteri (fun k other -> k < i && other = job) jobs
         in
         match earlier with
         | [] -> with_fixed
         | _ :: _ ->
             with_fixed
             @ [ { Cron_job_name.job; holder = Cron_job_name.Cron_job job } ])
       jobs)

let prop_collisions_match_pairwise_oracle =
  QCheck_alcotest.to_alcotest ~speed_level:`Quick
    (QCheck2.Test.make ~count:2000
       ~name:"collisions are exactly the pairwise oracle's clashes"
       ~print:print_payload payload (fun (service, managed, jobs) ->
         let reported = Cron_job_name.collisions ~service ~managed jobs in
         let expected =
           oracle
             ~service:(Option.map Router_name.to_string service)
             ~managed jobs
         in
         (* Each reported collision's job and holder are compared as a pair,
            and the multisets must match, so the empty result occurs exactly
            when the oracle finds nothing. *)
         let sort = List.sort compare in
         sort reported = sort expected && reported = [] = (expected = [])))

let test_refusal_sentence () =
  check (option string) "no collisions, no refusal" None
    (Cron_job_name.refusal []);
  let c1 = { Cron_job_name.job = "web"; holder = Service "web" } in
  let c2 = { Cron_job_name.job = "x"; holder = Cron_job "x" } in
  check (option string) "every collision named, in order"
    (Some
       (Printf.sprintf
          "cron jobs cannot take names already in use (%s; %s): rename these \
           jobs in bondi.yaml"
          (Cron_job_name.collision_to_string c1)
          (Cron_job_name.collision_to_string c2)))
    (Cron_job_name.refusal [ c1; c2 ])

let test_path_names () =
  List.iter
    (fun name -> check bool name true (Cron_job_name.is_safe_path_name name))
    [ "nightly"; "a.b_c-d"; "9lives" ];
  List.iter
    (fun name -> check bool name false (Cron_job_name.is_safe_path_name name))
    [ ""; "../x"; ".hidden"; "a/b"; "-x" ];
  check (option string) "safe names, no refusal" None
    (Cron_job_name.unsafe_path_refusal [ "a"; "b" ]);
  check (option string) "unsafe names named, safe ones left out"
    (Some
       "cron job names must be safe to place in a file path (\"../x\", \
        \"a/b\"). A name must begin with a letter or a digit and may hold only \
        letters, digits, '.', '_' and '-': rename these jobs in bondi.yaml")
    (Cron_job_name.unsafe_path_refusal [ "ok"; "../x"; "a/b" ])

let () =
  run "Cron_job_name"
    [
      ( "Cron_job_name",
        [
          test_case "refusal sentence" `Quick test_refusal_sentence;
          test_case "path names" `Quick test_path_names;
          test_case "reserved lists every class" `Quick
            test_reserved_lists_every_class;
          test_case "collision per holder" `Quick test_collision_per_holder;
          test_case "no service reserves no candidate" `Quick
            test_no_service_reserves_no_candidate;
          test_case "message names both entries" `Quick
            test_message_names_both_entries;
          test_case "realistic names accepted" `Quick
            test_realistic_names_accepted;
          prop_collisions_match_pairwise_oracle;
        ] );
    ]
