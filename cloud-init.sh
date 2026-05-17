#!/bin/bash
exec > /var/log/thesis-setup.log 2>&1
set -ex

# Bootstrap a single-node upstream Kubernetes cluster on a fresh Ubuntu 24.04 VM:
#   containerd 2.x → kubeadm 1.34 (kubelet/kubectl) → Flannel CNI →
#   local-path-provisioner → containerd-shim-spin-v2 for SpinKube.

# ── 1. Base prerequisites ────────────────────────────────────────────────────
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y apt-transport-https ca-certificates curl gpg tar

# ── 2. Kernel modules + sysctl required by kubeadm ───────────────────────────
cat > /etc/modules-load.d/k8s.conf <<'EOF'
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter

cat > /etc/sysctl.d/k8s.conf <<'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system

# Disable swap (kubeadm requirement)
swapoff -a
sed -i.bak '/\bswap\b/d' /etc/fstab

# ── 3. Install containerd 2.x + runc + CNI plugins from upstream ─────────────
# containerd 2.x is required for the Spin RuntimeClass plugin key
# (io.containerd.cri.v1.runtime) used by containerd-shim-spin-v2.
CONTAINERD_VERSION="2.0.2"
RUNC_VERSION="1.2.4"
CNI_PLUGINS_VERSION="1.6.2"
ARCH="amd64"

curl -fsSL --retry 8 --retry-delay 5 --retry-all-errors \
  "https://github.com/containerd/containerd/releases/download/v${CONTAINERD_VERSION}/containerd-${CONTAINERD_VERSION}-linux-${ARCH}.tar.gz" \
  | tar -xz -C /usr/local

# Stock Ubuntu 24.04 ships /usr/local/lib but no further subdirs, and may not
# have /usr/local/sbin populated until something installs into it. Pre-create
# the target directories so the install/curl steps below cannot race.
install -d -m 0755 /usr/local/lib/systemd/system /usr/local/sbin

curl -fsSL --retry 8 --retry-delay 5 --retry-all-errors \
  -o /tmp/containerd.service \
  "https://raw.githubusercontent.com/containerd/containerd/v${CONTAINERD_VERSION}/containerd.service"
install -m 0644 /tmp/containerd.service /usr/local/lib/systemd/system/containerd.service
rm -f /tmp/containerd.service

curl -fsSL --retry 8 --retry-delay 5 --retry-all-errors \
  -o /usr/local/sbin/runc \
  "https://github.com/opencontainers/runc/releases/download/v${RUNC_VERSION}/runc.${ARCH}"
chmod 755 /usr/local/sbin/runc

mkdir -p /opt/cni/bin
curl -fsSL --retry 8 --retry-delay 5 --retry-all-errors \
  "https://github.com/containernetworking/plugins/releases/download/v${CNI_PLUGINS_VERSION}/cni-plugins-linux-${ARCH}-v${CNI_PLUGINS_VERSION}.tgz" \
  | tar -xz -C /opt/cni/bin

# Generate containerd's default config and switch the cgroup driver to systemd
# (required by kubeadm 1.34 + Ubuntu 24.04's cgroup v2).
mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

# Register the spin runtime plugin BEFORE containerd starts so the shim is
# visible on first boot. Same plugin key the spin-runtimeclass.yaml expects.
cat >> /etc/containerd/config.toml <<'TOML'

# SpinKube: route pods with runtimeClassName: wasmtime-spin to this shim.
[plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.spin]
  runtime_type = 'io.containerd.spin.v2'
TOML

systemctl daemon-reload
systemctl enable --now containerd

# ── 4. Install kubeadm, kubelet, kubectl from pkgs.k8s.io ────────────────────
KUBE_VERSION="1.34"
install -m 0755 -d /etc/apt/keyrings
curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${KUBE_VERSION}/deb/Release.key" \
  | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${KUBE_VERSION}/deb/ /" \
  > /etc/apt/sources.list.d/kubernetes.list
apt-get update -y
apt-get install -y kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl   # prevent unattended upgrades

