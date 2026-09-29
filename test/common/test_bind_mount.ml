open Alcotest
module Bind_mount = Bondi_common.Bind_mount
module String_utils = Bondi_common.String_utils

let role_to_string = function
  | Bind_mount.Host -> "Host"
  | Bind_mount.Container -> "Container"

let pp_error ppf = function
  | Bind_mount.Not_absolute { role; path } ->
      Format.fprintf ppf "Not_absolute (%s, %S)" (role_to_string role) path
  | Bind_mount.Not_normalised { role; path } ->
      Format.fprintf ppf "Not_normalised (%s, %S)" (role_to_string role) path
  | Bind_mount.Control_character { role; path } ->
      Format.fprintf ppf "Control_character (%s, %S)" (role_to_string role) path
  | Bind_mount.Container_root -> Format.fprintf ppf "Container_root"
  | Bind_mount.Duplicate_container_path path ->
      Format.fprintf ppf "Duplicate_container_path %S" path

let error = testable pp_error ( = )

(* A mount as the tuple of what its accessors read back, so that two mounts can
   be compared without reaching into the abstract type. *)
let fields = Test_helpers.mount_fields
let mount_fields = triple string string bool

let refused ~host ~container =
  match Bind_mount.create ~host ~container ~read_only:false with
  | Ok mount ->
      fail
        (Printf.sprintf "expected %S -> %S to be refused, got %s -> %s" host
           container (Bind_mount.host mount)
           (Bind_mount.container mount))
  | Error e -> e

let accepted ~host ~container ~read_only =
  match Bind_mount.create ~host ~container ~read_only with
  | Ok mount -> mount
  | Error e ->
      fail
        (Printf.sprintf "expected %S -> %S to be accepted: %s" host container
           (Bind_mount.error_to_string e))

let names ~needle message =
  check bool
    (Printf.sprintf "%S names %S" message needle)
    true
    (String_utils.contains ~needle message)

let entry ~host ~container ~read_only =
  `Assoc
    [
      ("host", `String host);
      ("container", `String container);
      ("read_only", `Bool read_only);
    ]

let list_refused json =
  match Bind_mount.list_of_yojson json with
  | Ok mounts ->
      fail
        (Printf.sprintf "expected the list to be refused, got %d mount(s)"
           (List.length mounts))
  | Error message -> message

(* --- create --- *)

let test_accepts_absolute_paths_and_reads_them_back () =
  let mount =
    accepted ~host:"/srv/comalito/invoices" ~container:"/app/invoices"
      ~read_only:false
  in
  check mount_fields "a writable mount reads back as declared"
    ("/srv/comalito/invoices", "/app/invoices", false)
    (fields mount);
  let mount = accepted ~host:"/" ~container:"/host" ~read_only:true in
  check mount_fields "the host root is a normalised host path"
    ("/", "/host", true) (fields mount);
  (* A segment that merely starts with a dot is a name, not a "." or "..". *)
  let mount =
    accepted ~host:"/srv/.hidden" ~container:"/data/..cache" ~read_only:false
  in
  check mount_fields "dot-prefixed names are ordinary segments"
    ("/srv/.hidden", "/data/..cache", false)
    (fields mount);
  let mount = accepted ~host:"/srv/a:b" ~container:"/c:d" ~read_only:true in
  check mount_fields "a colon is part of the path, not a separator"
    ("/srv/a:b", "/c:d", true) (fields mount)

