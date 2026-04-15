# Rationale for Using a Dedicated Virtual Machine as the Experimental Environment

## 1. Initial Approach

The original plan was to run a single-node Kubernetes cluster locally on a personal Ubuntu laptop using either **Minikube** or **k3d** — two widely used tools for local Kubernetes development. Both would have been sufficient for prototyping, but neither is suitable for rigorous performance measurements.

---

## 2. Limitations of a Local Environment

Running experiments on a personal laptop introduces several threats to measurement validity:

- **Background process interference.** Desktop services, browsers, and IDEs compete for CPU, memory, and I/O with the workloads under measurement, introducing noise that is difficult to control.
- **Non-deterministic scheduling.** CPU frequency scaling and thermal throttling cause unpredictable variance in latency measurements between runs.
- **Runtime nesting.** Minikube adds a hypervisor layer; k3d nests K3s inside Docker containers. Both complicate the registration of the SpinKube containerd shim and add runtime overhead that is not part of the research question.
- **Poor reproducibility.** Results on a personal machine are tied to its specific software state and cannot be reliably reproduced on another machine or after system updates.

---

## 3. Decision: Dedicated Cloud VM with upstream Kubernetes (kubeadm)

To address these limitations, a dedicated Hetzner Cloud virtual machine (`ccx23`: 4 dedicated vCPUs, 16 GB RAM, 160 GB NVMe, Ubuntu 24.04 LTS) was provisioned exclusively for the experiment. The entire environment — server, firewall, Kubernetes distribution, Wasm runtime, and observability stack — is defined as code in this repository using Terraform and cloud-init, ensuring the environment is identical on every provisioning.

**Upstream Kubernetes via kubeadm** was chosen as the Kubernetes distribution for the following reasons:

- It is the reference installer in the official Kubernetes documentation and the foundation that the managed services used in production (AWS EKS, Google GKE, Azure AKS) run underneath; using it removes distribution-specific confounds from the runtime comparison.
- It uses containerd directly as its container runtime, which integrates cleanly with `containerd-shim-spin-v2` for SpinKube (Wasmtime) workloads.
- The ccx23 sizing provides comfortable headroom (4 vCPU, 16 GB RAM) above the combined footprint of the kubeadm control plane, the kube-prometheus-stack observability stack, the SpinOperator, and the benchmark workloads — including the unlimited-mode scaling experiment.

---

## 4. Summary

| Aspect | Local (rejected) | Dedicated VM (chosen) |
|---|---|---|
| Cluster host | Personal Ubuntu laptop | Hetzner Cloud `ccx23` |
| Kubernetes tool | Minikube / k3d | Kubernetes v1.34 (kubeadm) |
| Environment definition | Manual | Terraform + cloud-init |
| Reproducibility | Low | Full (infra-as-code) |
| Measurement isolation | Low | High (single-purpose host) |

The dedicated VM approach eliminates background noise, provides a stable and reproducible hardware baseline, and supports the SpinKube runtime integration without the constraints imposed by nested virtualisation or Docker-in-Docker setups.
