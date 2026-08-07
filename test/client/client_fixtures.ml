module Report = Bondi_client.Status_report

let mk_config ?user_service ?cron_jobs ?managed_containers () :
    Bondi_client.Config_file.t =
  {
    user_service;
    bondi_server = { version = "0.1.0" };
    traefik = None;
    cron_jobs;
    alloy = None;
    managed_containers;
  }

let mk_managed_container name image tag :
    Bondi_client.Config_file.managed_container =
  {
    name;
    image;
    tag;
    restart = "unless-stopped";
    network = Some "bondi-network";
    ports = None;
    env_vars = None;
    secret_env_vars = None;
  }

let row_named name (rows : Report.row list) =
  match
    List.find_opt (fun (row : Report.row) -> String.equal row.name name) rows
  with
  | Some row -> row
  | None ->
      Alcotest.failf "expected a row named %s, got rows: %s" name
        (String.concat ", "
           (List.map (fun (row : Report.row) -> row.name) rows))
