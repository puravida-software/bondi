open Alcotest
module Cron_secrets = Bondi_server.Cron_secrets

let pairs =
  testable
    (fun ppf l ->
      Format.fprintf ppf "%s"
        (String.concat "," (List.map (fun (k, v) -> k ^ "=" ^ v) l)))
    ( = )

let test_file_contents () =
  check string "one KEY=value per line, newline terminated" "A=1\nB=two\n"
    (Cron_secrets.file_contents [ ("A", "1"); ("B", "two") ]);
  check string "no secrets means an empty file, not an absent one" ""
    (Cron_secrets.file_contents [])

let test_roundtrip () =
  let entries = [ ("API_SECRET_KEY", "abc/def+ghi="); ("RUN_ENV", "paper") ] in
  check pairs "survives a round trip" entries
    (Cron_secrets.parse_file (Cron_secrets.file_contents entries))

(* A base64 secret ends in '=' and many tokens contain them. Splitting on every
   '=' would silently truncate the credential to its first segment, and the job
   would fail authenticating with no indication why. *)
let test_value_may_contain_equals () =
  check pairs "only the first = separates"
    [ ("K", "a=b=c") ]
    (Cron_secrets.parse_file "K=a=b=c\n")

let test_parse_skips_junk () =
  check pairs "blank and malformed lines are skipped"
    [ ("A", "1") ]
    (Cron_secrets.parse_file "\nnot-a-pair\nA=1\n\n=novalue\n")

module Env_entry = Bondi_common.Env_entry

(* Known answers written out by hand, not derived from the writer or the reader:
   the round-trip property below runs both halves of the production pair, so a
   writer and reader that agreed on a wrong format would pass it. These pin the
   format itself. *)
let test_file_contents_known_answer () =
  check string "the value is written as is, = and space included" "K=a=b c\n"
    (Cron_secrets.file_contents [ ("K", "a=b c") ])

let test_parse_empty_value () =
  check pairs "an empty value is an entry, not a skipped line"
    [ ("K", "") ]
    (Cron_secrets.parse_file "K=\n")

(* The reader does no unquoting, so a newline in a value is a second record
   once written: this entry would come back as two, the second one a key the
   operator never declared. That is why the entry rule refuses it before
   anything is written, and both halves are pinned here so that relaxing the
   rule shows up beside the reason it exists. *)
let test_probe_entry_is_refused_before_write () =
  (match Env_entry.check ~key:"K" ~value:"a\nB=c" with
  | Ok () -> fail "a value holding a newline must be refused"
  | Error (Env_entry.Invalid_value { key }) ->
      check string "refused under its own key" "K" key
  | Error (Env_entry.Invalid_key key) ->
      failf "the key is valid; refused as a key instead: %S" key);
  check pairs "written anyway, it reads back as two entries"
    [ ("K", "a"); ("B", "c") ]
    (Cron_secrets.parse_file (Cron_secrets.file_contents [ ("K", "a\nB=c") ]))

module Gen = QCheck2.Gen

(* A key the entry rule accepts: 1-16 bytes over 0x20-0xFF, without = or DEL.
   Spaces, quotes and # are in range, so a key is not assumed to look like a
   shell identifier. *)
let key =
  let byte =
    Gen.oneof
      [
        Gen.map Char.chr (Gen.int_range 0x20 0x3C);
        Gen.map Char.chr (Gen.int_range 0x3E 0x7E);
        Gen.map Char.chr (Gen.int_range 0x80 0xFF);
      ]
  in
  Gen.string_size ~gen:byte (Gen.int_range 1 16)

(* A value the entry rule accepts: 0-64 bytes over 0x20-0xFF without DEL. The
   bytes a reader might treat specially -- =, #, both quotes, space -- are drawn
   far more often than chance would give them, and the empty value is drawn on
   its own, so neither is left to luck. *)
let value =
  let byte =
    Gen.oneof_weighted
      [
        (2, Gen.oneof_list [ '='; '#'; '"'; '\''; ' ' ]);
        (3, Gen.map Char.chr (Gen.int_range 0x20 0x7E));
        (1, Gen.map Char.chr (Gen.int_range 0x80 0xFF));
      ]
  in
  Gen.oneof_weighted
    [ (1, Gen.return ""); (9, Gen.string_size ~gen:byte (Gen.int_range 0 64)) ]

(* 0-20 entries, duplicate keys allowed: the file keeps every line in order and
   the reader keeps every line in order, so a duplicate is not collapsed here. *)
let entries =
  Gen.list_size (Gen.int_range 0 20)
    (Gen.oneof
       [
         Gen.pair key value;
         (* A key drawn from a small pool, so that duplicates actually occur. *)
         Gen.pair (Gen.oneof_list [ "K"; "TOKEN"; "#K" ]) value;
       ])

let print_entries xs =
  "["
  ^ String.concat "; "
      (List.map (fun (k, v) -> Printf.sprintf "(%S, %S)" k v) xs)
  ^ "]"

(* Every entry the rule accepts reads back exactly as written. The first
   conjunct keeps the generator honest: an entry it produced that the rule
   refuses would be outside the domain this property claims. The property
   writes and reads with the production pair, so it proves the two agree, not
   that the format is the one documented; the known answers above pin that. *)
