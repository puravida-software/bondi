(** Serving, and the environment every command of the binary runs inside.

    Everything the server does needs the same capabilities: an Eio network, an
    Eio clock, a Docker Engine client and a way to deliver alerts.
    {!with_environment} builds that set once for the process and hands it over,
    {!start} mounts the routes that use it, and {!serve} is the two composed --
    which is what the binary's [serve] subcommand runs. The split exists so that
    a command which is not the HTTP server holds the same capabilities without
    entering the Lwt event loop -- that loop is serving's alone. *)

val start :
  clock:'clock Eio.Time.clock ->
  client:Docker.Client.t ->
  net:'net Eio.Net.t ->
  deliver:
    (net:'net Eio.Net.t ->
    clock:'clock Eio.Time.clock ->
    targets:Bondi_common.Alert.sink list ->
    payload:Bondi_common.Alert.payload ->
    unit) ->
  Server_config.t ->
  unit Lwt.t
(** [start ~clock ~client ~net ~deliver config] mounts every route under
    [/api/v1], behind the API-token middleware, and serves them on [config]'s
    interface and port.

    The capabilities are taken rather than built, because they belong to the
    process and not to the router: the same four values are what a subcommand
    holding no HTTP request is given. The returned promise is Dream's own and is
    resolved when serving stops, so awaiting it is awaiting the life of the
    process. *)

val with_environment :
  (net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t ->
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  client:Docker.Client.t ->
  deliver:
    (net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t ->
    clock:float Eio.Time.clock_ty Eio.Resource.t ->
    targets:Bondi_common.Alert.sink list ->
    payload:Bondi_common.Alert.payload ->
    unit) ->
  'a) ->
  'a
(** [with_environment f] builds the environment described above and applies [f]
    to it, answering whatever [f] answers.

    {b It enters [Eio_main.run], and [Eio_main.run] cannot be nested.} This is a
    precondition on every caller, not an implementation note: a process enters
    it exactly once, and nothing reached from [f] may call it again. A second
    entry raises where it stands rather than returning a failure a caller could
    classify. Each subcommand that needs a capability is written as one such
    [f], and none of them calls another.

    Alert delivery is best effort from the moment it is built: where the system
    trust store cannot be loaded, [f] is given a delivery function that drops
    every payload and the reason is traced, rather than one with TLS disabled. A
    command still runs on a box whose trust store is broken; it does not alert.
*)

val serve : unit -> (unit, Server_config.error) result
(** Read the server's configuration, build the environment and serve.

    The configuration is read first, so an error is answered without a Docker
    client, a trust store or an Eio runtime having been created for a process
    that is about to stop. That is the only failure this reports: everything
    after it belongs to {!start}, whose promise resolves when serving stops, at
    which point this answers [Ok ()]. *)
