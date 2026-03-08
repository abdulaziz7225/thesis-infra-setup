#!/bin/bash
exec > /var/log/thesis-setup.log 2>&1
set -ex

# 1. Fetch public IP from Hetzner metadata service
PUBLIC_IP=$(curl --retry 5 --retry-connrefused --retry-delay 2 -s \
  http://169.254.169.254/hetzner/v1/metadata/public-ipv4)

# 2. Install K3s (no traefik, TLS SAN for remote kubectl access)
curl -sfL https://get.k3s.io | \
INSTALL_K3S_EXEC="server --disable traefik --tls-san $PUBLIC_IP" sh -

# 3. Install WasmEdge host libraries system-wide
curl -sSf https://raw.githubusercontent.com/WasmEdge/WasmEdge/master/utils/install.sh \
  | bash -s -- -p /usr/local
ldconfig

# 4. Install the containerd-shim-wasmedge binary
wget -q https://github.com/containerd/runwasi/releases/download/containerd-shim-wasmedge%2Fv0.6.0/containerd-shim-wasmedge-x86_64-linux-musl.tar.gz \
  -O /tmp/shim.tar.gz
tar -xf /tmp/shim.tar.gz -C /tmp/
cp /tmp/containerd-shim-wasmedge-v1 /bin/containerd-shim-wasmedge-v1
chmod +x /bin/containerd-shim-wasmedge-v1
rm -f /tmp/shim.tar.gz /tmp/containerd-shim-wasmedge-v1 /tmp/containerd-shim-wasmedge-v1.sig /tmp/containerd-shim-wasmedge-v1.pem

# 5. Restart k3s so it picks up the new containerd shim
# (k3s v1.34+ auto-detects the shim binary; no manual containerd config template needed)
systemctl restart k3s
