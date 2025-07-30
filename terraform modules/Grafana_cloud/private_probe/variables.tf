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
    error_message = "Secret base path must follow pattern: internal/grafana-cloud-<ENV>/private-probe"
  }
}

# ✅ NEW: Variable to control whether to use existing tokens
variable "use_existing_tokens" {
  type        = bool
  default     = false
  description = "Whether to use existing tokens from Secrets Manager or create new ones"
}

variable "monitoring_agent_image" {
  type        = string
  description = "Docker image for Grafana synthetic monitoring agent"
  default     = "nexus.kmgroup.net/grafana/synthetic-monitoring-agent:v0.38.0"
}

variable "proxy_server" {
  type        = string
  description = "Proxy server address"
  default     = "proxy.muc:8080"
}
