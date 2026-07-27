open Alcotest
module M = Bondi_common.Managed_container

let default_env =
  [
    ("TRADING_MODE", M.Plain "paper");
    ("TWS_USERID", M.Plain "someuser");
    ("TWS_PASSWORD", M.Secret "hunter2");
  ]

let spec ?(name = "ib-gateway") ?(image = "gnzsnz/ib-gateway")
    ?(tag = "10.48.1e") ?(restart = M.Unless_stopped)
    ?(network = Some "bondi-network")
    ?(ports = [ { M.host = 4002; container = 4002 } ]) ?(env = default_env) () =
  M.create ~name ~image ~tag ~restart ~network ~ports ~env

let built ?name ?image ?tag ?restart ?network ?ports ?env () =
  match spec ?name ?image ?tag ?restart ?network ?ports ?env () with
  | Ok t -> t
  | Error e -> fail ("expected a valid spec, got: " ^ M.error_to_string e)

let base = built ()
let contains ~needle hay = Bondi_common.String_utils.contains ~needle hay

let has_traefik_label labels =
  List.exists
    (fun (key, _) ->
      Bondi_common.String_utils.starts_with ~prefix:"traefik" key)
    labels

(* --- create: validation --- *)

let rejects label expected result =
  match result with
  | Ok _ -> fail (label ^ ": expected rejection, got a valid spec")
  | Error actual ->
      check bool
        (label ^ " is rejected with the right reason")
        true (actual = expected)

let test_create_rejects_path_traversal_names () =
  (* The name becomes a path segment that later receives a secrets file and is
     deleted recursively, so separators and relative segments must not be
     representable. *)
  rejects "parent traversal" (M.Invalid_name "../etc") (spec ~name:"../etc" ());
  rejects "absolute path" (M.Invalid_name "/etc/passwd")
    (spec ~name:"/etc/passwd" ());
  rejects "nested separator" (M.Invalid_name "a/b") (spec ~name:"a/b" ());
  rejects "bare parent" (M.Invalid_name "..") (spec ~name:".." ());
  rejects "leading dot" (M.Invalid_name ".hidden") (spec ~name:".hidden" ())

let test_create_rejects_empty_fields () =
  rejects "empty name" M.Empty_name (spec ~name:"" ());
  rejects "empty image" M.Empty_image (spec ~image:"" ());
  rejects "empty tag" M.Empty_tag (spec ~tag:"" ())

(* Bondi creates [bondi-network] and no other, so a container declaring a
   different name would be handed an empty network it can reach nothing
   through, or fail at container-creation time with a Docker error — the same
   silent-then-obscure failure a cron job declaring one is rejected for. The
   rejection happens here, in the smart constructor, so the two declarations of
   the same field cannot diverge. *)
let test_create_rejects_an_unmanaged_network () =
  rejects "a network bondi does not manage"
    (M.Unmanaged_network "other-network")
    (spec ~network:(Some "other-network") ());
  rejects "a typo of the managed network" (M.Unmanaged_network "bondi-netwrok")
    (spec ~network:(Some "bondi-netwrok") ())

(* The affirmative arms: the one accepted name, and the absence of the field.
   Without these a constructor that rejected every network would pass above. *)
let test_create_accepts_the_managed_network_and_none () =
  (match spec ~network:(Some Bondi_common.Defaults.network_name) () with
  | Ok built ->
      check (option string) "the managed network survives"
        (Some Bondi_common.Defaults.network_name) (M.network built)
  | Error e ->
      fail ("the managed network must be accepted: " ^ M.error_to_string e));
  match spec ~network:None () with
  | Ok built ->
      check (option string) "declaring no network stays absent" None
        (M.network built)
  | Error e -> fail ("no network must be accepted: " ^ M.error_to_string e)

(* The message must name what was declared and what is accepted; an operator
   reading only "invalid network" cannot tell which of the two it was. *)
let test_unmanaged_network_message_names_both () =
  let msg = M.error_to_string (M.Unmanaged_network "other-network") in
  List.iter
    (fun needle ->
      check bool
        (Printf.sprintf "the message names %s: %s" needle msg)
        true (contains ~needle msg))
    [ "other-network"; Bondi_common.Defaults.network_name ]

let test_create_accepts_conventional_names () =
  let accepts name =
    match spec ~name () with
    | Ok built -> check string "name survives validation" name (M.name built)
    | Error e -> fail (name ^ " should be valid: " ^ M.error_to_string e)
  in
  accepts "ib-gateway";
  accepts "ib_gateway";
  accepts "ibgateway2";
  accepts "ib.gateway"

