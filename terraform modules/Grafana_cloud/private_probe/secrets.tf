#Retrieve SSH private key
data "aws_secretsmanager_secret" "ssh_key" {
  name = "${var.secret_base_path}/ssh"
}

data "aws_secretsmanager_secret_version" "ssh_key_version" {
  secret_id = data.aws_secretsmanager_secret.ssh_key.id
}

# Retrieve SSH user and proxy credentials
data "aws_secretsmanager_secret" "on_prem_secret" {
  name = "${var.secret_base_path}/users"
}

data "aws_secretsmanager_secret_version" "on_prem_secret_version" {
  secret_id = data.aws_secretsmanager_secret.on_prem_secret.id
}

# Retrieve probe config list
data "aws_secretsmanager_secret" "probe_config" {
  name = "${var.secret_base_path}/probe-config"
}

data "aws_secretsmanager_secret_version" "probe_config_version" {
  secret_id = data.aws_secretsmanager_secret.probe_config.id
}

# Retrieve the Grafana service account secret
data "aws_secretsmanager_secret" "grafana_service_account" {
  name = "${var.secret_base_path}/stack-sa-account"
}

data "aws_secretsmanager_secret_version" "grafana_service_account_version" {
  secret_id = data.aws_secretsmanager_secret.grafana_service_account.id
}

# ✅ NEW: Data source to retrieve stored probe tokens (optional, for existing tokens)
data "aws_secretsmanager_secret" "probe_tokens" {
  count = var.use_existing_tokens ? 1 : 0
  name  = "${var.secret_base_path}/probe-tokens"
}

data "aws_secretsmanager_secret_version" "probe_tokens_version" {
  count     = var.use_existing_tokens ? 1 : 0
  secret_id = data.aws_secretsmanager_secret.probe_tokens[0].id
}
