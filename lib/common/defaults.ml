let traefik_image = "traefik:v3.6.8"
let alloy_image = "grafana/alloy:v1.8.0"
let network_name = "bondi-network"

(* Named here, beside the network, because two libraries now have to agree on
   it: the client builds the commands that write and read the file, and the
   account of what a run corrected names the file those readings are about. A
   second spelling of the path would print an operator a file that is not the
   one the run touched. *)
let alloy_config_dir = "/etc/bondi/alloy"
let alloy_config_path = alloy_config_dir ^ "/config.alloy"
let alloy_env_path = alloy_config_dir ^ "/env"
let journal_path = "/var/log/journal"

(* Under /var/lib rather than beside the config in /etc/bondi/alloy: it is state
   Alloy writes, not configuration Bondi writes. The config directory is also
   deleted whole and rewritten on every setup, and a read position deleted with
   it would let the next Alloy re-read the journal from the start. *)
let state_dir = "/var/lib/bondi/alloy"
let bondi_restart_policy = "unless-stopped"
