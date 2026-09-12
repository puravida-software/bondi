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

val with_path : string -> (unit -> 'a) -> 'a
(** [with_path value f] runs [f] with PATH set to [value], restoring whatever
    was there on every path out.

    An absent PATH is restored as an empty one, there being no [unsetenv] in
    [Unix] — which is what an absent PATH means to a search. *)

val with_ssh_stub : string -> (unit -> 'a) -> 'a
(** [with_ssh_stub script f] runs [f] with an executable named [ssh], holding
    [script], at the front of PATH.

    The runner spawns whatever [ssh] the operator's PATH resolves, so this is
    the entire substitution: there is no seam inside it, and every step it takes
    on the way to the spawn — reading the configuration, writing the key,
    building the option set and the command line — is still taken. PATH and the
    stub are both restored on every path out, including one [f] leaves by
    raising: a stub left on PATH outlives its case, and every later case in the
    executable would resolve [ssh] to whichever stub ran last.

    Shared rather than copied because a second copy is a second answer to where
    the stub goes and when it is taken away, and the two tests that drive a real
    spawn are not testing that. *)

val staged_keys_during : (unit -> 'a) -> 'a * string list
(** [staged_keys_during f] is [f]'s value and the key file each [ssh] invocation
    made during it was handed, in order.

    The key is written to a temporary file and removed before the call that
    needed it returns, so how many were staged cannot be counted from the
    filesystem afterwards and the value that carries the path says nothing. The
    stub records the path instead, which is the same fact seen from the one
    place it is still visible.

    The list is the invocations, not the distinct paths: a caller that wants to
    know one key served several calls needs both numbers, because "one distinct
    path" is also true of a session whose calls never ran. *)
