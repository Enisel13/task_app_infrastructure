# Configure the Azure provider
terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
  }

  required_version = ">= 1.1.0"
}

provider "azurerm" {
  features {
    # Enable soft delete and purge protection for Key Vaults
    #Трябва ми за да може да се създаде secret в key vault-a и да се използва от AKS
    key_vault {
      purge_soft_delete_on_destroy    = true
      recover_soft_deleted_key_vaults = true
    }
  }
}

resource "azurerm_resource_group" "rg" {
  name     = var.resource_group_name
  location = "northeurope"
}

# Create a virtual network
resource "azurerm_virtual_network" "vnet" {
  name                = var.vnet_name
  address_space       = ["10.0.0.0/16"]
  location            = "northeurope"
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_subnet" "task-manager-public-subnet" {
  name                 = "task-manager-subnet-public"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.1.0/24"]
}

resource "azurerm_subnet" "task-manager-private-subnet" {
  name                 = "task-manager-subnet-private"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.2.0/24"]

  delegation {
    name = "fs"
    service_delegation {
      name = "Microsoft.DBforMySQL/flexibleServers"
      actions = [
        "Microsoft.Network/virtualNetworks/subnets/join/action",
      ]
    }
  }
}

#Създава private dns url за да може application-a да се връзвa с базата 
resource "azurerm_private_dns_zone" "task-manager-private-dns-zone" {
  name                = "task-manager-private-dns-zone.mysql.database.azure.com"
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_private_dns_zone_virtual_network_link" "task-manager-private-dns-zone-virtual-network-link" {
  name                  = "mysql-dns-link"
  private_dns_zone_name = azurerm_private_dns_zone.task-manager-private-dns-zone.name
  virtual_network_id    = azurerm_virtual_network.vnet.id
  resource_group_name   = azurerm_resource_group.rg.name
}


#Това е managed услуга в самия azure (managed mysql database) azure поддържа базата и azure се грижи да е up and running
#тук живее базата

resource "azurerm_mysql_flexible_server" "task-manager-server" {
    name                   = "task-manager-mysql-flexible-server"
    resource_group_name    = azurerm_resource_group.rg.name
    location               = azurerm_resource_group.rg.location
    administrator_login    = var.mysql_admin_username
    administrator_password = var.mysql_admin_password
    sku_name               = "GP_Standard_D2ds_v4"
    zone                   = "2"
    private_dns_zone_id    = azurerm_private_dns_zone.task-manager-private-dns-zone.id

    #създавам базата в private sybnet-а
    delegated_subnet_id = azurerm_subnet.task-manager-private-subnet.id

    storage {
        size_gb = 20
    }

    #първо трябва да се създаде url за да може да се свързва
    depends_on = [azurerm_private_dns_zone_virtual_network_link.task-manager-private-dns-zone-virtual-network-link]
}

#самата база която е в azurerm_mysql_flexible_server
resource "azurerm_mysql_flexible_database" "task-manager-database" {
  name                = "tasks_db"
  resource_group_name = azurerm_resource_group.rg.name
  server_name         = azurerm_mysql_flexible_server.task-manager-server.name
  charset             = "utf8"
  collation           = "utf8_unicode_ci"
}

#Създавам Security group които да определят inbound and outbound трафик
resource "azurerm_network_security_group" "nsg-db" {
  name                = "nsg-db"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  security_rule {
    name                       = "Allow-MySQL-from-AKS"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "3306"
    source_address_prefix      = "10.0.1.0/24" // Allow traffic from the AKS public subnet 
    destination_address_prefix = "10.0.2.0/24" // Allow traffic to the MySQL private subnet 
  }

  security_rule {
    name                       = "Deny-Internet-Inbound"
    priority                   = 200
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "Internet" // Deny all inbound traffic from the internet
    destination_address_prefix = "*"        // Deny all inbound traffic to any destination
  }
}

resource "azurerm_subnet_network_security_group_association" "db-nsg-association" {
  subnet_id                 = azurerm_subnet.task-manager-private-subnet.id
  network_security_group_id = azurerm_network_security_group.nsg-db.id
}

resource "azurerm_kubernetes_cluster" "aks" {
  name                = "aks-non-prod"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  dns_prefix          = "task-manager"
  oidc_issuer_enabled = true
  workload_identity_enabled = true
  key_vault_secrets_provider {
    secret_rotation_enabled = true
  }
  default_node_pool {
    name       = "system"
    node_count = 1
    vm_size    = "Standard_B2s_v2"
    vnet_subnet_id = azurerm_subnet.task-manager-public-subnet.id
  }

  identity {
    type = "SystemAssigned"
  }

  network_profile {
    network_plugin     = "azure"
    load_balancer_sku  = "standard"
    service_cidr       = "10.1.0.0/16"  // Service CIDR for the AKS cluster (to learn more bout it)
    dns_service_ip     = "10.1.0.10" // DNS service IP within the service CIDR
  }
}

resource "azurerm_container_registry" "acr" {
  name                = "containerRegistryTaskManager"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  sku                 = "Basic"
  admin_enabled       = false
}

#да може AKS да pull-ва images от ACR
#(Attaching a Container Registry to a Kubernetes Cluster)
resource "azurerm_role_assignment" "aks-acr-role-assignment" {
  principal_id                     = azurerm_kubernetes_cluster.aks.kubelet_identity[0].object_id
  role_definition_name             = "AcrPull"
  scope                            = azurerm_container_registry.acr.id
  skip_service_principal_aad_check = true
}

#Кey vault за да може да се съхраняват secrets и да се използват от AKS
data "azurerm_client_config" "current" {}

resource "azurerm_key_vault" "task-manager-key-vault" {
  name                        = "taskmanagerekeyvault"
  location                    = azurerm_resource_group.rg.location
  resource_group_name         = azurerm_resource_group.rg.name
  enable_rbac_authorization   = true
  tenant_id                   = data.azurerm_client_config.current.tenant_id

  sku_name = "standard"
}

#нещо като приложението да има карта за да може да се свързва с key vault-a и да взима secrets от него
resource "azurerm_user_assigned_identity" "app" {
  name                = "task-manager-app-identity"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
}
 
resource "azurerm_federated_identity_credential" "app" {
  name                = "task-manager-app-fic"
  resource_group_name = azurerm_resource_group.rg.name
  parent_id           = azurerm_user_assigned_identity.app.id
 
  audience = ["api://AzureADTokenExchange"]
  issuer   = azurerm_kubernetes_cluster.aks.oidc_issuer_url
  subject  = "system:serviceaccount:default:default"
}
 
#дава права на приложението да чете secrets от key vault-a
resource "azurerm_role_assignment" "app_kv_reader" {
  scope                = azurerm_key_vault.task-manager-key-vault.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.app.principal_id
}

output "app_identity_client_id" {
  value = azurerm_user_assigned_identity.app.client_id
}

output "mysql_fqdn" {
  value = azurerm_mysql_flexible_server.task-manager-server.fqdn
}

output "kv_name" {
  value = azurerm_key_vault.task-manager-key-vault.name
}

output "tenant_id" {
  value = data.azurerm_client_config.current.tenant_id
}