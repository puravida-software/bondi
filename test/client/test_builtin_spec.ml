open Alcotest
module Builtin_spec = Bondi_client.Builtin_spec

(* Two inputs that differ only where the case under test says they do. Each
   case builds both sides from these, so the difference asserted is the one the
   case names and no other. *)
let river = "logging {\n  level = \"info\"\n}\n"
let env = "GRAFANA_CLOUD_INSTANCE_ID=123456\nGRAFANA_CLOUD_API_KEY=glc_one\n"

let run_command =
  "docker run -d --name bondi-alloy -v /etc/bondi/alloy/config.alloy:ro \
   'grafana/alloy:v1.8.0'"

(* Every field of the run command is a field of the container: the image, a
   mount, the user it runs as. Each is changed on its own, so a digest that read
   only a prefix of the command, or only the image, fails on the arm it skips. *)
let test_hash_changes_with_run_command () =
  let base = Builtin_spec.hash ~run_command ~files:[ river; env ] in
  let differs name other =
    check bool name false
      (String.equal base
         (Builtin_spec.hash ~run_command:other ~files:[ river; env ]))
  in
  differs "a different image"
    "docker run -d --name bondi-alloy -v /etc/bondi/alloy/config.alloy:ro \
     'grafana/alloy:v1.9.2'";
  differs "a different mount"
    "docker run -d --name bondi-alloy -v /etc/bondi/alloy/other.alloy:ro \
     'grafana/alloy:v1.8.0'";
  differs "an added flag"
    "docker run -d --name bondi-alloy --user root -v \
     /etc/bondi/alloy/config.alloy:ro 'grafana/alloy:v1.8.0'"

(* The sidecar reads two files at start, and neither is on its command line: a
   rewritten River configuration or a rotated credential is a change that only
   the files show. *)
let test_hash_changes_with_each_file () =
  let base = Builtin_spec.hash ~run_command ~files:[ river; env ] in
  let differs name files =
    check bool name false
      (String.equal base (Builtin_spec.hash ~run_command ~files))
  in
  differs "a changed River configuration"
    [ "logging {\n  level = \"debug\"\n}\n"; env ];
  differs "a rotated credential"
    [
      river; "GRAFANA_CLOUD_INSTANCE_ID=123456\nGRAFANA_CLOUD_API_KEY=glc_two\n";
    ];
  differs "the two files swapped" [ env; river ];
  differs "a file missing" [ river ];
  differs "an empty file added" [ river; env; "" ];
  (* The boundaries. Each pair below concatenates to the same bytes, so a digest
     over the inputs run together reads them as one container. *)
  check bool "text moved from one file to the next" false
    (String.equal
       (Builtin_spec.hash ~run_command ~files:[ "ab"; "c" ])
       (Builtin_spec.hash ~run_command ~files:[ "a"; "bc" ]));
  check bool "text moved from the command into the first file" false
    (String.equal
       (Builtin_spec.hash ~run_command:"docker run x" ~files:[ "y" ])
       (Builtin_spec.hash ~run_command:"docker run " ~files:[ "xy" ]));
  check bool "a separator inside a file cannot forge a boundary" false
    (String.equal
       (Builtin_spec.hash ~run_command ~files:[ "a\"\nfile=\"b" ])
       (Builtin_spec.hash ~run_command ~files:[ "a"; "b" ]))

(* The digest is compared against one stamped by an earlier run of setup, from
   a value built again from bondi.yaml. Both sides are built here separately, so
   they are equal without being the same string: a digest that read identity, or
   anything that differs run to run, fails here and recreates an unchanged
   container on every setup. *)
let test_hash_stable_for_equal_inputs () =
  let first =
    Builtin_spec.hash
      ~run_command:(String.concat " " [ "docker"; "run"; "-d" ])
      ~files:[ String.concat "" [ "level"; "=info" ]; "KEY=one" ]
  in
  let second =
    Builtin_spec.hash
      ~run_command:(Bytes.to_string (Bytes.of_string "docker run -d"))
      ~files:[ "level=info"; Bytes.to_string (Bytes.of_string "KEY=one") ]
  in
  check string "equal inputs give equal digests" first second;
  (* The affirmative arm: two empty strings are equal too. The digest is what a
     Docker label carries, so it is non-empty hex and nothing a shell reads. *)
  check bool "the digest is lowercase hex" true
    (String.length first = 32
    && String.for_all
         (fun c -> (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))
         first)

let test_matches_only_the_recorded_digest () =
  let expected = Builtin_spec.hash ~run_command ~files:[ river ] in
  check bool "the same digest" true
    (Builtin_spec.matches ~expected (Some expected));
  check bool "another digest" false
    (Builtin_spec.matches ~expected (Some (expected ^ "0")));
  check bool "no digest recorded" false (Builtin_spec.matches ~expected None)

let test_label_flag_carries_the_label () =
  check string "the flag"
    (Printf.sprintf " --label %s=abc123" Builtin_spec.label)
    (Builtin_spec.label_flag "abc123")

let () =
  run "Builtin_spec"
    [
      ( "hash",
        [
          test_case "changes with the run command" `Quick
            test_hash_changes_with_run_command;
          test_case "changes with each file" `Quick
            test_hash_changes_with_each_file;
          test_case "stable for equal inputs" `Quick
            test_hash_stable_for_equal_inputs;
        ] );
      ( "stamp",
        [
          test_case "matches only the recorded digest" `Quick
            test_matches_only_the_recorded_digest;
          test_case "label flag carries the label" `Quick
            test_label_flag_carries_the_label;
        ] );
    ]