(* --- accessors --- *)

let test_accessors_return_declared_values () =
  check string "image" "gnzsnz/ib-gateway" (M.image base);
  check string "tag" "10.48.1e" (M.tag base);
  check (option string) "network" (Some "bondi-network") (M.network base);
  check bool "restart" true (M.restart base = M.Unless_stopped);
  check int "port count" 1 (List.length (M.ports base))

(* --- container_name --- *)

let test_container_name_is_prefixed () =
  check string "container name is bondi-prefixed" "bondi-ib-gateway"
    (M.container_name base)

(* --- secret env file --- *)

let test_env_file_contains_only_secrets () =
  (* Asserted as exact contents, including the trailing newline, so that a
     renderer emitting an unterminated line cannot alias a longer key. *)
  check (option string) "env file holds exactly the secret entries"
    (Some "TWS_PASSWORD=hunter2\n")
    (M.secret_env_file_contents base)

let test_env_file_terminates_every_line () =
  let two_secrets =
    built
      ~env:
        [
          ("TWS_PASSWORD", M.Secret "hunter2");
          ("TWS_USERID", M.Secret "someuser");
        ]
      ()
  in
  check (option string) "one terminated line per secret, in declared order"
    (Some "TWS_PASSWORD=hunter2\nTWS_USERID=someuser\n")
    (M.secret_env_file_contents two_secrets)

let test_secret_env_file_none_when_no_secrets () =
  let no_secrets = built ~env:[ ("TRADING_MODE", M.Plain "paper") ] () in
  check (option string) "no env file when nothing is secret" None
    (M.secret_env_file_contents no_secrets)

let test_plain_env_excludes_secrets () =
  check
    (list (pair string string))
    "only plain values, in declared order"
    [ ("TRADING_MODE", "paper"); ("TWS_USERID", "someuser") ]
    (M.plain_env base)

(* --- spec_hash --- *)

(* One arm per field. The record behind [t] is abstract, so no compiler warning
   can report a field that spec_hash forgot to digest — these assertions are the
   only thing that catches it, so each varies exactly one field. *)
let test_spec_hash_covers_every_field () =
  let differs label mutated =
    check bool
      (label ^ " changes the spec hash")
      false
      (String.equal (M.spec_hash base) (M.spec_hash mutated))
  in
  differs "name" (built ~name:"ib-gateway-paper" ());
  differs "image" (built ~image:"ghcr.io/acme/ib-gateway" ());
  differs "tag" (built ~tag:"10.45.1h" ());
  differs "restart" (built ~restart:M.Always ());
  (* Only [Some bondi-network] and [None] are constructible, so withdrawing the
     field is the only mutation this arm can make. *)
  differs "network" (built ~network:None ());
  differs "ports" (built ~ports:[ { M.host = 4001; container = 4002 } ] ());
  differs "port count" (built ~ports:[] ());
  differs "plain env value"
    (built
       ~env:
         [
           ("TRADING_MODE", M.Plain "live");
           ("TWS_USERID", M.Plain "someuser");
           ("TWS_PASSWORD", M.Secret "hunter2");
         ]
       ());
  differs "secret env value"
    (built
       ~env:
         [
           ("TRADING_MODE", M.Plain "paper");
           ("TWS_USERID", M.Plain "someuser");
           ("TWS_PASSWORD", M.Secret "rotated-secret");
         ]
       ());
  differs "plain vs secret classification"
    (built
       ~env:
         [
           ("TRADING_MODE", M.Plain "paper");
           ("TWS_USERID", M.Plain "someuser");
           ("TWS_PASSWORD", M.Plain "hunter2");
         ]
       ())

let test_spec_hash_resists_field_boundary_collision () =
  (* These two have equal field concatenations ("ab"+"c" = "a"+"bc"), so a
     digest over bare concatenated values would collide. It does not pin which
     of canonical_spec's three defences prevents it — the key prefix, the %S
     quoting and the newline terminator each suffice alone — only that the
     property holds. *)
  let a = built ~name:"ab" ~image:"c" () in
  let b = built ~name:"a" ~image:"bc" () in
  check bool "distinct specs with equal concatenations differ" false
    (String.equal (M.spec_hash a) (M.spec_hash b))

