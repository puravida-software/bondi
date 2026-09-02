(** Configuration fixtures and row lookups shared by the client's test
    executables.

    These are the client-shaped half of {!Test_helpers}: they name
    {!Bondi_client} types, so they cannot live beside the assertion helpers the
    common tests also link. *)

val mk_config :
  ?user_service:Bondi_client.Config_file.user_service ->
  ?cron_jobs:Bondi_client.Config_file.cron_job list ->
  ?managed_containers:Bondi_client.Config_file.managed_container list ->
  ?bind_address:string ->
  ?api_token:string ->
  unit ->
  Bondi_client.Config_file.t
(** A configuration declaring only what the caller names.

    Traefik and Alloy are absent. A test that needs either builds the record
    itself, because what it is testing is what their presence changes. *)

val mk_managed_container :
  string -> string -> string -> Bondi_client.Config_file.managed_container
(** A managed container declaration with the defaults every test uses, named by
    its name, image and tag. *)

val row_named :
  string ->
  Bondi_client.Status_report.row list ->
  Bondi_client.Status_report.row
(** The row with this name, or a test failure naming every row there was.

    Never a partial function: a lookup that returned an option would be
    unwrapped at each call site, and a test that fails by raising [Not_found]
    says nothing about which rows it did get. *)
