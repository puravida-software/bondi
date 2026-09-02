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
  let entries =
    [ ("ALPACA_SECRET_KEY", "abc/def+ghi="); ("RUN_ENV", "paper") ]
  in
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
    [ "levtra-paper"; "sotm"; "a"; "job.1"; "job_2" ];
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
          test_case "read absent" `Quick test_read_absent_is_empty;
        ] );
    ]
