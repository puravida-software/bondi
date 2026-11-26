open Alcotest
module Env_entry = Bondi_common.Env_entry

(* The error printed with every field it carries, so a value that reached the
   error would show up here. *)
let pp_error ppf = function
  | Env_entry.Invalid_key key -> Format.fprintf ppf "Invalid_key %S" key
  | Env_entry.Invalid_value { key } ->
      Format.fprintf ppf "Invalid_value { key = %S }" key

let error_equal a b =
  match (a, b) with
  | Env_entry.Invalid_key a, Env_entry.Invalid_key b -> String.equal a b
  | Env_entry.Invalid_value { key = a }, Env_entry.Invalid_value { key = b } ->
      String.equal a b
  | Env_entry.Invalid_key _, Env_entry.Invalid_value _
  | Env_entry.Invalid_value _, Env_entry.Invalid_key _ ->
      false

let error = testable pp_error error_equal
let outcome = result unit error

(* A line-oriented env file reads "a\nB=c" as the value "a" and a second
   variable B the operator never declared. *)
let test_refuses_probe_value () =
  check outcome "a newline in the value is refused, naming the key"
    (Error (Env_entry.Invalid_value { key = "K" }))
    (Env_entry.check ~key:"K" ~value:"a\nB=c")

let test_refuses_keys () =
  check outcome "an empty key is refused" (Error (Env_entry.Invalid_key ""))
    (Env_entry.check ~key:"" ~value:"x");
  check outcome "a key holding = is refused"
    (Error (Env_entry.Invalid_key "DB=URL"))
    (Env_entry.check ~key:"DB=URL" ~value:"x");
  check outcome "a key holding a tab is refused"
    (Error (Env_entry.Invalid_key "DB\tURL"))
    (Env_entry.check ~key:"DB\tURL" ~value:"x")

(* Affirmative arm: a credential URL holds =, &, ?, @ and :, each of which an
   over-eager check would refuse. *)
let test_accepts_ordinary_entry () =
  check outcome "an ordinary entry is accepted" (Ok ())
    (Env_entry.check ~key:"DB_URL"
       ~value:"postgres://u:p@h/db?sslmode=require&x=1")

module Gen = QCheck2.Gen

(* A key the rule accepts: 1-16 bytes over 0x20-0xFF, without = or DEL. *)
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

let control_character =
  Gen.oneof [ Gen.map Char.chr (Gen.int_range 0x00 0x1F); Gen.return '\x7F' ]

(* A printable value, possibly empty, with one control byte inserted anywhere
   in it, its first and last positions included. *)
let value_with_control_character =
  let open Gen in
  let* text =
    string_size ~gen:(map Char.chr (int_range 0x20 0x7E)) (int_range 0 32)
  in
  let* at = int_range 0 (String.length text) in
  let+ c = control_character in
  String.sub text 0 at
  ^ String.make 1 c
  ^ String.sub text at (String.length text - at)

let contains ~needle hay = Bondi_common.String_utils.contains ~needle hay

(* The exact equality is what proves the value stays out: the error is the key
   and nothing else. The printed form is checked as the caller would see it. *)
let prop_control_character_in_value_refused =
  QCheck_alcotest.to_alcotest ~speed_level:`Quick
    (QCheck2.Test.make ~count:2000
       ~name:"a value holding a control character is refused"
       ~print:(fun (k, v) -> Printf.sprintf "(%S, %S)" k v)
       (Gen.pair key value_with_control_character)
       (fun (key, value) ->
         match Env_entry.check ~key ~value with
         | Ok () -> false
         | Error e ->
             error_equal e (Env_entry.Invalid_value { key })
             && not (contains ~needle:value (Format.asprintf "%a" pp_error e))))

let test_job_refusal () =
  check (option string) "clean entries, no refusal" None
    (Env_entry.job_refusal [ ("nightly", [ ("A", "b=c") ]); ("other", []) ]);
  check (option string) "offenders named by job and key, never the value"
    (Some
       "cron job secret entries cannot be written to an env file (job \
        \"nightly\" has an invalid key \"A=B\"; job \"other\" has a control \
        character in the value of \"K\"). A key must be non-empty and hold no \
        \"=\" and no control character, and a value must hold no control \
        character, newline included: fix these entries in bondi.yaml")
    (Env_entry.job_refusal
       [
         ("nightly", [ ("OK", "v"); ("A=B", "v") ]);
         ("other", [ ("K", "sk-live\nX=1") ]);
       ])

let () =
  run "Env_entry"
    [
      ( "Env_entry",
        [
          test_case "job refusal" `Quick test_job_refusal;
          test_case "refuses probe value" `Quick test_refuses_probe_value;
          test_case "refuses keys" `Quick test_refuses_keys;
          test_case "accepts ordinary entry" `Quick test_accepts_ordinary_entry;
          prop_control_character_in_value_refused;
        ] );
    ]
