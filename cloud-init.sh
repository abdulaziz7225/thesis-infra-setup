#!/bin/bash
exec > /var/log/thesis-setup.log 2>&1
set -ex

# 1. Fetch public IP from Hetzner metadata service
PUBLIC_IP=$(curl --retry 5 --retry-connrefused --retry-delay 2 -s \
  http://169.254.169.254/hetzner/v1/metadata/public-ipv4)

# 2. Install K3s (no traefik, TLS SAN for remote kubectl access)
curl -sfL https://get.k3s.io | \
INSTALL_K3S_VERSION="v1.35.2+k3s1" \
INSTALL_K3S_EXEC="server --disable traefik --tls-san $PUBLIC_IP" sh -

# 3. Configure k3s containerd to route the "spin" RuntimeClass through
#    containerd-shim-spin (installed in step 4). Pods with
#    runtimeClassName: wasmtime-spin are routed here. Spin embeds
#    Wasmtime/Cranelift as its Wasm execution engine.
mkdir -p /var/lib/rancher/k3s/agent/etc/containerd
cat > /var/lib/rancher/k3s/agent/etc/containerd/config.toml.tmpl << 'TMPL'
{{ template "base" . }}

[plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.spin]
  runtime_type = 'io.containerd.spin.v2'
TMPL

# 4. Install containerd-shim-spin for SpinKube (WASI P2 via Wasmtime/Cranelift).
#
# containerd-shim-spin implements the containerd shim v2 protocol directly and
# embeds the Spin runtime (Wasmtime). It runs Spin applications that export
# wasi:http/incoming-handler (WASI P2 Component Model).
SPIN_SHIM_VERSION="0.17.0"
SPIN_SHIM_TGZ=$(mktemp /tmp/containerd-shim-spin.XXXXXX.tar.gz)
curl -fsSL --retry 8 --retry-delay 5 --retry-connrefused --retry-all-errors \
  -o "${SPIN_SHIM_TGZ}" \
  "https://github.com/spinframework/containerd-shim-spin/releases/download/v${SPIN_SHIM_VERSION}/containerd-shim-spin-v2-linux-x86_64.tar.gz"
tar -xzf "${SPIN_SHIM_TGZ}" -C /usr/local/bin/
rm -f "${SPIN_SHIM_TGZ}"
chmod +x /usr/local/bin/containerd-shim-spin-v2
test -x /usr/local/bin/containerd-shim-spin-v2  # fail loudly if shim is missing

# 5. Restart k3s so containerd picks up the new runtime config
systemctl restart k3s