# ── 5. Pre-pull kubeadm control-plane images + install spin shim ─────────────
#
# kubeadm init would otherwise pull ~6 control-plane images serially from
# registry.k8s.io (~200 MB) before bootstrapping. Run the pull in the
# background here so it overlaps with the spin shim download. Pulled images
# land in containerd's on-disk content store and persist across the restart
# below.
#
# containerd-shim-spin implements the containerd shim v2 protocol directly and
# embeds the Spin runtime (Wasmtime). It runs Spin applications that export
# wasi:http/incoming-handler (WASI P2 Component Model).
kubeadm config images pull --kubernetes-version "stable-${KUBE_VERSION}" \
  >/var/log/kubeadm-images-pull.log 2>&1 &
KUBEADM_PULL_PID=$!

SPIN_SHIM_VERSION="0.17.0"
SPIN_SHIM_TGZ=$(mktemp /tmp/containerd-shim-spin.XXXXXX.tar.gz)
curl -fsSL --retry 8 --retry-delay 5 --retry-connrefused --retry-all-errors \
  -o "${SPIN_SHIM_TGZ}" \
  "https://github.com/spinframework/containerd-shim-spin/releases/download/v${SPIN_SHIM_VERSION}/containerd-shim-spin-v2-linux-x86_64.tar.gz"
tar -xzf "${SPIN_SHIM_TGZ}" -C /usr/local/bin/
rm -f "${SPIN_SHIM_TGZ}"
chmod +x /usr/local/bin/containerd-shim-spin-v2
test -x /usr/local/bin/containerd-shim-spin-v2  # fail loudly if shim is missing

# Block until the pre-pull finishes so the containerd restart below doesn't
# interrupt in-flight image transfers. `set -e` propagates a pull failure.
wait "${KUBEADM_PULL_PID}"

# Restart containerd so it picks up both the spin plugin and the shim binary.
systemctl restart containerd

# ── 6. kubeadm init ──────────────────────────────────────────────────────────
# Fetch public IP from Hetzner metadata for the API server's TLS SAN
# (needed so the operator can talk to the cluster from outside the VM).
PUBLIC_IP=$(curl --retry 5 --retry-connrefused --retry-delay 2 -s \
  http://169.254.169.254/hetzner/v1/metadata/public-ipv4)

cat > /etc/kubeadm-config.yaml <<YAML
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
kubernetesVersion: "stable-${KUBE_VERSION}"
networking:
  podSubnet: "10.244.0.0/16"
apiServer:
  certSANs:
    - "${PUBLIC_IP}"
    - "127.0.0.1"
    - "localhost"
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
YAML

kubeadm init --config /etc/kubeadm-config.yaml

mkdir -p /root/.kube
cp -f /etc/kubernetes/admin.conf /root/.kube/config
export KUBECONFIG=/etc/kubernetes/admin.conf

# ── 7. Single-node: remove the control-plane taint ───────────────────────────
# kubeadm taints the control plane by default, so on a single-node cluster
# the workload pods would otherwise have nowhere to schedule.
kubectl taint nodes --all node-role.kubernetes.io/control-plane:NoSchedule- || true

# ── 8. Install Flannel CNI ───────────────────────────────────────────────────
# Pod CIDR matches the kubeadm-config above (10.244.0.0/16 is Flannel's default).
kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml

# ── 9. Install local-path-provisioner + mark as default StorageClass ─────────
# kubeadm does not ship a default StorageClass, so the kube-prometheus-stack
# PVC needs Rancher's local-path-provisioner installed explicitly — otherwise
# the Prometheus PVC stays Pending.
kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/master/deploy/local-path-storage.yaml
kubectl patch storageclass local-path \
  -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'

# ── 10. Wait for the node to reach Ready ─────────────────────────────────────
# kubelet needs a moment after Flannel is up to flip the node to Ready.
for i in $(seq 1 30); do
  STATUS=$(kubectl get node --no-headers 2>/dev/null | awk '{print $2}')
  [ "$STATUS" = "Ready" ] && break
  echo "Node not Ready yet (attempt $i/30): status=${STATUS:-Unknown}"
  sleep 10
done
echo "Final node status: $(kubectl get node --no-headers | awk '{print $2}')"
