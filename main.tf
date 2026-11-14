# Configure the Azure provider
terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0.2"
    }
  }

  required_version = ">= 1.1.0"
}

provider "azurerm" {
  features {}
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
    source_address_prefix      = "10.0.1.0/24"
    destination_address_prefix = "10.0.2.0/24"
  }

  security_rule {
    name                       = "Deny-Internet-Inbound"
    priority                   = 200
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "Internet"
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "db-nsg-association" {
  subnet_id                 = azurerm_subnet.task-manager-private-subnet.id
  network_security_group_id = azurerm_network_security_group.nsg-db.id
}