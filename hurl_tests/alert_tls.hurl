# Gated integration check: prove the server Docker image can make a real
# outbound HTTPS POST to an alert sink with certificate validation (the runtime
# image carries ca-certificates and TLS is wired, never ~https:None).
#
# The exit_code_severities map forces exit 0 into the failure severity so the
# run always routes an alert; the failure sink is a real https endpoint, so the
# server performs a genuine TLS handshake against the system trust store.
# Delivery is best-effort and never changes the run's recorded outcome, so the
# handshake itself is confirmed from the server logs (and at the sink), not from
# this response.
POST {{host}}/api/v1/run
Content-Type: application/json
{
  "job": "alert-tls-check",
  "image": "alpine:latest",
  "env_vars": {
    "TEST_VAR": "test_value"
  },
  "exit_code_severities": {
    "failure": [0]
  },
  "alert_sinks": {
    "critical": [],
    "failure": ["https://example.com/alert"]
  }
}

HTTP 200
[Asserts]
jsonpath "$.exit_code" == 0
