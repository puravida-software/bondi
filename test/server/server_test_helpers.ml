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
