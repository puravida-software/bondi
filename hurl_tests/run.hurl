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
