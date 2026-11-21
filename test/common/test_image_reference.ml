open Alcotest
module Image_reference = Bondi_common.Image_reference

let pp_error ppf = function
  | Image_reference.Empty -> Format.fprintf ppf "Empty"
  | Image_reference.Malformed text -> Format.fprintf ppf "Malformed %S" text

let error = testable pp_error ( = )

(* A reference as the tuple of what its accessors read back, so that it can be
   compared without reaching into the abstract type: name, registry, tag,
   digest. *)
let fields reference =
  ( (Image_reference.name reference, Image_reference.registry reference),
    (Image_reference.tag reference, Image_reference.digest reference) )

let reference_fields =
  pair (pair string (option string)) (pair (option string) (option string))

let parsed text =
  match Image_reference.of_string text with
  | Ok reference -> reference
  | Error e ->
      fail (Format.asprintf "expected %S to parse, got %a" text pp_error e)

let refused text =
  match Image_reference.of_string text with
  | Ok reference ->
      fail
        (Printf.sprintf "expected %S to be refused, got %s" text
           (Image_reference.to_string reference))
  | Error e -> e

(* A digest the engine accepts: sha256 and exactly 64 lowercase hex digits. *)
let sha256 =
  "sha256:4bcff63911fcb4448bd4fdacec207030997caf25e9bea4045fa6c8c44de311d1"

(* Each expected split is written out by hand from the Docker Engine's reference
   grammar, not computed with the module under test. *)
let known_answers =
  [
    ( "registry:5000/app:1.2.3",
      (("registry:5000/app", Some "registry:5000"), (Some "1.2.3", None)) );
    ("old/worker@" ^ sha256, (("old/worker", None), (None, Some sha256)));
    ("name:tag", (("name", None), (Some "tag", None)));
    ("name", (("name", None), (None, None)));
    ("app:1.0@" ^ sha256, (("app", None), (Some "1.0", Some sha256)));
    ( "ghcr.io/org/team/app:v1",
      (("ghcr.io/org/team/app", Some "ghcr.io"), (Some "v1", None)) );
    ("localhost/app", (("localhost/app", Some "localhost"), (None, None)));
    (* With no [/], nothing can be a registry, so the [:5000] is a tag. *)
    ("localhost:5000", (("localhost", None), (Some "5000", None)));
    (* An uppercase first component is a registry, because a path cannot hold
       one. *)
    ("Registry/app", (("Registry/app", Some "Registry"), (None, None)));
    ( "[::1]:5000/app:1",
      (("[::1]:5000/app", Some "[::1]:5000"), (Some "1", None)) );
    ("a-b.c/d__e--f.g", (("a-b.c/d__e--f.g", Some "a-b.c"), (None, None)));
    ("a__b-c--d_e/f", (("a__b-c--d_e/f", None), (None, None)));
  ]

let test_image_reference_known_answers () =
  List.iter
    (fun (text, expected) ->
      let reference = parsed text in
      check reference_fields text expected (fields reference);
      check string (text ^ " prints back") text
        (Image_reference.to_string reference);
      match Image_reference.of_yojson (Image_reference.to_yojson reference) with
      | Ok decoded ->
          check reference_fields (text ^ " through JSON") expected
            (fields decoded)
      | Error message -> fail message)
    known_answers

(* The generators below build references from the grammar's parts, so every
   member is one the parser must accept. Degenerate members are weighted in:
   one-character components, the longest tag, a name of exactly 255
   characters, every separator, [localhost], bare and bracketed hosts. *)
module Gen = QCheck2.Gen

let lower_alnum = Gen.oneof [ Gen.char_range 'a' 'z'; Gen.char_range '0' '9' ]
let alnum_run = Gen.string_size ~gen:lower_alnum (Gen.int_range 1 4)

let word_char =
  Gen.oneof
    [
      Gen.char_range 'a' 'z';
      Gen.char_range 'A' 'Z';
      Gen.char_range '0' '9';
      Gen.return '_';
    ]

(* A path component: alphanumeric runs joined by separators. The first
   component of a reference with no registry must not hold a [.], or it would
   be read as a registry, so its separators leave [.] out. *)
let path_component ~dot =
  let separators = [ "_"; "__"; "-"; "--"; "---" ] in
  let separators = if dot then "." :: separators else separators in
  let open Gen in
  let* first = alnum_run in
  let+ rest =
    list_size (int_range 0 2)
      (let+ separator = oneof_list separators and+ run = alnum_run in
       separator ^ run)
  in
  String.concat "" (first :: rest)

