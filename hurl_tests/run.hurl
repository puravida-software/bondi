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
jsonpath "$.exit_code" equals 0
