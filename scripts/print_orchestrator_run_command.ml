(* Print the command `bondi setup` runs to start an orchestrator, so that the
   image gate can assert against the client's own string instead of one its
   author remembered. The output is diffed against the tracked fixture beside
   this file by `dune runtest`, so a change to the command is a red test and a
   deliberate change is accepted with `dune promote`.

   The shell script that reads the fixture runs where there is no OCaml
   toolchain, which is why the string is generated here and committed rather
   than computed at the moment it is used. *)

module Config_file = Bondi_client.Config_file
module Setup = Bondi_client.Cmd.Setup

(* The version the deployed orchestrators carry as this gate is written. It
   selects the image tag in the command; the script substitutes the image under
   test for it, and refuses if the tail of the command is not the image it
   expected, so a version that moves cannot silently turn into no substitution
   at all. *)
let deployed_version = "0.12.0"

(* Only whether the list is non-empty reaches the run command -- it decides the
   spool mount and `--user root`. The values are named anyway rather than left
   to a fixture builder's optional arguments: a field that defaults out of sight
   is a field nobody chose. *)
let a_cron_job : Config_file.cron_job =
  {
    Config_file.name = "nightly";
    image = "registry.example.com/org/nightly";
    schedule = "10 22 * * *";
    network = None;
    env_vars = None;
    secret_env_vars = None;
    registry_user = None;
    registry_pass = None;
    alert_sinks = None;
    exit_code_severities = None;
    server = { Config_file.ip_address = "203.0.113.1"; ssh = None; port = None };
  }

(* `bind_address` and `api_token` also reach the run command and are pinned to
   their defaults here. The header this file prints names them and says why they
   get no line of their own, so the exclusion is stated where the fixture's
   reader is rather than only where its author was. *)
let config ~(cron_jobs : Config_file.cron_job list option) : Config_file.t =
  {
    user_service = None;
    bondi_server =
      {
        Config_file.version = deployed_version;
        bind_address = None;
        api_token = None;
      };
    traefik = None;
    cron_jobs;
    alloy = None;
    managed_containers = None;
  }

let print_labelled label config =
  match Setup.orchestrator_run_command config with
  | Ok command -> Printf.printf "%s %s\n" label command
  | Error message ->
      prerr_endline message;
      exit 1

let () =
  print_string
    "# The command `bondi setup` runs to start an orchestrator, produced by \
     Bondi's\n\
     # own client rather than transcribed. Generated: do not edit by hand. `dune\n\
     # runtest` regenerates and diffs it, and `dune promote` accepts a change.\n\
     #\n\
     # One line per rootless-sensitive deployment shape, which is not one line\n\
     # per deployment shape. The command varies on four config inputs; the two\n\
     # lines below are the input that moves the flags a rootless engine\n\
     # reinterprets: `no-cron` and, with cron jobs configured, `cron`, which\n\
     # additionally carries `--user root` and the spool mount.\n\
     #\n\
     # Held constant at their defaults, and named here rather than left to be\n\
     # inferred from the builder: `bondi_server.bind_address`, which only\n\
     # changes the address in `-p ADDR:3030:3030`, and `bondi_server.api_token`,\n\
     # which only adds `-e BONDI_API_TOKEN=`. Neither reaches a flag a rootless\n\
     # engine reinterprets, which is what this fixture exists to pin. The\n\
     # residue is that everything asserted through these lines is asserted\n\
     # against an unauthenticated API; a token-gated orchestrator is a shape\n\
     # nothing here covers.\n";
  print_labelled "no-cron" (config ~cron_jobs:None);
  print_labelled "cron" (config ~cron_jobs:(Some [ a_cron_job ]))
