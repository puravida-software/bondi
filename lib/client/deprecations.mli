(** What a run of the client owes an operator about configuration fields Bondi
    still parses and no longer acts on.

    [bondi_server.bind_address] and [bondi_server.api_token] are read from
    [bondi.yaml] and change nothing the orchestrator does: it serves no HTTP, so
    there is no socket to bind and no request to authenticate. The fields stay
    in the record because parsing is strict -- removing them would fail the
    whole read of any configuration that declares one, on exactly the boxes most
    likely to declare it -- so a message is the only place the operator learns
    they are dead.

    The module exists rather than a helper inside [Config_file] or the setup
    command because neither of those carries an [.mli]: a helper added to either
    becomes public by accident. And which commands say this is a property of the
    call sites, not of the deciding -- a module that printed the messages itself
    could not be asked what it would say, so there would be nothing for a test
    of the placement to hold. *)

val messages : Config_file.bondi_server -> string list
(** [messages server] is one message per deprecated field [server] declares:
    none when it declares neither, one each when it declares one, both when it
    declares both, ordered as the fields are ordered in the record.

    It takes the parsed record rather than the two [string option]s, so a field
    added to [Config_file.bondi_server] later is a compile error here rather
    than a knob nobody thought to warn about. It answers a list rather than an
    option because both fields can be declared and each gets its own sentence.

    The token's message says to rotate as well as to remove: a credential that
    sat in a configuration file is compromised whether or not anything still
    reads it, which is not true of a stale binding address.

    Pure: it reads nothing, prints nothing and can fail in no way a caller has
    to classify. *)
