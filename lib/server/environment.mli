(** The environment every command of the binary runs inside.

    Everything the orchestrator does needs the same capability set: an Eio
    network, an Eio clock, a Docker Engine client and a way to deliver alerts.
    The set belongs to the process rather than to any one command, so it is
    built once at the outermost point of the process and handed to whichever
    command is running. That is what this module is for: a command takes its
    capabilities rather than creating them, and the single entry into the Eio
    runtime has one owner that every command can be read against. *)

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

    The nesting precondition is held by inspection and not by a test. There are
    three callers -- the [deploy], [run] and [status] subcommands of {!Cli}, and
    not [check], which builds no environment at all -- and each is one [f] that
    calls no other. Nothing under [dune test] reaches this function: it takes no
    seam a test could replace, it creates a real Docker client and loads the
    box's real trust store, and a test written to prove that a second entry
    raises would itself be the second entry. What exercises the path in practice
    is the image gate, which needs a Docker Engine and does not run under
    [dune test]. A fourth caller added later is caught by this paragraph or by
    nothing, so the obligation is stated as one: whoever adds a fourth call
    site, in the change that adds it, owes it a check that the new caller is a
    fourth {e sibling} -- a callback entered directly from {!Cli}, calling no
    other -- and owes this list its name. A call reached from inside one of the
    existing callbacks, or a helper shared between two subcommands that builds
    its own environment on the way, is the second entry, and it raises on a box
    rather than failing a build.

    One process-wide precondition is deliberately established elsewhere, and a
    reader should not take the capability set above for the whole of what the
    process sets up. The default random generator that outbound TLS draws from
    is seeded by [Alert_delivery.make_https] rather than here, because [https]
    is abstract and constructed only there: the seam that owns the trust store
    owns the generator with it, and neither can be got round by a caller. That
    placement is the reason this function can build a delivery function without
    naming entropy at all. *)
