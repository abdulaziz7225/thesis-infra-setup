variable "admin_ip_cidr" {
  description = "The CIDR block of the admin machine (e.g., '79.242.180.38/32')."
  type        = string
}

variable "ssh_key_name" {
  description = "The name of the SSH key uploaded to the Hetzner Cloud dashboard."
  type        = string
}

variable "server_type" {
  description = "The Hetzner server type (e.g., ccx23)"
  type        = string
}

variable "os_image" {
  description = "The base OS image (e.g., ubuntu-24.04)"
  type        = string
}

variable "location" {
  description = "The datacenter location (e.g., nbg1)"
  type        = string
}