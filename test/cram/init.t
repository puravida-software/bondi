Init creates a bondi.yaml in a fresh directory.

  $ bondi-client init
  Initialising Bondi!
  Bondi initialised successfully!

  $ test -f bondi.yaml && echo "config exists"
  config exists

The generated config uses the directory name as the service name.

  $ head -2 bondi.yaml
  service:
    name: cram

Running init again says it's already initialised.

  $ bondi-client init
  Bondi already initialised, nothing else to do!

The template advertises every optional section, so an operator discovers them
without reading the usage guide.

  $ grep -c '^# cron_jobs:' bondi.yaml
  1
  $ grep -c '^# alloy:' bondi.yaml
  1
  $ grep -c '^# managed_containers:' bondi.yaml
  1

Both a cron job and a managed container can declare a network, so the two
examples each show it.

  $ grep -c '^#     network: bondi-network' bondi.yaml
  2

The template declares only the fields Bondi still acts on, so the very first
setup run against a generated config warns about nothing the template wrote.
The version line is read from the same file to show the greps are looking at
real generated content.

  $ grep -c '^  version:' bondi.yaml
  1
  $ grep -c bind_address bondi.yaml || true
  0
  $ grep -c api_token bondi.yaml || true
  0

The scaffolded ssh block declares a user and nothing else. Bondi authenticates
with the operator's own ssh configuration unless a manifest hands it a key, and
a template that writes key fields a new user never asked for is what put an
unusable placeholder into every manifest in the estate.

  $ grep -c '^        private_key' bondi.yaml || true
  0

The same pattern's indentation is the affirmative arm: the ssh fields the
template does write are at that level, and there are two of them, so the zero
above is the key fields being absent rather than a pattern that would match
nothing wherever they were.

  $ grep -c '^        user: root' bondi.yaml
  2

The generated file is one Bondi can read. Every placeholder it names is
supplied first: the template is rendered from the environment before it is
parsed, and that rendering does not skip commented lines, so the three
placeholders that only appear in commented-out example sections have to be set
as well. The target named here is one the template never writes, so the read
runs to completion -- the ssh identity check included -- and the run stops at
the target rather than at the file.

  $ REGISTRY_USER=someone REGISTRY_PASS=secret SOME_PASSWORD=secret \
  >   GRAFANA_INSTANCE_ID=id GRAFANA_API_KEY=key \
  >   bondi-client deploy not-a-service:v1 2>&1
  Deployment process initiated...
  Unknown deployment target: not-a-service
  [1]