let test_spec_hash_stable_under_port_reordering () =
  let two_ports =
    built
      ~ports:
        [
          { M.host = 4001; container = 4001 };
          { M.host = 4002; container = 4002 };
        ]
      ()
  in
  let reordered =
    built
      ~ports:
        [
          { M.host = 4002; container = 4002 };
          { M.host = 4001; container = 4001 };
        ]
      ()
  in
  check string "reordering ports does not change the spec hash"
    (M.spec_hash two_ports) (M.spec_hash reordered)

let test_spec_hash_stable_under_env_reordering () =
  let reordered =
    built
      ~env:
        [
          ("TWS_PASSWORD", M.Secret "hunter2");
          ("TWS_USERID", M.Plain "someuser");
          ("TRADING_MODE", M.Plain "paper");
        ]
      ()
  in
  check string "reordering env does not change the spec hash" (M.spec_hash base)
    (M.spec_hash reordered)

(* --- labels --- *)

let test_labels_never_leak_secret_values () =
  let labels = M.labels base in
  check bool "no label value leaks the secret" false
    (List.exists (fun (_, v) -> contains ~needle:"hunter2" v) labels);
  check bool "no label key leaks the secret" false
    (List.exists (fun (k, _) -> contains ~needle:"hunter2" k) labels)

let test_labels_exclude_traefik () =
  check bool "managed container emits no traefik routing labels" false
    (has_traefik_label (M.labels base))

let test_traefik_label_detector_is_sound () =
  check bool "detector recognises a routed label set" true
    (has_traefik_label
       [
         ("traefik.enable", "true");
         ("traefik.http.routers.x.rule", "Host(`example.com`)");
         ("bondi.managed", "true");
       ])

let test_labels_identify_the_container_as_managed () =
  check
    (list (pair string string))
    "exact label set, fully enumerated"
    [
      ("bondi.managed", "true");
      ("bondi.type", "managed");
      ("bondi.name", "ib-gateway");
      ("bondi.spec-hash", M.spec_hash base);
    ]
    (M.labels base)

(* --- paths --- *)

let test_config_dir_and_env_file_path () =
  check string "config dir" "/etc/bondi/ib-gateway" (M.config_dir base);
  check string "env file path" "/etc/bondi/ib-gateway/env"
    (M.env_file_path base)

(* --- parsing declared strings --- *)

let test_restart_policy_of_string_maps_every_spelling () =
  (* Each spelling maps to its own policy: a transposed pair would silently
     give a container a restart behaviour nobody asked for. *)
  check bool "no" true (M.restart_policy_of_string "no" = Ok M.No);
  check bool "on-failure" true
    (M.restart_policy_of_string "on-failure" = Ok M.On_failure);
  check bool "always" true (M.restart_policy_of_string "always" = Ok M.Always);
  check bool "unless-stopped" true
    (M.restart_policy_of_string "unless-stopped" = Ok M.Unless_stopped)

