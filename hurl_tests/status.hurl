GET {{host}}/api/v1/status?service=grokkr

HTTP 404
[Asserts]
body == "Container not found"
