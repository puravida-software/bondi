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
