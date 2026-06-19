terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
  }
}

provider "azurerm" {
  features {}
}

#Resource Group
resource "azurerm_resource_group" "lab" {
  name     = "rg-ailab-${var.participant_name}"
  location = var.location
  tags = {
    owner = "sathish"
  }
}

#Virtual Network
resource "azurerm_virtual_network" "lab" {
  name                = "vnet-ailab"
  address_space       = ["10.0.0.0/16"]
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  tags = {
    owner = "sathish"
  }
}

#Subnets
resource "azurerm_subnet" "app" {
  name                 = "snet-app"
  resource_group_name  = azurerm_resource_group.lab.name
  virtual_network_name = azurerm_virtual_network.lab.name
  address_prefixes     = ["10.0.1.0/24"]
}

resource "azurerm_subnet" "db" {
  name                 = "snet-db"
  resource_group_name  = azurerm_resource_group.lab.name
  virtual_network_name = azurerm_virtual_network.lab.name
  address_prefixes     = ["10.0.2.0/24"]
}

resource "azurerm_subnet" "bastion" {
  name                 = "AzureBastionSubnet"
  resource_group_name  = azurerm_resource_group.lab.name
  virtual_network_name = azurerm_virtual_network.lab.name
  address_prefixes     = ["10.0.3.0/27"]
}

#NSGs — NOTE: intentional security issues for Lab 1 AI review exercise
resource "azurerm_network_security_group" "app" {
  name                = "nsg-app"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name

  security_rule {
    name                       = "AllowSSH"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "10.0.3.0/27"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "AllowRDP"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "3389"
    source_address_prefix      = "10.0.3.0/27"
    destination_address_prefix = "*"
  }
  tags = {
    owner = "sathish"
  }
}

resource "azurerm_network_security_group" "db" {
  name                = "nsg-db"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name

  security_rule {
    name                       = "AllowPostgres"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "5432"
    source_address_prefix      = "10.0.1.0/24"
    destination_address_prefix = "*"
  }
  tags = {
    owner = "sathish"
  }
}

#NSG Associations
resource "azurerm_subnet_network_security_group_association" "app" {
  subnet_id                 = azurerm_subnet.app.id
  network_security_group_id = azurerm_network_security_group.app.id
}

resource "azurerm_subnet_network_security_group_association" "db" {
  subnet_id                 = azurerm_subnet.db.id
  network_security_group_id = azurerm_network_security_group.db.id
}

#Azure Bastion
resource "azurerm_public_ip" "bastion" {
  name                = "pip-bastion"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags = {
    owner = "sathish"
  }
}

resource "azurerm_bastion_host" "lab" {
  name                = "bastion-ailab"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  sku                 = "Basic"

  ip_configuration {
    name                 = "configuration"
    subnet_id            = azurerm_subnet.bastion.id
    public_ip_address_id = azurerm_public_ip.bastion.id
  }
  tags = {
    owner = "sathish"
  }
}

#Network Interfaces
resource "azurerm_network_interface" "app" {
  name                = "nic-app"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.app.id
    private_ip_address_allocation = "Static"
    private_ip_address            = "10.0.1.10"
  }
  tags = {
    owner = "sathish"
  }
}

resource "azurerm_network_interface" "db" {
  name                = "nic-db"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.db.id
    private_ip_address_allocation = "Static"
    private_ip_address            = "10.0.2.10"
  }
  tags = {
    owner = "sathish"
  }
}

resource "azurerm_network_interface" "win" {
  name                = "nic-win"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.app.id
    private_ip_address_allocation = "Static"
    private_ip_address            = "10.0.1.20"
  }
  tags = {
    owner = "sathish"
  }
}

#Virtual Machines
resource "azurerm_linux_virtual_machine" "app" {
  name                            = "vm-app"
  resource_group_name             = azurerm_resource_group.lab.name
  location                        = azurerm_resource_group.lab.location
  size                            = "Standard_B2ms"
  admin_username                  = "labadmin"
  admin_password                  = var.admin_password
  disable_password_authentication = false
  network_interface_ids           = [azurerm_network_interface.app.id]
  custom_data                     = base64encode(file("${path.module}/cloud-init-app.yaml"))
  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
    disk_size_gb         = 30
  }
  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }
  boot_diagnostics {
    storage_account_uri = azurerm_storage_account.lab.primary_blob_endpoint
  }
  tags = {
    owner = "sathish"
  }
}

resource "azurerm_linux_virtual_machine" "db" {
  name                            = "vm-db"
  resource_group_name             = azurerm_resource_group.lab.name
  location                        = azurerm_resource_group.lab.location
  size                            = "Standard_B2ms"
  admin_username                  = "labadmin"
  admin_password                  = var.admin_password
  disable_password_authentication = false
  network_interface_ids           = [azurerm_network_interface.db.id]
  custom_data                     = base64encode(file("${path.module}/cloud-init-db.yaml"))
  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
    disk_size_gb         = 30
  }
  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }
  boot_diagnostics {
    storage_account_uri = azurerm_storage_account.lab.primary_blob_endpoint
  }
  tags = {
    owner = "sathish"
  }
}

resource "azurerm_windows_virtual_machine" "win" {
  name                  = "vm-win"
  resource_group_name   = azurerm_resource_group.lab.name
  location              = azurerm_resource_group.lab.location
  size                  = "Standard_B2s"
  admin_username        = "labadmin"
  admin_password        = var.admin_password
  network_interface_ids = [azurerm_network_interface.win.id]
  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
    disk_size_gb         = 128
  }
  source_image_reference {
    publisher = "MicrosoftWindowsServer"
    offer     = "WindowsServer"
    sku       = "2022-datacenter-azure-edition"
    version   = "latest"
  }
  boot_diagnostics {
    storage_account_uri = azurerm_storage_account.lab.primary_blob_endpoint
  }
  tags = {
    owner = "sathish"
  }
}

#Storage Account
resource "azurerm_storage_account" "lab" {
  name                     = "stailab${var.participant_name}"
  resource_group_name      = azurerm_resource_group.lab.name
  location                 = azurerm_resource_group.lab.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  account_kind             = "StorageV2"
  access_tier              = "Hot"
  blob_properties {
    delete_retention_policy {
      days = 30
    }
    container_delete_retention_policy {
      days = 30
    }
  }
  tags = {
    owner = "sathish"
  }
}

#Auto-shutdown schedules
resource "azurerm_dev_test_global_vm_shutdown_schedule" "app" {
  virtual_machine_id    = azurerm_linux_virtual_machine.app.id
  location              = azurerm_resource_group.lab.location
  enabled               = true
  daily_recurrence_time = "0800"
  timezone              = "UTC"
  notification_settings { enabled = false }
  tags = {
    owner = "sathish"
  }
}

resource "azurerm_dev_test_global_vm_shutdown_schedule" "db" {
  virtual_machine_id    = azurerm_linux_virtual_machine.db.id
  location              = azurerm_resource_group.lab.location
  enabled               = true
  daily_recurrence_time = "0800"
  timezone              = "UTC"
  notification_settings { enabled = false }
  tags = {
    owner = "sathish"
  }
}

resource "azurerm_dev_test_global_vm_shutdown_schedule" "win" {
  virtual_machine_id    = azurerm_windows_virtual_machine.win.id
  location              = azurerm_resource_group.lab.location
  enabled               = true
  daily_recurrence_time = "0800"
  timezone              = "UTC"
  notification_settings { enabled = false }
  tags = {
    owner = "sathish"
  }
}