let prop_file_round_trips_accepted_entries =
  QCheck_alcotest.to_alcotest ~speed_level:`Quick
    (QCheck2.Test.make ~count:2000
       ~name:"every accepted entry list reads back as written"
       ~print:print_entries entries (fun xs ->
         List.for_all
           (fun (key, value) ->
             match Env_entry.check ~key ~value with
             | Ok () -> true
             | Error (Env_entry.Invalid_key _ | Env_entry.Invalid_value _) ->
                 false)
           xs
         && Cron_secrets.parse_file (Cron_secrets.file_contents xs) = xs))

let test_merge_secret_wins () =
  check (list string) "secret overrides a same-named plain value"
    [ "RUN_ENV=paper"; "TOKEN=real" ]
    (Cron_secrets.merge
       ~plain:[ ("RUN_ENV", "paper"); ("TOKEN", "placeholder") ]
       ~secret:[ ("TOKEN", "real") ])

let test_merge_empty () =
  check (list string) "no secrets leaves plain untouched" [ "A=1" ]
    (Cron_secrets.merge ~plain:[ ("A", "1") ] ~secret:[])

(* The job name arrives in a deploy payload from the network and is placed into
   a path that is written to. A name that escapes its directory must not be
   representable at all. *)
let test_name_validation () =
  List.iter
    (fun n -> check bool n true (Cron_secrets.is_valid_name n))
    [ "canary-paper"; "sotm"; "a"; "job.1"; "job_2" ];
  List.iter
    (fun n -> check bool n false (Cron_secrets.is_valid_name n))
    [ ""; "../etc/passwd"; "a/b"; ".hidden"; "-leading"; "has space"; "a\nb" ]

let test_path_shape () =
  check string "dir" "/etc/bondi/cron/sotm" (Cron_secrets.dir_of "sotm");
  check string "file" "/etc/bondi/cron/sotm/env"
    (Cron_secrets.env_file_of "sotm")

let test_write_refuses_unsafe_name () =
  match
    Cron_secrets.write_env_file ~name:"../../etc/cron.d/evil" [ ("A", "1") ]
  with
  | Ok () -> fail "a traversing name must be refused before any write"
  | Error msg ->
      check bool "explains itself" true
        (Bondi_common.String_utils.contains ~needle:"unsafe" msg)

(* The run payload's file is the job definition the crontab line points at. *)
let test_run_file_path_shape () =
  check string "run file" "/etc/bondi/cron/sotm/run.json"
    (Cron_secrets.run_file_of "sotm")

(* The two files are the job's whole on-disk definition and are written by the
   same deploy step. A run file that landed anywhere but beside the env file
   would be written in one place and looked for in another when cron fired. *)
let test_run_file_is_env_sibling () =
  let env = Cron_secrets.env_file_of "canary-paper" in
  let run = Cron_secrets.run_file_of "canary-paper" in
  check string "same directory" (Filename.dirname env) (Filename.dirname run);
  check bool "and not the same file" true (env <> run)

(* The name check runs before any I/O, which is why the rejection arm needs no
   filesystem. The second assertion is the one that matters for a secret: the
   error names a path and never the payload, because this text is returned to
   whoever ran the subcommand and mailed by cron, and the payload is what the
   file exists to hide. *)
let test_write_run_file_refuses_unsafe_name () =
  match
    Cron_secrets.write_run_file ~name:"../../etc/cron.d/evil"
      (`Assoc [ ("image", `String "ghcr.io/acme/job:sha-deadbeef") ])
  with
  | Ok () -> fail "a traversing name must be refused before any write"
  | Error msg ->
      check bool "explains itself" true
        (Bondi_common.String_utils.contains ~needle:"unsafe" msg);
      check bool "carries no payload" false
        (Bondi_common.String_utils.contains ~needle:"deadbeef" msg)

let test_read_absent_is_empty () =
  check pairs "an absent file is not an error" []
    (Cron_secrets.read_env_file "definitely-not-a-real-job-xyz")

let () =
  run "cron_secrets"
    [
      ( "file format",
        [
          test_case "contents" `Quick test_file_contents;
          test_case "round trip" `Quick test_roundtrip;
          test_case "value may contain =" `Quick test_value_may_contain_equals;
          test_case "skips junk" `Quick test_parse_skips_junk;
          test_case "contents, known answer" `Quick
            test_file_contents_known_answer;
          test_case "an empty value is kept" `Quick test_parse_empty_value;
          test_case "a newline entry is refused before it is written" `Quick
            test_probe_entry_is_refused_before_write;
          prop_file_round_trips_accepted_entries;
        ] );
      ( "merge",
        [
          test_case "secret wins" `Quick test_merge_secret_wins;
          test_case "no secrets" `Quick test_merge_empty;
        ] );
      ( "paths",
        [
          test_case "name validation" `Quick test_name_validation;
          test_case "path shape" `Quick test_path_shape;
          test_case "write refuses unsafe name" `Quick
            test_write_refuses_unsafe_name;
          test_case "run file sits in the job's directory" `Quick
            test_run_file_path_shape;
          test_case "run file and env file are siblings" `Quick
            test_run_file_is_env_sibling;
          test_case "write refuses an unsafe name for the run file" `Quick
            test_write_run_file_refuses_unsafe_name;
          test_case "read absent" `Quick test_read_absent_is_empty;
        ] );
    ]
