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

# Gated: not part of the default hurl-tests bundle. Requires a full server
# deployment and reaches a real external https host to exercise outbound TLS.
run-alert-tls:
    hurl \
    --error-format=long \
    --variable host=${HURL_HOST} \
    hurl_tests/alert_tls.hurl
