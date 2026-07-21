GET {{host}}/api/v1/status?service=grokkr

HTTP 404
[Asserts]
body == "Container not found"

# The status response is additive: a server with no managed containers omits
# the key entirely, so a consumer written against the previous shape still
# parses it. Asserting the infrastructure object is present as well, otherwise
# "managed not exists" would hold for any response at all.
GET {{host}}/api/v1/status

HTTP 200
[Asserts]
jsonpath "$.infrastructure" exists
jsonpath "$.infrastructure.managed" not exists
