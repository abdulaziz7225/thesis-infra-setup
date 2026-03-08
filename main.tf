terraform {
  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.60.1"
    }
  }
}

provider "hcloud" {}

data "hcloud_ssh_key" "default" {
  name = var.ssh_key_name
}

resource "hcloud_firewall" "k3s_firewall" {
  name = "k3s-research-firewall"

  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "22"
    source_ips = [var.admin_ip_cidr]
  }

  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "6443"
    source_ips = [var.admin_ip_cidr]
  }

  # Port 80 — reserved for HTTP ingress traffic during thesis experiment workloads
  # (WASM vs Docker microservice benchmarks exposed via k3s NodePort or a future ingress)
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "80"
    source_ips = ["0.0.0.0/0"]
  }

  # NodePort range — expose Grafana (32000) and Prometheus (32090) to admin only
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "30000-32767"
    source_ips = [var.admin_ip_cidr]
  }
}

resource "hcloud_server" "k3s_node" {
  name         = "thesis-wasm-node"
  image        = var.os_image
  server_type  = var.server_type
  location     = var.location
  ssh_keys     = [data.hcloud_ssh_key.default.id]
  firewall_ids = [hcloud_firewall.k3s_firewall.id]

  # Bootstrap script — stored in cloud-init.sh to avoid heredoc indentation issues
  # (Terraform <<-EOF strips tabs only, not spaces, which breaks the shebang)
  user_data = file("${path.module}/cloud-init.sh")
}

output "instance_public_ip" {
  value = hcloud_server.k3s_node.ipv4_address
}