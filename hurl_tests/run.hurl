# First run: verify response includes warning field (null when no issues)
POST {{host}}/api/v1/run
Content-Type: application/json
{
  "job": "test-job",
  "image": "alpine:latest",
  "env_vars": {
    "TEST_VAR": "test_value"
  }
}

HTTP 200
[Asserts]
jsonpath "$.exit_code" == 0
jsonpath "$.warning" == null

# Verify container named test-job exists after run with completed status
GET {{host}}/api/v1/status
HTTP 200
[Asserts]
jsonpath "$.cron_jobs[?(@.name=='test-job')].status" nth 0 == "completed"

# Second run of same job: old container cleaned up, new one succeeds
POST {{host}}/api/v1/run
Content-Type: application/json
{
  "job": "test-job",
  "image": "alpine:latest",
  "env_vars": {
    "TEST_VAR": "test_value"
  }
}

HTTP 200
[Asserts]
jsonpath "$.exit_code" == 0
jsonpath "$.warning" == null

# A body the decoder rejects is the caller's mistake, not an orchestrator fault,
# so it answers 400 rather than the 404 this endpoint used to give every
# failure. The message names the keys that arrived — "imag" is the misspelling
# under test — and never their values.
POST {{host}}/api/v1/run
Content-Type: application/json
{
  "job": "test-job",
  "imag": "alpine:latest"
}

HTTP 400
[Asserts]
body contains "imag"
body not contains "404"

# A decodable body naming an image with no tag is also the caller's mistake.
# This is the path that dispatches an alert before failing, so a 500 here would
# report a configuration error as an orchestrator fault.
POST {{host}}/api/v1/run
Content-Type: application/json
{
  "job": "test-job",
  "image": "alpine"
}

HTTP 400
[Asserts]
body contains "tag"
