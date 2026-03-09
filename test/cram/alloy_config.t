Init creates a bondi.yaml that includes a commented-out alloy section.

  $ bondi-client init
  Initialising Bondi!
  Bondi initialised successfully!

The generated config contains a commented-out alloy section.

  $ grep -c "# alloy:" bondi.yaml
  1

  $ grep -A 10 "# alloy:" bondi.yaml
  # alloy:
  #   grafana_cloud:
  #     instance_id: "{{GRAFANA_INSTANCE_ID}}"
  #     api_key: "{{GRAFANA_API_KEY}}"
  #     endpoint: "https://logs-prod-us-central1.grafana.net/loki/api/v1/push"
  #   # image: grafana/alloy:v1.8.0
  #   # collect: all
  #   # labels:
  #   #   env: production
