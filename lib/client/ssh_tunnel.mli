(** Reaching the orchestrator over SSH rather than over the open internet.

    The orchestrator API can start a container with the host Docker socket
    mounted, so it is equivalent to root on the box. It is therefore published
    on loopback only (see [Cmd.Setup] and bondi.yaml's [bind_address]), and a
    client on another machine reaches it by forwarding a local port through SSH.

    That also encrypts the payload, which is the reason to prefer this over a
    firewall allowlist: a deploy body carries [env_vars], [registry_user] and
    [registry_pass], and over plain HTTP to a public address those crossed the
    internet in the clear. An allowlist changes who may connect; it does not
    encrypt anything. *)

val tunnel_command :
  key_path:string ->
  user:string ->
  host:string ->
  local_port:int ->
  remote_port:int ->
  string
(** The [ssh] invocation, separated from running it so it can be asserted. *)

val free_local_port : unit -> int
(** A port the kernel reports as free. Racy by nature -- something else can take
    it between the check and [ssh] binding it -- which is why the tunnel is
    started with [ExitOnForwardFailure] and its readiness is confirmed rather
    than assumed. *)

val with_tunnel :
  ssh:Config_file.server_ssh ->
  host:string ->
  remote_port:int ->
  (int -> ('a, string) result) ->
  ('a, string) result
(** [with_tunnel ~ssh ~host ~remote_port f] forwards a free local port to
    [remote_port] on [host]'s loopback, waits until that port actually answers,
    and calls [f local_port]. The tunnel is torn down before returning, on any
    path including an exception raised by [f]. *)
