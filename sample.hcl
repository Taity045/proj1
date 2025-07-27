#we can try 2 options

#LOL This purely based on my assumptions i don't know how your current code looks like, so there might a look of caveats 

#option 1
#using ignore changes in terraform 


resource "grafana_synthetic_monitoring_private_probe" "probe" {
  name = var.probe_name
}

resource "aws_secretsmanager_secret" "probe_token" {
  name = "grafana/${var.probe_name}/registration_token"
}

resource "aws_secretsmanager_secret_version" "probe_token" {
  secret_id     = aws_secretsmanager_secret.probe_token.id
  secret_string = grafana_synthetic_monitoring_private_probe.probe.registration_token

  lifecycle {
    ignore_changes = [secret_string]
  }
}



#Option 2
#automatic rotation and fetch on each "query" with a helper script


resource "grafana_synthetic_monitoring_private_probe" "probe" {
  name = var.probe_name
}

data "external" "probe_token" {
  program = ["bash", "${path.module}/scripts/get_probe_token.sh",
             grafana_synthetic_monitoring_private_probe.probe.id,
             var.grafana_api_token]   # Service‑account token with SM Admin perms
}

resource "aws_secretsmanager_secret" "probe_token" {
  name = "grafana/${var.probe_name}/registration_token"
}

resource "aws_secretsmanager_secret_version" "probe_token" {
  secret_id     = aws_secretsmanager_secret.probe_token.id
  secret_string = data.external.probe_token.result.token
}


#!/usr/bin/env bash
# Usage: get_probe_token.sh <PROBE_ID> <SERVICE_ACCOUNT_TOKEN> [REGION]
set -euo pipefail
PROBE_ID=$1
BEARER=$2
REGION=${3:-"us-east-0"}

curl -s -H "Authorization: Bearer ${BEARER}" \
  "https://synthetic-monitoring-api.${REGION}.grafana.net/v1/probes/${PROBE_ID}/token" \
  | jq -r '{token: .registration_token}'
