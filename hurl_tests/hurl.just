hurl-tests: run-status run-health

run-status:
    hurl \
    --error-format=long \
    --variable host=${HURL_HOST} \
    hurl_tests/status.hurl

run-health:
    hurl \
    --error-format=long \
    --variable host=${HURL_HOST} \
    hurl_tests/health.hurl
