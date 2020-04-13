terraform {
  required_providers {
    azurerm = ">= 2.0.0"
    tls     = "~> 2.1"
  }
}

provider "azurerm" {
  features {}
}

locals {
  ssh_key = lower(var.ssh_key_type) == "generated" ? tls_private_key.ssh[0].public_key_openssh : var.admin_ssh_key_data
}

resource "tls_private_key" "ssh" {
  count       = lower(var.ssh_key_type) == "generated" ? 1 : 0
  algorithm   = "RSA"
  ecdsa_curve = "2048"
}

data "azurerm_resource_group" "rg" {
  name = var.resource_group_name
}

resource "azurerm_virtual_network" "vnet" {
  address_space       = [var.address_space]
  location            = data.azurerm_resource_group.rg.location
  name                = format("%s-vnet", var.prefix)
  resource_group_name = data.azurerm_resource_group.rg.name
  tags                = var.tags
}

resource "azurerm_subnet" "subnet" {
  address_prefix       = var.address_space
  name                 = format("%s-subnet", var.prefix)
  resource_group_name  = data.azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
}

resource "azurerm_public_ip" "pip" {
  count               = var.load_balance ? 1 : 0
  location            = data.azurerm_resource_group.rg.location
  name                = format("%s-pip", var.prefix)
  resource_group_name = data.azurerm_resource_group.rg.name
  allocation_method   = "Static"
  sku                 = "Standard"
  domain_name_label   = format("%s-pip", var.prefix)
  tags                = var.tags
}

resource "azurerm_lb" "lb" {
  count               = var.load_balance ? 1 : 0
  location            = data.azurerm_resource_group.rg.location
  name                = format("%s-lb", var.prefix)
  resource_group_name = data.azurerm_resource_group.rg.name
  sku                 = "Standard"
  tags                = var.tags

  frontend_ip_configuration {
    name                 = format("%s-ip-config", var.prefix)
    public_ip_address_id = azurerm_public_ip.pip[count.index].id
  }
}

resource "azurerm_lb_backend_address_pool" "pool" {
  count               = var.load_balance ? 1 : 0
  loadbalancer_id     = azurerm_lb.lb[count.index].id
  name                = format("%s-backend-pool", var.prefix)
  resource_group_name = data.azurerm_resource_group.rg.name
}

resource "azurerm_lb_nat_pool" "natpool" {
  count                          = var.load_balance ? 1 : 0
  resource_group_name            = data.azurerm_resource_group.rg.name
  name                           = "ssh"
  loadbalancer_id                = azurerm_lb.lb[count.index].id
  protocol                       = "Tcp"
  frontend_port_start            = 50000
  frontend_port_end              = 50119
  backend_port                   = 22
  frontend_ip_configuration_name = azurerm_lb.lb[0].frontend_ip_configuration.0.name
}

resource "azurerm_lb_probe" "probe" {
  count               = var.load_balance ? 1 : 0
  name                = format("%s-lb-probe-port-%d", var.prefix, var.load_balancer_probe_port)
  resource_group_name = data.azurerm_resource_group.rg.name
  loadbalancer_id     = azurerm_lb.lb[0].id
  port                = var.load_balancer_probe_port
}

resource "azurerm_lb_rule" "lb_rule" {
  count                          = var.load_balance ? length(var.load_balanced_port_list) : 0
  resource_group_name            = data.azurerm_resource_group.rg.name
  loadbalancer_id                = azurerm_lb.lb[0].id
  probe_id                       = azurerm_lb_probe.probe[0].id
  name                           = format("%s-%02d-rule", var.prefix, count.index + 1)
  protocol                       = "Tcp"
  frontend_port                  = tostring(var.load_balanced_port_list[count.index])
  backend_port                   = tostring(var.load_balanced_port_list[count.index])
  frontend_ip_configuration_name = azurerm_lb.lb[0].frontend_ip_configuration.0.name
}

