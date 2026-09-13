let traefik_image = "traefik:v3.6.8"
let alloy_image = "grafana/alloy:v1.8.0"

(* Not a live default: nothing under lib/ or bin/ reads this, now that the
   binary serves no port and the client reaches it over SSH. It survives only as
   the number no command may emit, and its one reader is a test asserting the
   check command names it nowhere. *)
let server_port = 3030
let network_name = "bondi-network"
let bondi_restart_policy = "unless-stopped"
