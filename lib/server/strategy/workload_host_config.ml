module Bind_mount = Bondi_common.Bind_mount

let bind_mount (volume : Bind_mount.t) : Docker.Client.mount =
  {
    type_ = "bind";
    source = Bind_mount.host volume;
    target = Bind_mount.container volume;
    read_only = Bind_mount.read_only volume;
  }

let of_volumes (volumes : Bind_mount.t list option) : Docker.Client.host_config
    =
  let mounts =
    match volumes with
    | None
    | Some [] ->
        None
    | Some (_ :: _ as volumes) -> Some (List.map bind_mount volumes)
  in
  {
    binds = None;
    port_bindings = None;
    network_mode = None;
    restart_policy = Some Docker.Restart_policy.bondi_managed;
    mounts;
  }
