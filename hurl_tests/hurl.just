hurl-tests: run-status run-health run-deploy run-run

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

run-deploy:
    hurl \
    --error-format=long \
    --variable host=${HURL_HOST} \
    hurl_tests/deploy.hurl

run-run:
    hurl \
    --error-format=long \
    --variable host=${HURL_HOST} \
    hurl_tests/run.hurl
