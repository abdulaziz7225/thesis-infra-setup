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

# 3. (Optional) Install WasmEdge host libraries system-wide.
#    Set ENABLE_WASMEDGE=true to enable the WASI P1 optional comparison variants.
#    Skip this by default — SpinKube (WASI P2) does not require WasmEdge.
if [ "${ENABLE_WASMEDGE:-false}" = "true" ]; then
  curl -sSf https://raw.githubusercontent.com/WasmEdge/WasmEdge/master/utils/install.sh \
    | bash -s -- --version 0.14.1 -p /usr/local
  echo "/usr/local/lib" > /etc/ld.so.conf.d/wasmedge.conf
  ldconfig
fi

# 4. (Optional) Build crun with WasmEdge support.
#    crun is the OCI runtime that delegates WASM modules to the system WasmEdge
#    (installed in step 3). Required only for the optional WasmEdge WASI P1 variants.
#    The runwasi musl-static shim bundles its own WasmEdge without socket support —
#    this custom crun build is necessary to enable networking.
if [ "${ENABLE_WASMEDGE:-false}" = "true" ]; then
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
fi

# 5. Configure k3s containerd to route the "spin" RuntimeClass through
#    containerd-shim-spin (step 6 — primary default Wasm runtime).
#    The optional "wasmedge" RuntimeClass block is appended only when
#    ENABLE_WASMEDGE=true.
mkdir -p /var/lib/rancher/k3s/agent/etc/containerd
cat > /var/lib/rancher/k3s/agent/etc/containerd/config.toml.tmpl << 'TMPL'
{{ template "base" . }}

# SpinKube: containerd-shim-spin (installed in step 6) uses Wasmtime/Cranelift
# internally — DIFFERENT from WasmEdge. Pods with runtimeClassName: wasmtime-spin
# are routed here. This is the primary Wasm runtime for this thesis.
[plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.spin]
  runtime_type = 'io.containerd.spin.v2'
TMPL

if [ "${ENABLE_WASMEDGE:-false}" = "true" ]; then
  cat >> /var/lib/rancher/k3s/agent/etc/containerd/config.toml.tmpl << 'TMPL'

# WasmEdge (optional): routes pods with runtimeClassName: wasmedge through crun
# (compiled --with-wasmedge in step 4). crun auto-detects WASM modules via the
# module.wasm.image/variant annotation and delegates to libwasmedge.so 0.14.1.
[plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.wasmedge]
  runtime_type = 'io.containerd.runc.v2'
  pod_annotations       = ["run.oci.handler", "module.wasm.image/variant"]
  container_annotations = ["run.oci.handler", "module.wasm.image/variant"]

[plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.wasmedge.options]
  BinaryName = '/usr/local/bin/crun'
TMPL
fi

# 6. Install containerd-shim-spin for SpinKube (WASI P2 via Wasmtime/Cranelift).
#
# IMPORTANT: Spin uses Wasmtime as its embedded runtime — NOT WasmEdge.
# This is architecturally distinct from the WasmEdge/crun chain above:
#   WasmEdge chain: kubelet → containerd → crun (--with-wasmedge) → WasmEdge LLVM JIT
#   Spin chain:     kubelet → containerd → containerd-shim-spin   → Wasmtime Cranelift JIT
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

# 7. Restart k3s so containerd picks up the new runtime config
systemctl restart k3s
