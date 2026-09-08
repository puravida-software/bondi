(* Each right-hand side is the plain module name, resolved through the alias
   module dune opens here. Naming the mangled [Bondi_server__X] instead compiles
   and then races: dune derives this module's dependencies from the names it can
   map back to sources, a mangled name maps to none, and the cmi it needs is
   left free to not exist yet. That failure only surfaces on a cold build, which
   is every CI and Docker build and no local one. *)
module Env = Env
module Auth = Auth
module Server_config = Server_config
module Cron_secrets = Cron_secrets
module Diagnostics = Diagnostics
module Handler_error = Handler_error
module Health = Health
module Status = Status
module Deploy = Deploy
module Run = Run
module Crontab = Crontab
module Docker = Docker
module Strategy = Strategy
module Cli = Cli
