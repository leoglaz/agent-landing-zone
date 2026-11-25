# Offline deployment selection: Foundry agents with models supplied by a gateway.
mock_provider "azurerm" {
  mock_data "azurerm_client_config" {
    defaults = {
      tenant_id       = "00000000-0000-0000-0000-000000000002"
      subscription_id = "00000000-0000-0000-0000-000000000001"
      object_id       = "00000000-0000-0000-0000-000000000003"
      client_id       = "00000000-0000-0000-0000-000000000004"
    }
  }
}
mock_provider "azapi" {}
mock_provider "random" {}
mock_provider "modtm" {}
mock_provider "time" {}

run "foundry_agents_with_external_models" {
  command = plan

  variables {
    subscriptionId                             = "00000000-0000-0000-0000-000000000001"
    tenantId                                   = "00000000-0000-0000-0000-000000000002"
    principalId                                = "00000000-0000-0000-0000-000000000003"
    environmentName                            = "dev"
    resourceGroupName                          = "rg-foundry-agents"
    location                                   = "canadaeast"
    createResourceGroup                        = true
    deployModelDeployments                     = false
    deployContainerApps                        = false
    deployContainerEnv                         = false
    networkIsolation                           = true
    useExistingVNet                            = false
    privateEndpointLocation                    = "canadaeast"
    deploySubnets                              = true
    deployAiFoundrySubnet                      = true
    deploymentMode                             = "standalone"
    deployAzureFirewall                        = false
    hubIntegrationExistingRouteTableResourceId = "/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/rg-network/providers/Microsoft.Network/routeTables/rt-existing"
    deployAcrTaskAgentPool                     = false
    deployJumpbox                              = false
    deployBastion                              = false
    deployNatGateway                           = false
  }

  assert {
    condition = (
      length(azapi_resource.model_deployment) == 0 &&
      length(azurerm_container_app.shell) == 0 &&
      length(azapi_resource.container_environment) == 0 &&
      length(output.DEPLOYMENT_METADATA.modelDeployments) == 0 &&
      length(output.DEPLOYMENT_METADATA.containerApps) == 0 &&
      !output.DEPLOY_CONTAINER_APPS && !output.DEPLOY_CONTAINER_ENV
    )
    error_message = "The Foundry-only selection must not deploy local models, Container Apps or their environment."
  }

  assert {
    condition = (
      length(azapi_resource.foundry_account) == 1 &&
      length(azapi_resource.foundry_project) == 1 &&
      local.services_agent_service &&
      alltrue(values(local.services_foundry_owned)) &&
      length(azurerm_resource_group.managed) == 1 &&
      var.deployContainerRegistry
    )
    error_message = "Foundry, Agent Service dependencies and workload group ownership must remain enabled without changing unrelated service selections."
  }

  assert {
    condition = (
      length(module.network_vnet) == 1 &&
      length(data.azapi_resource.network_existing_subnet) == 0 &&
      length(local.managed_subnets) > 0 &&
      length(module.network_firewall) == 0 &&
      length(module.network_firewall_policy) == 0 &&
      length(module.network_public_ip) == 0 &&
      length(module.network_route_table) == 0 &&
      length(azapi_resource.network_default_route) == 0 &&
      length(local.private_endpoints) > 0 &&
      local.foundry_agent_network_injection &&
      local.effective_locations.main == "canadaeast" &&
      local.effective_locations.private_endpoint == "canadaeast" &&
      alltrue([for endpoint in values(local.private_endpoints) : endpoint.location == "canadaeast"]) &&
      local.managed_subnets.pe.name != local.managed_subnets.applicationPe.name &&
      contains(local.managed_subnets.agent.service_endpoints, "Microsoft.CognitiveServices") &&
      contains(local.managed_subnets.pe.service_endpoints, "Microsoft.AzureCosmosDB") &&
      contains(local.managed_subnets.applicationPe.service_endpoints, "Microsoft.AzureCosmosDB") &&
      alltrue([for purpose, subnet in local.managed_subnets : subnet.route_table_id == var.hubIntegrationExistingRouteTableResourceId if contains(["agent", "pe", "jumpbox", "acaEnvironment", "devopsBuildAgents", "applicationPe"], purpose)]) &&
      !contains(keys(local.managed_subnets), "firewall") &&
      !contains(keys(local.managed_subnets), "firewallManagement") &&
      local.public_access.public_network_access == "Disabled" &&
      !local.effective_flags.jumpbox && !local.effective_flags.bastion &&
      !local.effective_flags.nat && !local.effective_flags.acr_pool
    )
    error_message = "The private Foundry deployment must use declared external routing without creating a firewall, public IP or route table; public service access must remain disabled."
  }
}
