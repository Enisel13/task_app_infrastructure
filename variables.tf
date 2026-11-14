variable "resource_group_name" {
  default = "TaskManagerResourceGroup"
}

variable "vnet_name" {
    default = "TaskManagerVnet"
}

variable "mysql_admin_username" {
    description = "Administrator login for mysql server"
    type = string
    default = "mysqladmin"
}

variable "mysql_admin_password" {
    description = "Admin password for mysql server"
    type = string
    default = "H@Sh1CoR3!"
    #sensitive = true
}