let path ~registry =
  let open Gen in
  let* first = path_component ~dot:registry in
  let+ rest = list_size (int_range 0 2) (path_component ~dot:true) in
  String.concat "/" (first :: rest)

let domain_component =
  let open Gen in
  let alnum =
    oneof [ char_range 'a' 'z'; char_range 'A' 'Z'; char_range '0' '9' ]
  in
  oneof
    [
      string_size ~gen:alnum (return 1);
      (let+ first = alnum
       and+ middle =
         string_size ~gen:(oneof [ alnum; return '-' ]) (int_range 0 3)
       and+ last = alnum in
       String.make 1 first ^ middle ^ String.make 1 last);
    ]

let port = Gen.map string_of_int (Gen.int_range 0 65535)

(* Every member is a registry by the engine's test: it holds a [.] or a [:], or
   is [localhost]. *)
let registry =
  let open Gen in
  let dotted =
    let+ first = domain_component
    and+ rest = list_size (int_range 1 2) domain_component in
    String.concat "." (first :: rest)
  in
  oneof
    [
      return "localhost";
      map (fun p -> "localhost:" ^ p) port;
      dotted;
      (let+ host = dotted and+ p = port in
       host ^ ":" ^ p);
      (let+ host = domain_component and+ p = port in
       host ^ ":" ^ p);
      map (fun p -> "[::1]:" ^ p) port;
      return "[fe80::1]";
    ]

let tag =
  let open Gen in
  let rest_char = oneof [ word_char; return '.'; return '-' ] in
  let* first = word_char in
  let+ rest =
    oneof
      [
        string_size ~gen:rest_char (int_range 0 8);
        string_size ~gen:rest_char (return 127);
      ]
  in
  String.make 1 first ^ rest

let digest =
  let open Gen in
  let hex = oneof [ char_range '0' '9'; char_range 'a' 'f' ] in
  oneof
    [
      map (fun h -> "sha256:" ^ h) (string_size ~gen:hex (return 64));
      map (fun h -> "sha384:" ^ h) (string_size ~gen:hex (return 96));
      map (fun h -> "sha512:" ^ h) (string_size ~gen:hex (return 128));
    ]

let name =
  let open Gen in
  let ordinary =
    oneof
      [
        path ~registry:false;
        (let+ r = registry and+ p = path ~registry:true in
         r ^ "/" ^ p);
      ]
  in
  (* The longest name the grammar admits: 255 characters, registry included. *)
  let longest = return ("r.io/" ^ String.make 250 'a') in
  let+ candidate = oneof_weighted [ (20, ordinary); (1, longest) ] in
  if String.length candidate > 255 then
    failwith
      "generator: unreachable — every part is bounded far below the \
       255-character name limit, so a longer name means the generator is wrong"
  else candidate

let reference =
  let open Gen in
  let* n = name in
  oneof
    [
      return n;
      map (fun t -> n ^ ":" ^ t) tag;
      map (fun d -> n ^ "@" ^ d) digest;
      (let+ t = tag and+ d = digest in
       n ^ ":" ^ t ^ "@" ^ d);
    ]

(* This property parses and prints with the module under test, so it proves
   only that the two agree. A parser that splits a reference wrongly but
   consistently, putting the tag in the name for instance, still prints the
   text back. The known-answer test is the guard against that. A refusal here
   is the parser rejecting a reference the grammar admits, which is a contract
   violation, so it is a failed property rather than an exception. *)
