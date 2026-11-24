module Docker = Bondi_server__Docker__Client

let mk_container ~id ~image ~names ?(image_id = "sha256:test")
    ?(state = Some "running") ?(status = Some "Up") ?(labels = None) () :
    Docker.container =
  { Docker.id; image; image_id; names; state; status; labels }

let mk_health_state ?(failing_streak = 0) ?(log = []) status :
    Docker.health_state =
  { status; failing_streak; log }

let mk_inspect ~created_at ~restart_count ~status ?(exit_code = 0)
    ?(health = None) ?(host_config = None) ?(networks = None) () :
    Docker.inspect_response =
  {
    created_at;
    restart_count;
    state = { status; exit_code; health };
    host_config;
    network_settings = Option.map (fun networks -> { Docker.networks }) networks;
  }

let mount_testable : Docker.mount Alcotest.testable =
  Alcotest.testable
    (fun fmt (m : Docker.mount) ->
      Format.fprintf fmt "{%s %s -> %s ro=%b}" m.type_ m.source m.target
        m.read_only)
    ( = )

let host_config_testable : Docker.host_config Alcotest.testable =
  Alcotest.testable
    (fun fmt host_config ->
      Format.pp_print_string fmt
        (Yojson.Safe.to_string (Docker.host_config_to_yojson host_config)))
    ( = )

(* Every capture is the body a real Docker Engine returned for
   [GET /images/{name}/json], saved byte for byte; how each image was built and
   captured is in [fixtures/image_inspect/README.md]. Each image is read at
   v1.41, the version negotiation picks on today's engines, where
   [ContainerConfig] is still sent but null, and at v1.45, the first version that
   no longer sends it at all. The path is resolved from the test executable, so
   the read holds under [dune runtest], which is what copies the captures next
   to the executable. *)
let capture_versions = [ "v1.41"; "v1.45" ]

let image_inspect_capture_body ~kind ~version =
  let name = Printf.sprintf "%s.%s.json" kind version in
  let path =
    Filename.concat
      (Filename.dirname Sys.executable_name)
      (Filename.concat "fixtures" (Filename.concat "image_inspect" name))
  in
  In_channel.with_open_bin path In_channel.input_all

let image_inspect_capture ~kind ~version =
  let name = Printf.sprintf "%s.%s.json" kind version in
  let body = image_inspect_capture_body ~kind ~version in
  match
    Docker.image_inspect_response_of_yojson (Yojson.Safe.from_string body)
  with
  | Ok response -> response
  | Error msg ->
      Alcotest.fail (Printf.sprintf "%s does not decode: %s" name msg)
