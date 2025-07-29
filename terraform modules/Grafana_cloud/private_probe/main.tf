# Decode and extract the correct stack credentials
locals {
  creds           = jsondecode(data.aws_secretsmanager_secret_version.on_prem_secret_version.secret_string)
  probes_list     = jsondecode(data.aws_secretsmanager_secret_version.probe_config_version.secret_string).probes
  ssh_private_key = data.aws_secretsmanager_secret_version.ssh_key_version.secret_string
}

# Create Grafana synthetic monitoring probes
resource "grafana_synthetic_monitoring_probe" "probes" {
  count = length(local.probes_list)

  name      = "${local.probes_list[count.index].city}, ${local.probes_list[count.index].stack} on-prem ${count.index}"
  latitude  = local.probes_list[count.index].latitude
  longitude = local.probes_list[count.index].longitude
  region    = local.probes_list[count.index].region
}

# Deploy the probes using the generated compose file
resource "null_resource" "deploy_probe" {
  count = length(local.probes_list)

  provisioner "file" {
    connection {
      type        = "ssh"
      user        = local.creds.ssh_user  # Use the retrieved SSH user
      private_key = local.ssh_private_key # Use the retrieved SSH private key
      host        = local.probes_list[count.index].server_ip
    }

    source      = abspath("${path.module}/generate_compose.sh")
    destination = "/tmp/generate_compose.sh"
  }

  provisioner "remote-exec" {
    connection {
      type        = "ssh"
      user        = local.creds.ssh_user  # Use the retrieved SSH user
      private_key = local.ssh_private_key # Use the retrieved SSH private key
      host        = local.probes_list[count.index].server_ip
    }

    inline = [
      "chmod +x /tmp/generate_compose.sh",
      "echo '--- Starting deployment at $(date) ---' > ~/deploy.log",
      "/tmp/generate_compose.sh ${length(local.probes_list)} '${local.creds.proxy_user}' '${local.creds.proxy_password}' '${jsonencode(local.probes_list)}' >> ~/deploy.log 2>&1",
      "echo '--- Deployment finished at $(date) ---' >> ~/deploy.log"
    ]
  }

  # Ensure this runs after the Grafana probe has been created
  depends_on = [grafana_synthetic_monitoring_probe.probes]
}