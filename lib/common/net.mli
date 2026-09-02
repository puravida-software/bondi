val is_loopback : string -> bool
(** [is_loopback addr] is whether binding or publishing to [addr] confines the
    socket to the host. Recognises all of 127.0.0.0/8, ["localhost"] and the
    IPv6 loopback in both bare and bracketed forms. *)