resource "azurerm_linux_virtual_machine_scale_set" "lin_vmss" {
  count               = var.flavour == "linux" || var.flavour == "lin" ? 1 : 0
  name                = format("%s-vmss", var.prefix)
  resource_group_name = data.azurerm_resource_group.rg.name
  location            = data.azurerm_resource_group.rg.location
  sku                 = var.vm_size
  instances           = var.instance_count
  admin_username      = var.admin_username
  tags                = var.tags

  admin_ssh_key {
    username   = var.admin_username
    public_key = local.ssh_key
  }

  source_image_reference {
    publisher = var.linux_distro_list[lower(var.linux_distro)]["publisher"]
    offer     = var.linux_distro_list[lower(var.linux_distro)]["offer"]
    sku       = var.linux_distro_list[lower(var.linux_distro)]["sku"]
    version   = var.linux_distro_list[lower(var.linux_distro)]["version"]
  }

  os_disk {
    storage_account_type = var.os_disk_storage_account_type
    caching              = "ReadWrite"
  }

  dynamic "data_disk" {
    for_each = var.additional_data_disk_capacity_list

    content {
      lun                  = data_disk.key
      disk_size_gb         = data_disk.value
      caching              = "ReadWrite"
      storage_account_type = var.additional_data_disk_storage_account_type
    }
  }

  network_interface {
    name    = format("%s-nic", var.prefix)
    primary = true

    ip_configuration {
      name      = format("%s-ipconfig", var.prefix)
      primary   = true
      subnet_id = azurerm_subnet.subnet.id

      load_balancer_backend_address_pool_ids = var.load_balance ? [azurerm_lb_backend_address_pool.pool[0].id] : null
      load_balancer_inbound_nat_rules_ids    = var.load_balance ? [azurerm_lb_nat_pool.natpool[0].id] : null
    }
  }
  # As noted in Terraform documentation https://www.terraform.io/docs/providers/azurerm/r/linux_virtual_machine_scale_set.html#load_balancer_backend_address_pool_ids
  depends_on = [azurerm_lb_rule.lb_rule]
}

resource "azurerm_windows_virtual_machine_scale_set" "win_vmss" {
  count               = var.flavour == "windows" || var.flavour == "win" ? 1 : 0
  name                = format("%s-vmss", var.prefix)
  resource_group_name = data.azurerm_resource_group.rg.name
  location            = data.azurerm_resource_group.rg.location
  sku                 = var.vm_size
  instances           = var.instance_count
  admin_username      = var.admin_username
  admin_password      = var.admin_password
  tags                = var.tags

  source_image_reference {
    publisher = var.win_distro_list[lower(var.win_distro)]["publisher"]
    offer     = var.win_distro_list[lower(var.win_distro)]["offer"]
    sku       = var.win_distro_list[lower(var.win_distro)]["sku"]
    version   = var.win_distro_list[lower(var.win_distro)]["version"]
  }

  os_disk {
    storage_account_type = var.os_disk_storage_account_type
    caching              = "ReadWrite"
  }

  dynamic "data_disk" {
    for_each = var.additional_data_disk_capacity_list

    content {
      lun                  = data_disk.key
      disk_size_gb         = data_disk.value
      caching              = "ReadWrite"
      storage_account_type = var.additional_data_disk_storage_account_type
    }
  }

  network_interface {
    name    = format("%s-nic", var.prefix)
    primary = true

    ip_configuration {
      name      = format("%s-ipconfig", var.prefix)
      primary   = true
      subnet_id = azurerm_subnet.subnet.id

      load_balancer_backend_address_pool_ids = [azurerm_lb_backend_address_pool.pool[0].id]
    }
  }
  # As noted in Terraform documentation https://www.terraform.io/docs/providers/azurerm/r/linux_virtual_machine_scale_set.html#load_balancer_backend_address_pool_ids
  depends_on = [azurerm_lb_rule.lb_rule]
}
