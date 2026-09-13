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
