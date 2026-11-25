The health probe is one shell command that setup sends over SSH. It is run here
with sh against stand-in curl scripts, so each marker it prints is read off the
shell itself.

  $ SH="$(command -v sh)"
  $ "$PWD/alloy_health_probe.exe" > probe.sh
  $ mkdir tools fake
  $ for t in date sleep tail; do ln -s "$(command -v $t)" tools/$t; done

Curl answers 200: the probe says healthy.

  $ cat > fake/curl <<'STUB'
  > #!/bin/sh
  > printf 'All Alloy components are healthy.\n200'
  > STUB
  $ chmod +x fake/curl
  $ PATH="$PWD/fake:$PWD/tools" "$SH" -c "$(cat probe.sh)"
  BONDI_ALLOY_HEALTHY

Curl cannot connect (exit 7, prints 000 with -w): nothing answered.

  $ cat > fake/curl <<'STUB'
  > #!/bin/sh
  > printf '000'
  > exit 7
  > STUB
  $ PATH="$PWD/fake:$PWD/tools" "$SH" -c "$(cat probe.sh)"
  BONDI_ALLOY_NEVER_HEALTHY

Curl answers 500 with the body Alloy gives: the probe keeps the body, after its
marker. The body here follows Alloy v1.8.0's source, internal/service/http/http.go
line 205, and was not captured from a run.

  $ cat > fake/curl <<'STUB'
  > #!/bin/sh
  > printf 'unhealthy components: loki.write.grafana_cloud500'
  > STUB
  $ PATH="$PWD/fake:$PWD/tools" "$SH" -c "$(cat probe.sh)"
  BONDI_ALLOY_UNHEALTHY
  unhealthy components: loki.write.grafana_cloud

A listener that is not Alloy and answers 404 is no Alloy that reported itself
unhealthy: the port wording stays.

  $ cat > fake/curl <<'STUB'
  > #!/bin/sh
  > printf 'not found\n404'
  > STUB
  $ PATH="$PWD/fake:$PWD/tools" "$SH" -c "$(cat probe.sh)"
  BONDI_ALLOY_NEVER_HEALTHY

No curl on PATH: its own marker, at once.

  $ PATH="$PWD/tools" "$SH" -c "$(cat probe.sh)"
  BONDI_ALLOY_CURL_MISSING