let test_restart_policy_of_string_rejects_unknown () =
  rejects "unknown policy" (M.Invalid_restart_policy "sometimes")
    (M.restart_policy_of_string "sometimes");
  rejects "empty policy" (M.Invalid_restart_policy "")
    (M.restart_policy_of_string "");
  (* Docker's spelling, not a synonym of it. *)
  rejects "underscore variant" (M.Invalid_restart_policy "unless_stopped")
    (M.restart_policy_of_string "unless_stopped")

let test_ports_of_strings_preserves_order () =
  check bool "parsed in declared order" true
    (M.ports_of_strings [ "5900:5900"; "4001:4003" ]
    = Ok
        [
          { M.host = 5900; container = 5900 };
          { M.host = 4001; container = 4003 };
        ])

let test_ports_of_strings_rejects_malformed () =
  rejects "wrong separator" (M.Invalid_port "4001-4003")
    (M.ports_of_strings [ "4001-4003" ]);
  rejects "missing container side" (M.Invalid_port "4001:")
    (M.ports_of_strings [ "4001:" ]);
  rejects "non-numeric" (M.Invalid_port "http:web")
    (M.ports_of_strings [ "http:web" ]);
  rejects "three parts" (M.Invalid_port "1:2:3")
    (M.ports_of_strings [ "1:2:3" ]);
  rejects "bare number" (M.Invalid_port "4001") (M.ports_of_strings [ "4001" ])

let test_ports_of_strings_rejects_out_of_range () =
  rejects "zero host" (M.Invalid_port "0:80") (M.ports_of_strings [ "0:80" ]);
  rejects "container above range" (M.Invalid_port "80:65536")
    (M.ports_of_strings [ "80:65536" ]);
  rejects "negative" (M.Invalid_port "-1:80") (M.ports_of_strings [ "-1:80" ]);
  check bool "the range boundaries themselves are accepted" true
    (M.ports_of_strings [ "1:65535" ] = Ok [ { M.host = 1; container = 65535 } ])

let test_create_rejects_duplicate_env_key () =
  (* Which value wins would not be visible in bondi.yaml, and the loser may be
     a credential. *)
  rejects "same key plain and secret" (M.Duplicate_env_key "TWS_PASSWORD")
    (spec
       ~env:
         [
           ("TWS_PASSWORD", M.Plain "placeholder");
           ("TWS_PASSWORD", M.Secret "hunter2");
         ]
       ());
  rejects "same key twice plain" (M.Duplicate_env_key "TRADING_MODE")
    (spec
       ~env:
         [ ("TRADING_MODE", M.Plain "paper"); ("TRADING_MODE", M.Plain "live") ]
       ())

(* The secret env file is line-oriented (KEY=VALUE per line) and Docker's
   --env-file parser does no unquoting, so a newline in either half injects
   variables the operator never declared. The name is validated for the same
   class of reason; keys and values are the remaining unchecked inputs. *)
let test_create_rejects_env_keys_that_break_the_file_format () =
  rejects "newline in key" (M.Invalid_env_key "TWS\nEXTRA")
    (spec ~env:[ ("TWS\nEXTRA", M.Plain "paper") ] ());
  rejects "equals in key" (M.Invalid_env_key "TWS=USERID")
    (spec ~env:[ ("TWS=USERID", M.Plain "paper") ] ());
  rejects "carriage return in key" (M.Invalid_env_key "TWS\rID")
    (spec ~env:[ ("TWS\rID", M.Plain "paper") ] ());
  rejects "empty key" (M.Invalid_env_key "")
    (spec ~env:[ ("", M.Plain "x") ] ())

let test_create_rejects_env_values_that_break_the_file_format () =
  rejects "newline in plain value" (M.Invalid_env_value "TRADING_MODE")
    (spec ~env:[ ("TRADING_MODE", M.Plain "paper\nADMIN=1") ] ());
  rejects "newline in secret value" (M.Invalid_env_value "TWS_PASSWORD")
    (spec ~env:[ ("TWS_PASSWORD", M.Secret "hunter2\nADMIN=1") ] ());
  rejects "carriage return in value" (M.Invalid_env_value "TRADING_MODE")
    (spec ~env:[ ("TRADING_MODE", M.Plain "paper\r") ] ())

(* The rejected value may be the credential itself, so the message names the key
   and nothing else. *)
let test_invalid_env_value_message_never_quotes_the_value () =
  let message = M.error_to_string (M.Invalid_env_value "TWS_PASSWORD") in
  check bool "names the key" true (contains ~needle:"TWS_PASSWORD" message);
  match spec ~env:[ ("TWS_PASSWORD", M.Secret "hunter2\nADMIN=1") ] () with
  | Ok _ -> fail "expected the value to be rejected"
  | Error e ->
      check bool "does not quote the value" false
        (contains ~needle:"hunter2" (M.error_to_string e))

(* Affirmative arm: ordinary values keep working, including ones with the
   characters an over-eager check would reject. *)
let test_create_accepts_ordinary_env_values () =
  let t =
    built
      ~env:
        [
          ("TRADING_MODE", M.Plain "paper");
          ("URL", M.Plain "https://example.com/a?b=c&d=e");
          ("TWS_PASSWORD", M.Secret "p@ss w0rd!#$%");
        ]
      ()
  in
  check bool "secret file renders" true
    (match M.secret_env_file_contents t with
    | None -> false
    | Some contents -> contents = "TWS_PASSWORD=p@ss w0rd!#$%\n")

(* --- run_args --- *)

(* The fully-populated arm is pinned end to end by test/cram/setup_managed.t.
   What cram cannot cheaply cover is the shape of a spec that declares none of
   the optional groups, so each absent arm is owned here. *)
let test_run_args_omits_absent_options () =
  let args =
    M.run_args
      (built ~network:None ~ports:[]
         ~env:[ ("TRADING_MODE", M.Plain "paper") ]
         ())
  in
  let absent flag =
    check bool
      (flag ^ " is not emitted when nothing declares it")
      false (List.mem flag args)
  in
  absent "--network";
  absent "-p";
  absent "--env-file";
  (* Affirmative arm: the same builder with those groups declared emits all
     three, so the assertions above fail for the declaration and not because
     run_args stopped emitting flags altogether. *)
  let populated = M.run_args base in
  List.iter
    (fun flag ->
      check bool
        (flag ^ " is emitted when declared")
        true (List.mem flag populated))
    [ "--network"; "-p"; "--env-file" ]

let test_run_args_never_carries_a_secret_value () =
  (* FR-2: a credential reaching argv is visible in ps on the server. *)
  List.iter
    (fun arg ->
      check bool
        ("no argument carries the secret value: " ^ arg)
        false
        (contains ~needle:"hunter2" arg))
    (M.run_args base)

let test_run_args_ends_with_the_pinned_image () =
  (* Anything after the image is read by Docker as the container command, so
     the image must be last and must carry the tag. *)
  let args = M.run_args base in
  let last = List.nth args (List.length args - 1) in
  check string "image with pinned tag is the final argument"
    "gnzsnz/ib-gateway:10.48.1e" last

let () =
  run "Managed_container"
    [
      ( "create",
        [
          test_case "rejects path traversal names" `Quick
            test_create_rejects_path_traversal_names;
          test_case "rejects empty fields" `Quick
            test_create_rejects_empty_fields;
          test_case "accepts conventional names" `Quick
            test_create_accepts_conventional_names;
          test_case "rejects an unmanaged network" `Quick
            test_create_rejects_an_unmanaged_network;
          test_case "accepts the managed network and none" `Quick
            test_create_accepts_the_managed_network_and_none;
          test_case "unmanaged network message names both" `Quick
            test_unmanaged_network_message_names_both;
          test_case "accessors return declared values" `Quick
            test_accessors_return_declared_values;
          test_case "rejects duplicate env keys" `Quick
            test_create_rejects_duplicate_env_key;
          test_case "rejects env keys that break the file format" `Quick
            test_create_rejects_env_keys_that_break_the_file_format;
          test_case "rejects env values that break the file format" `Quick
            test_create_rejects_env_values_that_break_the_file_format;
          test_case "invalid env value message never quotes the value" `Quick
            test_invalid_env_value_message_never_quotes_the_value;
          test_case "accepts ordinary env values" `Quick
            test_create_accepts_ordinary_env_values;
        ] );
      ( "parsing",
        [
          test_case "restart policy maps every spelling" `Quick
            test_restart_policy_of_string_maps_every_spelling;
          test_case "restart policy rejects unknown" `Quick
            test_restart_policy_of_string_rejects_unknown;
          test_case "ports preserve declared order" `Quick
            test_ports_of_strings_preserves_order;
          test_case "ports reject malformed entries" `Quick
            test_ports_of_strings_rejects_malformed;
          test_case "ports reject out-of-range numbers" `Quick
            test_ports_of_strings_rejects_out_of_range;
        ] );
      ( "naming",
        [
          test_case "container name is bondi-prefixed" `Quick
            test_container_name_is_prefixed;
          test_case "config dir and env file path" `Quick
            test_config_dir_and_env_file_path;
        ] );
      ( "env",
        [
          test_case "env file contains only secrets" `Quick
            test_env_file_contains_only_secrets;
          test_case "every line is terminated" `Quick
            test_env_file_terminates_every_line;
          test_case "no env file when nothing is secret" `Quick
            test_secret_env_file_none_when_no_secrets;
          test_case "plain env excludes secrets" `Quick
            test_plain_env_excludes_secrets;
        ] );
      ( "spec_hash",
        [
          test_case "covers every field" `Quick
            test_spec_hash_covers_every_field;
          test_case "resists field boundary collision" `Quick
            test_spec_hash_resists_field_boundary_collision;
          test_case "stable under env reordering" `Quick
            test_spec_hash_stable_under_env_reordering;
          test_case "stable under port reordering" `Quick
            test_spec_hash_stable_under_port_reordering;
        ] );
      ( "labels",
        [
          test_case "no secret value reaches a label" `Quick
            test_labels_never_leak_secret_values;
          test_case "no traefik routing labels" `Quick
            test_labels_exclude_traefik;
          test_case "traefik detector is sound" `Quick
            test_traefik_label_detector_is_sound;
          test_case "labels identify the container as managed" `Quick
            test_labels_identify_the_container_as_managed;
        ] );
      ( "run_args",
        [
          test_case "omits absent options" `Quick
            test_run_args_omits_absent_options;
          test_case "never carries a secret value" `Quick
            test_run_args_never_carries_a_secret_value;
          test_case "ends with the pinned image" `Quick
            test_run_args_ends_with_the_pinned_image;
        ] );
    ]
