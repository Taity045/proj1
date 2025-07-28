variable "aws_region" {
  type        = string
  nullable    = false
  default     = "eu-central-1"
  description = "AWS region"
}

variable "grafanacloud_stack" {
  type        = string
  default     = "kmgroupdev"
  nullable    = false
  description = "Used to identify the stack to create on"
  validation {
    condition     = contains(["kmgroupdev", "kmgroup", "kmgroupemeaint", "kmgroupplayground"], var.grafanacloud_stack)
    error_message = "The Grafana Cloud stack name needs to be one of 'kmgroupdev', 'kmgroup', 'kmgroupemeaint', 'kmgroupplayground'."
  }
}

variable "secret_base_path" {
  type        = string
  nullable    = false
  description = "Base path for secrets in AWS Secrets Manager"
  validation {
    condition     = can(regex("^internal/grafana-cloud-.+/private-probe", var.secret_base_path))
    error_message = "The secret base path must start with 'internal/grafana-cloud-<ENV>/private-probe'."
  }
}
