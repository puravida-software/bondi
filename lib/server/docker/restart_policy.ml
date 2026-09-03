let bondi_managed : Client.restart_policy =
  {
    Client.name = Bondi_common.Defaults.bondi_restart_policy;
    maximum_retry_count = None;
  }

let applied_matches : Client.restart_policy option -> bool = function
  | None -> false
  | Some applied ->
      String.equal applied.Client.name
        Bondi_common.Defaults.bondi_restart_policy

let of_inspect :
    (Client.inspect_response, string) result -> Client.restart_policy option =
  function
  | Error _ -> None
  | Ok inspection ->
      Option.bind inspection.Client.host_config
        (fun (host_config : Client.host_config) -> host_config.restart_policy)
