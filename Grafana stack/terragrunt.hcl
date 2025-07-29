include "root" {
  path = find_in_parent_folders("root.hcl")
}

locals {
  common  = read_terragrunt_config(find_in_parent_folders("common.hcl"))
  stack   = read_terragrunt_config(find_in_parent_folders("stack.hcl"))
  account = read_terragrunt_config("../aws/account.hcl")

  # These two variables reference the same inputs, is thie by design?
  common_inputs  = local.common.locals.grafanacloud.inputs
  inputs         = local.common.locals.grafanacloud.inputs
  stack_inputs   = local.stack.locals
  account_inputs = local.account.locals

  teams = read_terragrunt_config("teams.hcl")

  source = "../../terraform-modules/grafanacloud"
  # TODO when we'll define the module in a separate repo and with proper version/release tags
  # source_version = "" # normally defined in common.hcl but can be overridden here if needed
  # source_url = format(
  #   "", # "%s"
  #   local.common.locals.grafanacloud.source_url,
  #   coalesce(
  #     local.source,
  #     local.common.locals.grafanacloud.source_version
  #   )
  # )
}

terraform {
  source = local.source
}

# Due its size, the teams configuration is generated in a separate file
# If this is passed normally we run into the argument limits for Terragrunt
generate "teams_vars" {
  path      = "teams_config.auto.tfvars.json"
  if_exists = "overwrite"
  contents = jsonencode(
    { teams_config = local.teams.locals.teams_config }
  )

  #Signature needs to be disabled for valid JSON
  disable_signature = true
}

inputs = merge(
  local.common,
  local.stack_inputs,
  local.common_inputs,
  local.account_inputs,
  local.inputs,
  # and now the actual input to be added to the inherited ones:
  {
    prometheus_datasource_uid      = "grafanacloud-prom",
    private_probe_secret_base_path = "internal/grafana-cloud-test/private-probe"
    roles_config                   = try(yamldecode(file("${get_terragrunt_dir()}/roles.yaml")), {})
    global_contact_points          = try(yamldecode(file("./contact-points.yaml")), {})
    fleet_management_remote_configurations = [
      {
        name = "linux_node_linux_to_grafana_cloud_test_collector"
        file = "fleet_management_pipelines/linux_node_linux_to_grafana_cloud_test_collector.alloy"
        matchers = [
          "collector.os=~\"linux\"",
        ],
        enabled = true
      },
      {
        name = "self_monitoring_logs_linux_to_grafana_cloud_test_collector"
        file = "fleet_management_pipelines/self_monitoring_logs_linux_to_grafana_cloud_test_collector.alloy"
        matchers = [
          "collector.os=~\"linux\"",
          "platform!=\"kubernetes\""
        ],
        enabled = true
      },
      {
        name = "windows_exporter_windows_to_grafana_cloud_test_collector"
        file = "fleet_management_pipelines/windows_exporter_windows_to_grafana_cloud_test_collector.alloy"
        matchers = [
          "km_appd_env_class=\"TEST\"",
          "km_region=\"eu-central-1\"",
          "collector.os=\"windows\""
        ],
        enabled = true
      },
      {
        name = "receive_otlp_and_send_to_grafana_cloud_test_collector"
        file = "fleet_management_pipelines/receive_otlp_and_send_to_grafana_cloud_test_collector.alloy"
        matchers = [
          "km_appd_env_class=\"TEST\"",
          "km_region=\"eu-central-1\"",
          "receive_otlp=\"true\"",
          "platform!=\"kubernetes\""
        ],
        enabled = true
      }
    ]
  }
)