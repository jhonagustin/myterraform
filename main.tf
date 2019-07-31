locals {
  virtual_machine_name = "${var.prefix}-vm"
  admin_username = "testadmin"
  admin_password = "Password1234!"
}


resource "azurerm_resource_group" "myterraform" {
  name     = "${var.prefix}-resources"
  location = "${var.location}"
}

resource "azurerm_virtual_network" "network" {
  name = "${var.prefix}-network"
  location = "${azurerm_resource_group.myterraform.location}"
  resource_group_name = "${azurerm_resource_group.myterraform.name}"
  address_space = ["10.0.0.0/16"]
}

resource "azurerm_subnet" "subnet" {
  name ="internal"
  resource_group_name ="${azurerm_resource_group.myterraform.name}"
  virtual_network_name = "${azurerm_virtual_network.network.name}"
  address_prefix = "10.0.2.0/24"  
}

resource "azurerm_public_ip" "publicip" {
  name = "${var.prefix}-publicip"
  resource_group_name ="${azurerm_resource_group.myterraform.name}"
  location = "${azurerm_resource_group.myterraform.location}"
  allocation_method = "Static"
}

resource "azurerm_network_interface" "nic" {
  name = "${var.prefix}-nic"
  location = "${azurerm_resource_group.myterraform.location}"
  resource_group_name = "${azurerm_resource_group.myterraform.name}"
  
  ip_configuration{
    name = "configuration"
    private_ip_address_allocation = "Static"
  }  
}



#certificates

data "azurerm_client_config" "current" {}

resource "azurerm_key_vault" "keyvault" {
  name                = "${var.prefix}-keyvault"
  location            = "${azurerm_resource_group.myterraform.location}"
  resource_group_name = "${azurerm_resource_group.myterraform.name}"
  tenant_id           = "${data.azurerm_client_config.current.tenant_id}"

  enabled_for_deployment          = true
  enabled_for_template_deployment = true

  sku_name = "standard"
  

  access_policy {
    tenant_id = "${data.azurerm_client_config.current.tenant_id}"
    object_id = "${data.azurerm_client_config.current.service_principal_object_id}"
  

    certificate_permissions = [
      "create",
      "delete",
      "get",
      "update",
    ]

    key_permissions    = []
    secret_permissions = []
  }
  
}

resource "azurerm_key_vault_certificate" "keyvault" {
  name      = "${local.virtual_machine_name}-cert"
  vault_uri = "${azurerm_key_vault.keyvault.vault_uri}"

  certificate_policy {
    issuer_parameters {
      name = "Self"
    }

    key_properties {
      exportable = true
      key_size   = 2048
      key_type   = "RSA"
      reuse_key  = true
    }

    lifetime_action {
      action {
        action_type = "AutoRenew"
      }

      trigger {
        days_before_expiry = 30
      }
    }

    secret_properties {
      content_type = "application/x-pkcs12"
    }

    x509_certificate_properties {
      # Server Authentication = 1.3.6.1.5.5.7.3.1
      # Client Authentication = 1.3.6.1.5.5.7.3.2
      extended_key_usage = ["1.3.6.1.5.5.7.3.1"]

      key_usage = [
        "cRLSign",
        "dataEncipherment",
        "digitalSignature",
        "keyAgreement",
        "keyCertSign",
        "keyEncipherment",
      ]

      subject            = "CN=${local.virtual_machine_name}"
      validity_in_months = 12
    }
  }
}
#VM
locals {
  custom_data_params  = "Param($ComputerName = \"${local.virtual_machine_name}\")"
  custom_data_content = "${local.custom_data_params} ${file("./files/winrm.ps1")}"
  
  }

resource "azurerm_virtual_machine" "vm" {
  name = "${local.virtual_machine_name}"
  location = "${azurerm_resource_group.myterraform.location}"
  resource_group_name ="${azurerm_resource_group.myterraform.name}"
  vm_size = "Standard_F2"
  network_interface_ids = ["${azurerm_network_interface.nic.id}"]

  delete_data_disks_on_termination = true

  storage_image_reference {
    publisher = "MicrosoftWindowsServer"
    offer = "WindowsServer"
    sku = "2016-Datacenter"
    version = "latest"
  }

  storage_os_disk {
    name = "${var.prefix}-osdisk"
    caching = "ReadWrite"
    create_option = "FromImage"
    managed_disk_type ="Standard_LRS"
  }

os_profile {
  computer_name = "${local.virtual_machine_name}"
  admin_username ="${local.admin_username}"
  admin_password ="${local.admin_password}"
  custom_data = "${local.custom_data_content}"
}

os_profile_secrets {
    source_vault_id = "${azurerm_key_vault.keyvault.id}"

    vault_certificates {
      certificate_url   = "${azurerm_key_vault_certificate.keyvault.secret_id}"
      certificate_store = "My"
    }
  }

  os_profile_windows_config {
    provision_vm_agent        = true
    enable_automatic_upgrades = true

    # Auto-Login's required to configure WinRM
    additional_unattend_config {
      pass         = "oobeSystem"
      component    = "Microsoft-Windows-Shell-Setup"
      setting_name = "AutoLogon"
      content      = "<AutoLogon><Password><Value>${local.admin_password}</Value></Password><Enabled>true</Enabled><LogonCount>1</LogonCount><Username>${local.admin_username}</Username></AutoLogon>"
    }

    # Unattend config is to enable basic auth in WinRM, required for the provisioner stage.
    additional_unattend_config {
      pass         = "oobeSystem"
      component    = "Microsoft-Windows-Shell-Setup"
      setting_name = "FirstLogonCommands"
      content      = "${file("./files/FirstLogonCommands.xml")}"
    }
  }

  provisioner "remote-exec" {
    connection {
      host = "${azurerm_public_ip.publicip.ip_address}"
      user     = "${local.admin_username}"
      password = "${local.admin_password}"
      port     = 5986
      https    = true
      timeout  = "10m"

      # NOTE: if you're using a real certificate, rather than a self-signed one, you'll want this set to `false`/to remove this.
      insecure = true
    }

    inline = [
      "cd C:\\Windows",
      "dir",
    ]
  }
}
