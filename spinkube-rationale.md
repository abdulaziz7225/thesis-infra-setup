# SpinKube Infrastructure Rationale

This document explains why **Fermyon Spin / SpinKube** was chosen as the WebAssembly runtime
for the thesis benchmarking experiment, describes its architecture, and explains the decision
over the primary alternative (WasmCloud).

---

## What Fermyon Spin Is

**Fermyon Spin** is an open-source framework for building and running HTTP microservices
as WebAssembly components. It implements the `wasi:http/incoming-handler` interface from
WASI Preview 2 (P2), handling all HTTP connection management internally and dispatching each
incoming request to the component's `handle` export. Applications are single-function
request handlers — no server loop required.

Key characteristics:
- **Runtime**: Embeds **Wasmtime** (Bytecode Alliance, Cranelift JIT backend) as its Wasm execution engine.
- **WASI version**: Preview 2 (Component Model, WIT interfaces).
- **HTTP model**: Synchronous request/response per component invocation — analogous to a serverless function or a single HTTP handler call in Docker.
- **Packaging**: Applications are packaged as Spin OCI artifacts via `spin registry push` (distinct from Docker images; uses `application/vnd.fermyon.spin.manifest.v2+json` media types).

**SpinKube** is the CNCF Sandbox project (accepted January 2025) that brings Spin to
Kubernetes via:
1. `containerd-shim-spin-v2` — a containerd shim v2 implementation that embeds Spin (and thus Wasmtime). Operates at the same level as runc.
2. **SpinOperator** — a Kubernetes operator that manages the `SpinApp` CRD lifecycle, creating Deployments with `runtimeClassName: wasmtime-spin` and validating Spin OCI artifacts.
3. `wasmtime-spin` RuntimeClass — routes pod scheduling to nodes with `containerd-shim-spin-v2` installed.

---

## SpinKube Architecture

```
kubelet → containerd → containerd-shim-spin-v2 → Spin → Wasmtime/Cranelift → .wasm component
```

Unlike runc-based containers:
- The shim owns the HTTP listener (no network namespace hand-off).
- Each HTTP request instantiates the Wasm component (or reuses a warm instance if `max_instances > 1`).
- The component binary + `spin.toml` are packaged together in the Spin OCI artifact, not in a standard Docker image layer.

The SpinOperator manages the `SpinApp` CRD and reconciles it to the desired `spec.replicas`.
**Never use `kubectl scale deployment` for SpinApp-managed pods** — the operator reconciles
it back. Use `kubectl patch spinapp`.

---

## Why Fermyon Spin Over WasmCloud

Both SpinKube and WasmCloud deploy WASI P2 WebAssembly workloads in Kubernetes. WasmCloud
was not chosen because its execution model is fundamentally incompatible with a fair latency
comparison against Docker HTTP microservices:

| Criterion                  | SpinKube / Fermyon Spin                        | WasmCloud                                      |
|----------------------------|------------------------------------------------|------------------------------------------------|
| HTTP execution model       | Direct: Spin owns TCP + dispatches per request | Indirect: requests flow through a NATS broker  |
| Latency measurement        | Clean — no infrastructure overhead on the path | Contaminated — NATS round-trip added to every request latency |
| K8s integration level      | containerd shim (pod-level, same as runc)      | Operator above Kubernetes (not pod-level)      |
| Comparison semantics       | Like-for-like with Docker HTTP service         | Different abstraction (distributed actor mesh) |
| CNCF status                | Sandbox (January 2025)                         | Incubating (November 2024)                     |
| Rust support               | First-class (spin-sdk, `#[http_component]`)    | Supported (wasmcloud-component SDK)            |
| TinyGo support             | Via Spin Go SDK (`spinhttp.Handle()`, wasip1)  | Supported but requires wasmCloud SDK           |

The thesis measures HTTP request latency and throughput as the primary metrics. WasmCloud's
NATS message bus introduces a mandatory network hop for every request, making its latency
numbers incomparable to Docker's direct TCP path. SpinKube's synchronous HTTP handler model
is the direct analog to a Docker container serving HTTP — the same request enters, the same
response exits, with no additional infrastructure in between.

---

## Why Fermyon Spin Over a Raw Deployment + runtimeClassName

A raw Kubernetes `Deployment` with `runtimeClassName: wasmtime-spin` can run Spin components
without the SpinOperator. SpinKube/SpinOperator is preferred because:

1. **Image validation**: The operator validates that the referenced image is a valid Spin OCI artifact before creating pods, surfacing errors at apply-time rather than at pod startup.
2. **Correct scaling**: `kubectl patch spinapp` is the only safe scaling path — the operator owns the Deployment and reconciles it back to `spec.replicas`. Direct `kubectl scale deployment` is overridden.
3. **Health management**: The operator manages pod readiness via its own probes suited to Spin's startup model (no HTTP readiness probe required on the SpinApp spec).

---

## `max_instances = 1` for Resource Fairness

All four benchmark variants (wasm-rust, wasm-tinygo, docker-rust, docker-golang) must
operate under equivalent resource constraints for the comparison to be valid.

Docker variants are constrained to single-threaded execution:
- `docker-rust`: `TOKIO_WORKER_THREADS=1`
- `docker-golang`: `GOMAXPROCS=1`

Wasm variants use `max_instances = 1` in `spin.toml`, capping concurrent Wasm instances
to one. This makes Spin's concurrency equivalent to the Docker single-thread constraint.

Queuing differs slightly:
- Docker (1 thread): excess connections queue at the TCP level (OS listen backlog).
- Spin (max_instances=1): excess requests queue within Spin's HTTP layer before component dispatch.

This behavioural difference is documented as a confounding variable in the thesis discussion.

---

## References

- [Fermyon Spin](https://github.com/spinframework/spin)
- [SpinKube (CNCF Sandbox)](https://www.spinkube.dev/)
- [containerd-shim-spin](https://github.com/spinframework/containerd-shim-spin)
- [SpinOperator](https://github.com/spinkube/spin-operator)
- [WASI 0.2 Launch — Bytecode Alliance](https://bytecodealliance.org/articles/WASI-0.2)
- [wasmCloud CNCF Incubating](https://www.cncf.io/blog/2024/11/12/cncf-welcomes-wasmcloud-to-the-cncf-incubator/)
