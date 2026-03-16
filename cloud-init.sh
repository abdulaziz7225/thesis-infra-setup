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

# 3. Install WasmEdge host libraries system-wide
curl -sSf https://raw.githubusercontent.com/WasmEdge/WasmEdge/master/utils/install.sh \
  | bash -s -- --version 0.14.1 -p /usr/local
echo "/usr/local/lib" > /etc/ld.so.conf.d/wasmedge.conf
ldconfig

# 4. Build crun with WasmEdge support.
# crun is the OCI runtime that delegates WASM modules to the system WasmEdge
# (installed in step 3). This is WasmEdge's documented approach for networking:
# the runwasi musl-static shim bundles its own WasmEdge without socket support.
apt-get update -y
apt-get install -y make gcc build-essential pkgconf libtool \
  libsystemd-dev libcap-dev libseccomp-dev libyajl-dev autoconf automake go-md2man

CRUN_VERSION="1.22"
git clone --depth=1 --branch "${CRUN_VERSION}" \
  https://github.com/containers/crun.git /tmp/crun
cd /tmp/crun
./autogen.sh
./configure --with-wasmedge --prefix=/usr/local
make -j"$(nproc)"
make install
cd / && rm -rf /tmp/crun

# 5. Configure k3s containerd to route the "wasmedge" RuntimeClass through crun.
# crun auto-detects WASM modules via the module.wasm.image/variant annotation
# and delegates execution to libwasmedge.so (system WasmEdge 0.14.1).
mkdir -p /var/lib/rancher/k3s/agent/etc/containerd
cat > /var/lib/rancher/k3s/agent/etc/containerd/config.toml.tmpl << 'TMPL'
{{ template "base" . }}

[plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.wasmedge]
  runtime_type = 'io.containerd.runc.v2'
  # Forward these pod annotations into the OCI spec so crun can read them.
  # Without this, crun never sees run.oci.handler and falls back to native exec.
  pod_annotations       = ["run.oci.handler", "module.wasm.image/variant"]
  container_annotations = ["run.oci.handler", "module.wasm.image/variant"]

[plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.wasmedge.options]
  BinaryName = '/usr/local/bin/crun'
TMPL

# 6. Restart k3s so containerd picks up the new runtime config
systemctl restart k3s