let test_image_reference_round_trip =
  QCheck_alcotest.to_alcotest ~speed_level:`Quick
    (QCheck2.Test.make ~count:2000 ~name:"parse then print is the identity"
       ~print:Fun.id reference (fun text ->
         match Image_reference.of_string text with
         | Ok parsed -> String.equal (Image_reference.to_string parsed) text
         | Error _ -> false))

let refusals =
  [
    (* a trailing [:] *)
    "app:";
    (* a [:] after the [@]: a tag written after the digest *)
    "app@" ^ sha256 ^ ":1.0";
    (* an uppercase repository *)
    "App";
    "registry:5000/App:1.0";
    "org/App";
    (* malformed digests *)
    "app@";
    "app@sha256:abc";
    "app@sha256:" ^ String.uppercase_ascii (String.make 64 'a');
    "app@md5:" ^ String.make 32 'a';
    "app@sha256:" ^ String.make 63 'a';
    "app@sha256:" ^ String.make 65 'a';
    (* malformed names and tags *)
    " app";
    "app ";
    "/app";
    "app/";
    "a//b";
    "a..b";
    "a___b";
    "-app";
    "app:-1";
    "app:" ^ String.make 129 'a';
    "app:1.0:2.0";
    "app/bad_.x";
    "bad_host.io/app";
    "r.io/" ^ String.make 251 'a';
  ]

let test_image_reference_refuses () =
  check error "the empty string" Image_reference.Empty (refused "");
  List.iter
    (fun text ->
      check error text (Image_reference.Malformed text) (refused text))
    refusals;
  let contains = Bondi_common.String_utils.contains in
  (match Image_reference.of_yojson (`String "App") with
  | Ok _ -> fail "a JSON string holding App decoded"
  | Error message ->
      check bool
        ("the message names App: " ^ message)
        true
        (contains ~needle:"App" message));
  match Image_reference.of_yojson (`Int 42) with
  | Ok _ -> fail "a JSON number decoded as a reference"
  | Error message ->
      check bool
        ("the message carries the JSON: " ^ message)
        true
        (contains ~needle:"42" message)

let test_of_name_and_tag () =
  (match
     Image_reference.of_name_and_tag ~name:"registry:5000/app" ~tag:"1.2.3"
   with
  | Ok reference ->
      check reference_fields "composed"
        (("registry:5000/app", Some "registry:5000"), (Some "1.2.3", None))
        (fields reference)
  | Error e -> fail (Format.asprintf "refused: %a" pp_error e));
  List.iter
    (fun (name, tag, composed) ->
      match Image_reference.of_name_and_tag ~name ~tag with
      | Ok reference ->
          fail
            (Printf.sprintf "expected %S + %S to be refused, got %s" name tag
               (Image_reference.to_string reference))
      | Error e ->
          check error
            (name ^ " + " ^ tag)
            (Image_reference.Malformed composed) e)
    [
      (* the name already has a tag *)
      ("app:1.0", "2.0", "app:1.0:2.0");
      (* the name already has a digest *)
      ("app@" ^ sha256, "1.0", "app@" ^ sha256 ^ ":1.0");
      (* the tag would smuggle in a digest *)
      ("app", "1.0@" ^ sha256, "app:1.0@" ^ sha256);
      (* an empty tag *)
      ("app", "", "app:");
      (* a host and port with no path is not a name *)
      ("localhost:5000", "1", "localhost:5000:1");
      ("App", "1", "App:1");
    ]

let test_pull_tag () =
  List.iter
    (fun (text, expected) ->
      check string text expected (Image_reference.pull_tag (parsed text)))
    [
      ("traefik", "latest");
      ("registry:5000/app", "latest");
      ("app:1.0", "1.0");
      ("old/worker@" ^ sha256, sha256);
      (* The container is created from the reference as written, and the engine
         resolves one that carries a digest by its digest, so the pull must
         fetch that digest and not whatever the tag points at now. *)
      ("app:1.0@" ^ sha256, sha256);
    ]

(* The two columns a status listing shows. Both the host's listing, read by the
   client, and the orchestrator's status, written by the server, split through
   this, so that one container is never reported as two. A digest is reported
   whole with no tag: it names no tag, and a tag beside it is not the image the
   container was created from. *)
let test_image_and_tag () =
  List.iter
    (fun (text, expected) ->
      check (pair string string) text expected
        (Image_reference.image_and_tag (parsed text)))
    [
      ("traefik", ("traefik", ""));
      ("app:1.0", ("app", "1.0"));
      ("registry:5000/app:1.2.3", ("registry:5000/app", "1.2.3"));
      ("old/worker@" ^ sha256, ("old/worker@" ^ sha256, ""));
      ( "registry:5000/app:1.2.3@" ^ sha256,
        ("registry:5000/app:1.2.3@" ^ sha256, "") );
    ]

let () =
  run "Image_reference"
    [
      ( "Image_reference",
        [
          test_case "known answers" `Quick test_image_reference_known_answers;
          test_image_reference_round_trip;
          test_case "refuses" `Quick test_image_reference_refuses;
          test_case "of_name_and_tag" `Quick test_of_name_and_tag;
          test_case "pull_tag" `Quick test_pull_tag;
          test_case "image_and_tag" `Quick test_image_and_tag;
        ] );
    ]
