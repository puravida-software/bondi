module Docker = Bondi_server__Docker__Client

let mk_container ~id ~image ~names ?(image_id = "sha256:test")
    ?(state = Some "running") ?(status = Some "Up") ?(labels = None) () :
    Docker.container =
  { Docker.id; image; image_id; names; state; status; labels }

let mk_health_state ?(failing_streak = 0) ?(log = []) status :
    Docker.health_state =
  { status; failing_streak; log }

let mk_inspect ~created_at ~restart_count ~status ?(exit_code = 0)
    ?(health = None) ?(host_config = None) () : Docker.inspect_response =
  {
    created_at;
    restart_count;
    state = { status; exit_code; health };
    host_config;
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
