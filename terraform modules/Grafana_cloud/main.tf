# Have to import the provider if already existing as it's one per account and not per stack
# import {
#   id = "arn:aws:iam::${var.aws_account}:oidc-provider/atc-github.azure.cloud.km/_services/token"
#   to   = module.aws-gh-oidc[0].aws_iam_openid_connect_provider.atc_github
# }

module "aws-gh-oidc" {
  source = "./aws-gh-oidc"
  count  = var.aws_account == null ? 0 : 1

  aws_account        = var.aws_account
  grafanacloud_stack = var.grafanacloud_stack

  # Default these temporarily until we confirm the module structure
  github_organisation = "Operations-Management"
  github_repositories = ["APM_Grafana_Cloud"]
}

module "private_probe" {
  source             = "./private_probe"
  aws_region         = var.aws_region
  grafanacloud_stack = var.grafanacloud_stack
  secret_base_path   = var.private_probe_secret_base_path
}