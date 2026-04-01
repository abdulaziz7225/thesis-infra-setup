# Master Thesis Infrastructure

Infrastructure-as-code for the master thesis:
**"A Comparative Analysis of WebAssembly and Docker for Microservice Architecture in Kubernetes"**

A single-node Kubernetes cluster on Hetzner Cloud, pre-configured to run both standard OCI containers
and WebAssembly (WASI P2) workloads side-by-side, with Prometheus and Grafana for metrics collection.

---

## Architecture overview

```text
Hetzner Cloud (ccx13 — 2 vCPU, 8 GB RAM, 80 GB disk)
└── Ubuntu 24.04
    └── k3s (lightweight Kubernetes, no Traefik)
        ├── SpinKube runtime  ← WASI P2 Wasm pods via containerd-shim-spin-v2
        ├── runc              ← standard Docker/OCI pods
        └── observability namespace
            ├── Prometheus (NodePort 32090, 5 s scrape interval, 10 Gi PVC)
            └── Grafana    (NodePort 32000, admin / thesis-grafana)
```

**Key components:**

| Component               | Version / Detail                                        |
| ----------------------- | ------------------------------------------------------- |
| k3s                     | v1.35.2+k3s1 (containerd v2)                           |
| containerd-shim-spin-v2 | v0.17.0 (SpinKube; embeds Spin + Wasmtime/Cranelift)   |
| SpinOperator            | v0.6.1 (Helm, `spinoperator` chart; manages SpinApp CRDs) |
| cert-manager            | v1.16.3 (prerequisite for SpinOperator webhooks)       |
| kube-prometheus-stack   | via Helm, prometheus-community chart                   |
| k6                      | installed locally for load testing                     |

**Firewall rules (managed by Terraform):**

| Port        | Access        | Purpose                          |
| ----------- | ------------- | -------------------------------- |
| 22          | admin IP only | SSH                              |
| 6443        | admin IP only | Kubernetes API                   |
| 80          | public        | HTTP                             |
| 30000–32767 | admin IP only | NodePort (Grafana, Prometheus, benchmark services) |

---

## Prerequisites

### Local tools

- [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.0
- `kubectl` and `helm`
- `ssh` / `scp`
- `make`

Install k6 (load testing tool):

```bash
make setup-local
```

### Hetzner Cloud

1. Create an account at [hetzner.com](https://www.hetzner.com/cloud)
2. Generate an **API token** (Read & Write) in the Cloud Console → Security → API Tokens
3. Upload your SSH public key in the Cloud Console → Security → SSH Keys, and note the **key name** you gave it

---

## Configuration

### 1. Terraform variables

Create `terraform.tfvars` in this directory:

```hcl
admin_ip_cidr = "YOUR_PUBLIC_IP/32"   # only your IP can SSH and reach NodePorts
ssh_key_name  = "your-key-name"       # name of the SSH key in Hetzner Cloud dashboard
server_type   = "ccx13"
os_image      = "ubuntu-24.04"
location      = "nbg1"                # Nuremberg
```

Find your public IP: `curl -4 ifconfig.me`

### 2. API token

Export the Hetzner API token so Terraform and the provider can authenticate:

```bash
export HCLOUD_TOKEN="your-hetzner-api-token"
```

Add this to your shell profile (`~/.bashrc` or `~/.zshrc`) to avoid repeating it.

### 3. Terraform init (first time only)

```bash
terraform init
```

---

## Full setup — step by step

```bash
make up            # 1. Provision Hetzner server + run cloud-init (k3s + containerd-shim-spin-v2)
make configure     # 2. Wait for k3s, fetch kubeconfig → hetzner-thesis.yaml
make label-node    # 3. Label node with SpinKube capability (runtime.spin.fermyon.com/v2=true)
make deploy-stack  # 4. Deploy cert-manager, SpinOperator, Prometheus, Grafana, RuntimeClass
make test          # 5. Smoke-test: run a SpinApp pod and verify HTTP 200
make info          # 6. Print access URLs and credentials
```

After `make info` you will see:

```text
=== Thesis Experiment Access Info ===
  Server IP  : 1.2.3.4
  Grafana    : http://1.2.3.4:32000  (admin / thesis-grafana)
  Prometheus : http://1.2.3.4:32090
  K8s API    : https://1.2.3.4:6443
  SSH        : ssh -i ~/.ssh/id_hetzner_cloud root@1.2.3.4
```

### Using kubectl directly

```bash
export KUBECONFIG=$PWD/hetzner-thesis.yaml
kubectl get nodes
kubectl get pods -A
```

---

## Repository structure

```text
.
├── main.tf                    # Terraform: Hetzner server + firewall
├── variables.tf               # Terraform: input variable declarations
├── terraform.tfvars           # Your local config (not committed)
├── cloud-init.sh              # Bootstrap script (k3s + containerd-shim-spin-v2)
├── spin-runtimeclass.yaml     # Kubernetes RuntimeClass for SpinKube (wasmtime-spin)
├── test-spin.yaml             # Smoke-test SpinApp (hello-spin, validates Wasmtime shim)
├── observability-values.yaml  # Helm values for kube-prometheus-stack
├── wasmedge-runtimeclass.yaml # (Optional) RuntimeClass for WasmEdge/WASI P1 pods
├── test-wasmedge.yaml         # (Optional) Smoke-test WasmEdge pod
└── Makefile                   # All workflow targets
```

---

## Makefile reference

| Target               | Description                                                        |
| -------------------- | ------------------------------------------------------------------ |
| `setup-local`        | Install k6 locally (run once)                                      |
| `up`                 | `terraform apply` — provision the server                           |
| `configure`          | Fetch kubeconfig from server → `hetzner-thesis.yaml`               |
| `label-node`         | Label node with SpinKube capability (`runtime.spin.fermyon.com/v2=true`) |
| `deploy-stack`       | Deploy cert-manager, SpinOperator, Prometheus, Grafana, RuntimeClass |
| `test`               | Run a Spin smoke-test SpinApp and verify HTTP 200                  |
| `info`               | Print Grafana/Prometheus URLs and SSH command                      |
| `teardown`           | `terraform destroy` — delete everything                            |
| `label-node-wasmedge` | *(Optional)* Label node for WasmEdge/WASI P1 pods                |
| `deploy-wasmedge`    | *(Optional)* Deploy WasmEdge RuntimeClass                         |

---

## Optional: WasmEdge (WASI P1) comparison

WasmEdge is **not deployed by default**. It is available as an optional comparison runtime
for the WASI P1 appendix (Appendix B of the thesis report).

To add WasmEdge support to an already-running cluster:

```bash
# 1. Re-provision with WasmEdge enabled (cloud-init installs crun --with-wasmedge)
ENABLE_WASMEDGE=true make up

# 2. Label the node for WasmEdge pods
make label-node-wasmedge

# 3. Deploy the WasmEdge RuntimeClass
make deploy-wasmedge

# 4. Smoke-test
kubectl apply -f test-wasmedge.yaml
kubectl logs -n default <pod-name>

# 5. Deploy optional benchmark variants
kubectl apply -f ../thesis-experiments/k8s/01-prime-sieve/optional/
```

Note: WasmEdge variants run at NodePorts 30085–30086, which do not conflict with the
primary SpinKube variants (30081–30084). Both runtimes can coexist on the same node.
