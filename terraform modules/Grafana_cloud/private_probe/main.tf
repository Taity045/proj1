# Decode and extract credentials and configurations
locals {
  creds           = jsondecode(data.aws_secretsmanager_secret_version.on_prem_secret_version.secret_string)
  probes_list     = jsondecode(data.aws_secretsmanager_secret_version.probe_config_version.secret_string).probes
  ssh_private_key = data.aws_secretsmanager_secret_version.ssh_key_version.secret_string
  
  # Try to get existing tokens from Secrets Manager, fallback to empty if not found
  existing_tokens = try(
    jsondecode(data.aws_secretsmanager_secret_version.probe_tokens_version[0].secret_string),
    {}
  )
  
  # Create probes with stored tokens (if available) or use newly generated ones
  probes_with_tokens = [
    for i, probe in local.probes_list : merge(probe, {
      # Use stored token if available, otherwise use the newly generated token from Grafana resource
      registration_token = lookup(
        local.existing_tokens,
        "probe_${i}_token", # Key format for stored tokens
        grafana_synthetic_monitoring_probe.probes[i].auth_token
      )
      probe_id     = grafana_synthetic_monitoring_probe.probes[i].id
      api_server   = "https://synthetic-monitoring-api.grafana.net"
      environment  = lookup(probe, "environment", var.grafanacloud_stack)
    })
  ]
  
  # Prepare tokens for storage in Secrets Manager
  tokens_to_store = {
    for i, probe in grafana_synthetic_monitoring_probe.probes :
    "probe_${i}_token" => probe.auth_token
  }
}

# Create Grafana synthetic monitoring probes
resource "grafana_synthetic_monitoring_probe" "probes" {
  count = length(local.probes_list)

  name      = "${local.probes_list[count.index].city}, ${local.probes_list[count.index].stack} on-prem ${count.index}"
  latitude  = lookup(local.probes_list[count.index], "latitude", 0)
  longitude = lookup(local.probes_list[count.index], "longitude", 0)
  region    = lookup(local.probes_list[count.index], "region", "default")

  labels = {
    environment = lookup(local.probes_list[count.index], "environment", var.grafanacloud_stack)
    city        = local.probes_list[count.index].city
    stack       = local.probes_list[count.index].stack
  }
}

# ✅ Store probe tokens in AWS Secrets Manager
resource "aws_secretsmanager_secret" "probe_tokens" {
  name        = "${var.secret_base_path}/probe-tokens"
  description = "Grafana probe registration tokens for ${var.grafanacloud_stack}"
  
  tags = {
    Environment = var.grafanacloud_stack
    Purpose     = "Grafana Probe Tokens"
    ManagedBy   = "Terraform"
  }
}

resource "aws_secretsmanager_secret_version" "probe_tokens" {
  secret_id = aws_secretsmanager_secret.probe_tokens.id
  
  secret_string = jsonencode(merge(
    local.tokens_to_store,
    {
      # Add metadata
      created_at    = timestamp()
      grafana_stack = var.grafanacloud_stack
      probe_count   = length(local.probes_list)
      # Store probe metadata for reference
      probe_metadata = {
        for i, probe in local.probes_list :
        "probe_${i}" => {
          city        = probe.city
          server_ip   = probe.server_ip
          environment = lookup(probe, "environment", var.grafanacloud_stack)
          probe_id    = grafana_synthetic_monitoring_probe.probes[i].id
        }
      }
    }
  ))
  
  lifecycle {
    # Don't recreate if only timestamp changes
    ignore_changes = [secret_string]
  }
}

# Deploy probes using stored tokens
resource "null_resource" "deploy_probe" {
  count = length(local.probes_list)

  triggers = {
    probe_config     = md5(jsonencode(local.probes_list[count.index]))
    tokens_version   = aws_secretsmanager_secret_version.probe_tokens.version_id
    script_hash      = filemd5("${path.module}/generate-compose.sh")
  }

  connection {
    type        = "ssh"
    user        = local.creds.ssh_user
    private_key = local.ssh_private_key
    host        = local.probes_list[count.index].server_ip
    timeout     = "5m"
  }

  provisioner "file" {
    source      = "${path.module}/generate-compose.sh"
    destination = "/tmp/generate-compose.sh"
  }

  # ✅ Pass AWS credentials and secret info to the script
  provisioner "remote-exec" {
    inline = [
      "chmod +x /tmp/generate-compose.sh",
      "echo '=== Starting deployment with AWS Secrets Manager integration at $(date) ===' | tee ~/deploy.log",
      # Pass AWS region and secret name to the script
      "AWS_REGION='${var.aws_region}' SECRET_NAME='${aws_secretsmanager_secret.probe_tokens.name}' /tmp/generate-compose.sh ${length(local.probes_list)} '${local.creds.proxy_user}' '${local.creds.proxy_password}' '${jsonencode(local.probes_with_tokens)}' 2>&1 | tee -a ~/deploy.log",
      "echo '=== Deployment finished at $(date) ===' | tee -a ~/deploy.log"
    ]
  }

  depends_on = [
    grafana_synthetic_monitoring_probe.probes,
    aws_secretsmanager_secret_version.probe_tokens
  ]
}