let test_refuses_relative_host_path_naming_it () =
  let e = refused ~host:"srv/comalito/invoices" ~container:"/app/invoices" in
  check error "a relative host path is not absolute"
    (Bind_mount.Not_absolute
       { role = Bind_mount.Host; path = "srv/comalito/invoices" })
    e;
  check string "the message names the host path"
    {|volume host path "srv/comalito/invoices" is not absolute: it must start with /|}
    (Bind_mount.error_to_string e);
  check error "an empty host path is not absolute"
    (Bind_mount.Not_absolute { role = Bind_mount.Host; path = "" })
    (refused ~host:"" ~container:"/app");
  check (result reject string) "the list codec refuses it with the same message"
    (Error (Bind_mount.error_to_string e))
    (Result.map (List.map fields)
       (Bind_mount.list_of_yojson
          (`List
             [
               entry ~host:"srv/comalito/invoices" ~container:"/app/invoices"
                 ~read_only:false;
             ])))

let test_refuses_relative_container_path_naming_it () =
  let e = refused ~host:"/srv/data" ~container:"app/data" in
  check error "a relative container path is not absolute"
    (Bind_mount.Not_absolute { role = Bind_mount.Container; path = "app/data" })
    e;
  let message = Bind_mount.error_to_string e in
  names ~needle:"app/data" message;
  names ~needle:"container" message

let test_refuses_dot_and_dotdot_segments () =
  List.iter
    (fun (host, container, role, path) ->
      let e = refused ~host ~container in
      check error
        (Printf.sprintf "%S is not normalised" path)
        (Bind_mount.Not_normalised { role; path })
        e;
      names ~needle:path (Bind_mount.error_to_string e))
    [
      ("/srv/./data", "/data", Bind_mount.Host, "/srv/./data");
      ("/srv/../etc", "/data", Bind_mount.Host, "/srv/../etc");
      ("/srv/.", "/data", Bind_mount.Host, "/srv/.");
      ("/..", "/data", Bind_mount.Host, "/..");
      ("/srv", "/app/./data", Bind_mount.Container, "/app/./data");
      ("/srv", "/app/../etc", Bind_mount.Container, "/app/../etc");
      ("/srv", "/app/..", Bind_mount.Container, "/app/..");
    ]

let test_refuses_double_slash_and_trailing_slash () =
  List.iter
    (fun (host, container, role, path) ->
      let e = refused ~host ~container in
      check error
        (Printf.sprintf "%S is not normalised" path)
        (Bind_mount.Not_normalised { role; path })
        e;
      names ~needle:path (Bind_mount.error_to_string e))
    [
      ("/srv//data", "/data", Bind_mount.Host, "/srv//data");
      ("/srv/data/", "/data", Bind_mount.Host, "/srv/data/");
      ("//", "/data", Bind_mount.Host, "//");
      ("/srv", "/app//data", Bind_mount.Container, "/app//data");
      ("/srv", "/app/data/", Bind_mount.Container, "/app/data/");
      ("/srv", "//", Bind_mount.Container, "//");
    ]

let test_refuses_control_characters () =
  List.iter
    (fun (host, container, role, path) ->
      let e = refused ~host ~container in
      check error
        (Printf.sprintf "%S holds a control character" path)
        (Bind_mount.Control_character { role; path })
        e;
      names ~needle:"control character" (Bind_mount.error_to_string e))
    [
      ("/srv/da\nta", "/data", Bind_mount.Host, "/srv/da\nta");
      ("/srv/da\000ta", "/data", Bind_mount.Host, "/srv/da\000ta");
      ("/srv", "/app/da\tta", Bind_mount.Container, "/app/da\tta");
      ("/srv", "/app/da\x7fta", Bind_mount.Container, "/app/da\x7fta");
    ]

let test_refuses_container_root () =
  let e = refused ~host:"/srv/data" ~container:"/" in
  check error "the container root is refused" Bind_mount.Container_root e;
  let message = Bind_mount.error_to_string e in
  names ~needle:{|"/"|} message;
  names ~needle:"container" message

(* --- list codec --- *)

let test_list_refuses_duplicate_container_path_naming_it () =
  let message =
    list_refused
      (`List
         [
           entry ~host:"/srv/a" ~container:"/data" ~read_only:false;
           entry ~host:"/srv/b" ~container:"/logs" ~read_only:false;
           entry ~host:"/srv/c" ~container:"/data" ~read_only:true;
         ])
  in
  check string "the message is the duplicate's"
    (Bind_mount.error_to_string (Bind_mount.Duplicate_container_path "/data"))
    message;
  names ~needle:"/data" message;
  (* The same host directory mounted at two container paths is legitimate. *)
  check
    (result (list mount_fields) string)
    "one host path at two container paths is accepted"
    (Ok [ ("/srv/a", "/data", false); ("/srv/a", "/backup", true) ])
    (Result.map (List.map fields)
       (Bind_mount.list_of_yojson
          (`List
             [
               entry ~host:"/srv/a" ~container:"/data" ~read_only:false;
               entry ~host:"/srv/a" ~container:"/backup" ~read_only:true;
             ])))

let test_list_refuses_missing_read_only () =
  let message =
    list_refused
      (`List
         [
           `Assoc
             [
               ("host", `String "/srv/comalito/invoices");
               ("container", `String "/app/invoices");
             ];
         ])
  in
  names ~needle:"read_only" message;
  names ~needle:"/srv/comalito/invoices" message;
  (* A boolean spelled as a string is not a boolean. *)
  let message =
    list_refused
      (`List
         [
           `Assoc
             [
               ("host", `String "/srv/a");
               ("container", `String "/a");
               ("read_only", `String "true");
             ];
         ])
  in
  names ~needle:"read_only" message;
  names ~needle:"/srv/a" message

let test_list_refuses_unknown_key_in_entry () =
  let message =
    list_refused
      (`List
         [
           `Assoc
             [
               ("host", `String "/srv/a");
               ("container", `String "/a");
               ("read_only", `Bool false);
               ("mode", `String "ro");
             ];
         ])
  in
  names ~needle:{|"mode"|} message;
  names ~needle:"/srv/a" message;
  (* A key given twice is not one key: which value wins would be invisible. *)
  let message =
    list_refused
      (`List
         [
           `Assoc
             [
               ("host", `String "/srv/a");
               ("container", `String "/a");
               ("read_only", `Bool false);
               ("host", `String "/srv/b");
             ];
         ])
  in
  names ~needle:"/srv/b" message

let test_list_refuses_string_entry () =
  let message = list_refused (`List [ `String "/a:/b" ]) in
  names ~needle:"/a:/b" message;
  let message = list_refused (`String "/a:/b") in
  names ~needle:"/a:/b" message

let test_list_round_trips_through_json () =
  let declared =
    [
      accepted ~host:"/srv/comalito/invoices" ~container:"/app/invoices"
        ~read_only:false;
      accepted ~host:"/etc/comalito" ~container:"/app/config" ~read_only:true;
    ]
  in
  let json = Bind_mount.list_to_yojson declared in
  check string "the wire shape is a list of objects"
    {|[{"host":"/srv/comalito/invoices","container":"/app/invoices","read_only":false},{"host":"/etc/comalito","container":"/app/config","read_only":true}]|}
    (Yojson.Safe.to_string json);
  check
    (result (list mount_fields) string)
    "decoding the encoding gives back the declared mounts, in order"
    (Ok (List.map fields declared))
    (Result.map (List.map fields) (Bind_mount.list_of_yojson json))

let () =
  run "Bind mount"
    [
      ( "create",
        [
          test_case "accepts absolute paths and reads them back" `Quick
            test_accepts_absolute_paths_and_reads_them_back;
          test_case "refuses a relative host path, naming it" `Quick
            test_refuses_relative_host_path_naming_it;
          test_case "refuses a relative container path, naming it" `Quick
            test_refuses_relative_container_path_naming_it;
          test_case "refuses . and .. segments" `Quick
            test_refuses_dot_and_dotdot_segments;
          test_case "refuses a double slash and a trailing slash" `Quick
            test_refuses_double_slash_and_trailing_slash;
          test_case "refuses a control character" `Quick
            test_refuses_control_characters;
          test_case "refuses the container root" `Quick
            test_refuses_container_root;
        ] );
      ( "list",
        [
          test_case "refuses a duplicate container path, naming it" `Quick
            test_list_refuses_duplicate_container_path_naming_it;
          test_case "refuses an entry missing read_only" `Quick
            test_list_refuses_missing_read_only;
          test_case "refuses an unknown key in an entry" `Quick
            test_list_refuses_unknown_key_in_entry;
          test_case "refuses a string entry" `Quick
            test_list_refuses_string_entry;
          test_case "round-trips through JSON" `Quick
            test_list_round_trips_through_json;
        ] );
    ]
