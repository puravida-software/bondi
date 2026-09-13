(* Each right-hand side is the plain module name, resolved through the alias
   module dune opens here. Naming the mangled [Bondi_server__X] instead compiles
   and then races: dune derives this module's dependencies from the names it can
   map back to sources, a mangled name maps to none, and the cmi it needs is
   left free to not exist yet. That failure only surfaces on a cold build, which
   is every CI and Docker build and no local one. *)
module Env = Env

(* No OCaml caller outside this library names [Environment] -- the binary reaches
   only [Cli], and the tests reach the mangled name. The alias is here for the
   doc references: [run.mli], [deploy.mli] and [status.mli] each point at
   [Environment.with_environment], and measured on 2026-09-13 those four
   references stop resolving the moment this line goes, which is four warnings
   out of the documentation lint and nothing out of the compiler. That is what
   separates it from [Cmd_io] and [Readiness], which are deliberately absent
   below.

   Nothing outside this library names [Cmd_io] in either sense. [Readiness] is
   the harder of the two: a public signature does name it -- [Cli.eval_argv]
   takes [observe : cron_configured:bool -> Readiness.observation list] -- but
   no caller outside this build does. [bin/server/] and the test suite are the
   only callers there are, and the test suite reaches the type through the
   mangled [Bondi_server__Readiness]. Aliasing it would widen the surface
   without buying a caller, which is the measurement [Environment] has and this
   does not.

   What that costs is a gap in the documentation lint, which only reports
   against modules the rendered doc set reaches. [observed -- 2026-09-13, dune
   3.20.2, odoc 3.1.0] a deliberately broken doc reference injected into
   [readiness.mli] produced no diagnostic at all and [just lint-doc] exited 0,
   while the same injection in [cli.mli] reddened the gate with a resolution
   warning. So a reference that rots inside a module absent from this list rots
   silently. *)
module Environment = Environment
module Cron_secrets = Cron_secrets
module Diagnostics = Diagnostics
module Handler_error = Handler_error
module Status = Status
module Deploy = Deploy
module Run = Run
module Crontab = Crontab
module Docker = Docker
module Strategy = Strategy
module Cli = Cli
