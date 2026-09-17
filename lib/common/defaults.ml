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
let bondi_restart_policy = "unless-stopped"
