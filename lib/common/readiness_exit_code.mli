(** The process exit code a Bondi server subcommand leaves behind when the box
    it runs on is not in a state to serve.

    Two parties have to agree on this number and neither can detect a
    disagreement on its own: the server, which picks it from the failure class
    it is reporting, and a client that reads it back over a transport carrying
    the remote status and nothing else. A client whose number has drifted does
    not fail -- it reads a box that named its own faults as a box that could not
    be reached, and sends an operator to the network instead of to the machine.

    It lives in the shared library rather than beside the server's own table of
    codes because the client library may not depend on the server's. *)

val not_ready : int
(** The code left behind by a box that is not in a state to serve.

    Distinct from every other code the server can leave, and picked away from
    the ones a reader would misattribute: 0 reports a failure as a success, 255
    is the transport's own, 128 and above is a signal, and 123 to 125 belong to
    the command-line library. The whole table and the reasoning behind it stay
    with the server, which is the only party that maps a failure class to a
    code; this is the one value a reader outside that library must also know. *)
