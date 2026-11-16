let journal_path = Bondi_common.Defaults.journal_path
let state_dir = Bondi_common.Defaults.state_dir

type t = { docker_options : string list; alloy_options : string list }

let journal ~host_state_dir =
  {
    docker_options =
      [
        "--mount";
        Printf.sprintf "type=bind,source=%s,target=%s,readonly" journal_path
          journal_path;
        "--mount";
        Printf.sprintf "type=bind,source=%s,target=%s" host_state_dir state_dir;
      ];
    alloy_options = [ "--storage.path=" ^ state_dir ];
  }
