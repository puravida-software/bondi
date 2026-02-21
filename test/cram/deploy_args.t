Deploy with no arguments prints an error.

  $ bondi-client deploy 2>&1
  Deployment process initiated...
  Error: no deployments specified. Use name:tag (e.g. my-service:v1.2.3)
  [1]

Deploy with a name but no tag prints an error.

  $ bondi-client deploy my-service 2>&1
  Deployment process initiated...
  Error: missing tag (expected name:tag)
  [1]

Deploy with an empty tag after the colon prints an error.

  $ bondi-client deploy "my-service:" 2>&1
  Deployment process initiated...
  Error: missing tag (expected name:tag)
  [1]
