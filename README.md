# Master Thesis Infrastructure

Infrastructure-as-code for the master thesis:
**"A Comparative Analysis of WebAssembly and Docker for Microservice Architecture in Kubernetes"**

A single-node Kubernetes cluster on Hetzner Cloud, pre-configured to run both standard OCI containers and WebAssembly (WASM) workloads side-by-side, with Prometheus and Grafana for metrics collection.

---

## Architecture overview

```bash
Hetzner Cloud (ccx13 — 2 vCPU, 8 GB RAM, 80 GB disk)
└── Ubuntu 24.04
    └── k3s (lightweight Kubernetes, no Traefik)
        ├── WasmEdge runtime  ← runs WASM pods via containerd shim
        ├── runc              ← runs standard Docker/OCI pods
        └── observability namespace
            ├── Prometheus (NodePort 32090, 5s scrape interval, 10 Gi PVC)
            └── Grafana    (NodePort 32000, admin / thesis-grafana)
```

**Key components:**

| Component                | Version / Detail                       |
| ------------------------ | -------------------------------------- |
| k3s                      | v1.34.5+k3s1 (containerd v2)           |
| WasmEdge                 | latest (installed via official script) |
| containerd-shim-wasmedge | v0.6.0 (runwasi)                       |
| kube-prometheus-stack    | via Helm, prometheus-community chart   |
| k6                       | installed locally for load testing     |

**Firewall rules (managed by Terraform):**

| Port        | Access        | Purpose                        |
| ----------- | ------------- | ------------------------------ |
| 22          | admin IP only | SSH                            |
| 6443        | admin IP only | Kubernetes API                 |
| 80          | public        | HTTP                           |
| 30000–32767 | admin IP only | NodePort (Grafana, Prometheus) |

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
make up            # 1. Provision Hetzner server + run cloud-init (k3s + WasmEdge ~5-10 min)
make configure     # 2. Wait for k3s, fetch kubeconfig → hetzner-thesis.yaml
make label-node    # 3. Label node with WasmEdge capability
make deploy-stack  # 4. Deploy Prometheus + Grafana + WasmEdge RuntimeClass (~5 min)
make test          # 5. Smoke-test: run a WASM pod and verify output
make info          # 6. Print access URLs and credentials
```

After `make info` you will see:

```bash
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

```bash
.
├── main.tf                    # Terraform: Hetzner server + firewall
├── variables.tf               # Terraform: input variable declarations
├── terraform.tfvars           # Your local config (not committed)
├── cloud-init.sh              # Bootstrap script (k3s + WasmEdge, runs on first boot)
├── wasmedge-runtimeclass.yaml # Kubernetes RuntimeClass for WasmEdge pods
├── test-wasm.yaml             # Smoke-test WASM pod (wasmedge/example-wasi)
├── observability-values.yaml  # Helm values for kube-prometheus-stack
└── Makefile                   # All workflow targets
```

---

## Makefile reference

| Target         | Description                                               |
| -------------- | --------------------------------------------------------- |
| `setup-local`  | Install k6 locally (run once)                             |
| `up`           | `terraform apply` — provision the server                  |
| `configure`    | Fetch kubeconfig from server → `hetzner-thesis.yaml`      |
| `label-node`   | Label the node with WasmEdge capability                   |
| `deploy-stack` | Deploy Prometheus, Grafana, and the WasmEdge RuntimeClass |
| `test`         | Run a WASM smoke-test pod and print its output            |
| `info`         | Print Grafana/Prometheus URLs and SSH command             |
| `teardown`     | `terraform destroy` — delete everything                   |
