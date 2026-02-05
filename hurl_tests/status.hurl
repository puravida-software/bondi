GET http://localhost:3030/api/v1/status

HTTP 404
[Asserts]
body == "Container not found"
