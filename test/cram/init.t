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
