# Rationale for Using a Dedicated Virtual Machine as the Experimental Environment

## 1. Initial Approach

The original plan was to run a single-node Kubernetes cluster locally on a personal Ubuntu laptop using either **Minikube** or **k3d** — two widely used tools for local Kubernetes development. Both would have been sufficient for prototyping, but neither is suitable for rigorous performance measurements.

---

## 2. Limitations of a Local Environment

Running experiments on a personal laptop introduces several threats to measurement validity:

- **Background process interference.** Desktop services, browsers, and IDEs compete for CPU, memory, and I/O with the workloads under measurement, introducing noise that is difficult to control.
- **Non-deterministic scheduling.** CPU frequency scaling and thermal throttling cause unpredictable variance in latency measurements between runs.
- **Runtime nesting.** Minikube adds a hypervisor layer; k3d nests K3s inside Docker containers. Both complicate the registration of the WasmEdge containerd shim and add runtime overhead that is not part of the research question.
- **Poor reproducibility.** Results on a personal machine are tied to its specific software state and cannot be reliably reproduced on another machine or after system updates.

---

## 3. Decision: Dedicated Cloud VM with K3s

To address these limitations, a dedicated Hetzner Cloud virtual machine (`ccx13`: 2 dedicated vCPUs, 8 GB RAM, Ubuntu 24.04 LTS) was provisioned exclusively for the experiment. The entire environment — server, firewall, Kubernetes distribution, WasmEdge runtime, and observability stack — is defined as code in this repository using Terraform and cloud-init, ensuring the environment is identical on every provisioning.

**K3s** was chosen as the Kubernetes distribution for the following reasons:

- It uses containerd directly as its container runtime, and its v1.34+ release auto-detects the `containerd-shim-wasmedge` binary placed in `/usr/local/bin`, making WasmEdge integration straightforward.
- Its minimal footprint (single binary, SQLite-backed control plane) leaves more RAM available for the workloads under measurement.
- It is designed for production use, making its scheduling and runtime behaviour more representative of real deployment targets than Minikube or k3d.

Traefik was disabled at install time (`--disable traefik`) to avoid introducing an irrelevant processing layer between the load generator and the measured services.

---

## 4. Summary

| Aspect | Local (rejected) | Dedicated VM (chosen) |
|---|---|---|
| Cluster host | Personal Ubuntu laptop | Hetzner Cloud `ccx13` |
| Kubernetes tool | Minikube / k3d | K3s v1.34.5 |
| Environment definition | Manual | Terraform + cloud-init |
| Reproducibility | Low | Full (infra-as-code) |
| Measurement isolation | Low | High (single-purpose host) |

The dedicated VM approach eliminates background noise, provides a stable and reproducible hardware baseline, and supports the WasmEdge runtime integration without the constraints imposed by nested virtualisation or Docker-in-Docker setups.
