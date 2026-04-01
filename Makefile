.PHONY: setup-local up configure label-node label-node-wasmedge deploy-stack deploy-wasmedge test info teardown

SSH_KEY  := ~/.ssh/id_hetzner_cloud
SSH_OPTS := -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
KC       := KUBECONFIG=./hetzner-thesis.yaml

# Derive the server IP from Terraform state (works offline after `up`)
IP = $(shell terraform output -raw instance_public_ip 2>/dev/null)

# ── 1. Local prerequisites ────────────────────────────────────────────────────
# Install k6 locally (run once). Requires apt-based Linux.
setup-local:
	@if command -v k6 >/dev/null 2>&1; then \
		echo "k6 already installed. Skipping."; \
	else \
		echo "Installing k6..."; \
		sudo install -m 0755 -d /usr/share/keyrings; \
		sudo gpg --no-default-keyring \
			--keyring /usr/share/keyrings/k6-archive-keyring.gpg \
			--keyserver hkp://keyserver.ubuntu.com:80 \
			--recv-keys C5AD17C747E3415A3642D57D77C6C491D6AC1D69; \
		echo "deb [signed-by=/usr/share/keyrings/k6-archive-keyring.gpg] https://dl.k6.io/deb stable main" \
			| sudo tee /etc/apt/sources.list.d/k6.list; \
		sudo apt-get update && sudo apt-get install -y k6; \
	fi

# ── 2. Provision the Hetzner server ──────────────────────────────────────────
up:
	terraform apply -auto-approve

# ── 3. Fetch kubeconfig (waits for k3s to be ready) ──────────────────────────
configure:
	@echo "Waiting for SSH..."
	@timeout 300 bash -c \
		'until ssh $(SSH_OPTS) -i $(SSH_KEY) root@$(IP) "echo ok" 2>/dev/null; \
		 do sleep 10; echo "SSH not ready..."; done'
	@echo "Waiting for cloud-init to complete..."
	@ssh $(SSH_OPTS) -i $(SSH_KEY) root@$(IP) "cloud-init status --wait" 2>/dev/null || \
		echo "WARNING: cloud-init may have failed — check /var/log/thesis-setup.log on the server"
	@echo "Waiting for k3s kubeconfig..."
	@until ssh $(SSH_OPTS) -i $(SSH_KEY) root@$(IP) \
		"[ -f /etc/rancher/k3s/k3s.yaml ]" 2>/dev/null; \
		do sleep 10; echo "Still waiting for k3s..."; done
	@echo "Fetching kubeconfig..."
	scp $(SSH_OPTS) -i $(SSH_KEY) \
		root@$(IP):/etc/rancher/k3s/k3s.yaml ./hetzner-thesis.yaml
	sed -i "s/127.0.0.1/$(IP)/g" ./hetzner-thesis.yaml
	@echo "kubeconfig saved to ./hetzner-thesis.yaml"

# ── 4. Label node for SpinKube (primary default) ─────────────────────────────
label-node:
	$(KC) kubectl label node --all \
		runtime.spin.sh/runtime=spin \
		--overwrite

# ── 4a. (Optional) Add WasmEdge labels for WASI P1 comparison variants ───────
label-node-wasmedge:
	$(KC) kubectl label node --all \
		runtime.kwasm.sh/runtime=wasmedge \
		node.kubernetes.io/wasm-runtime=wasmedge \
		--overwrite

# ── 5. Deploy observability stack and SpinKube RuntimeClass ──────────────────
deploy-stack:
	$(KC) kubectl apply -f spin-runtimeclass.yaml
	# cert-manager is required by SpinOperator's admission webhook.
	$(KC) kubectl apply -f \
		https://github.com/cert-manager/cert-manager/releases/download/v1.16.3/cert-manager.yaml
	@echo "Waiting for cert-manager to be ready..."
	$(KC) kubectl rollout status deployment/cert-manager         -n cert-manager --timeout=300s
	$(KC) kubectl rollout status deployment/cert-manager-webhook -n cert-manager --timeout=300s
	# SpinOperator watches SpinApp CRDs and manages the Spin workload lifecycle.
	# Spin uses Wasmtime/Cranelift internally (see spinkube-rationale.md).
	# SpinOperator requires CRDs to be installed first
	$(KC) kubectl apply -f \
		https://github.com/spinframework/spin-operator/releases/download/v0.6.1/spin-operator.crds.yaml
	$(KC) helm upgrade --install spin-operator \
		--namespace spin-operator \
		--create-namespace \
		oci://ghcr.io/spinframework/charts/spin-operator \
		--version 0.6.1 \
		--wait
	$(KC) kubectl apply -f \
		https://github.com/spinframework/spin-operator/releases/download/v0.6.1/spin-operator.shim-executor.yaml
	$(KC) helm repo add prometheus-community \
		https://prometheus-community.github.io/helm-charts
	$(KC) helm repo update
	$(KC) helm upgrade --install prometheus prometheus-community/kube-prometheus-stack \
		--namespace observability \
		--create-namespace \
		--values observability-values.yaml \
		--timeout 10m \
		--wait

# ── 5a. (Optional) Deploy WasmEdge RuntimeClass for WASI P1 comparison ───────
deploy-wasmedge:
	$(KC) kubectl label node --all \
		runtime.kwasm.sh/runtime=wasmedge \
		node.kubernetes.io/wasm-runtime=wasmedge \
		--overwrite
	$(KC) kubectl apply -f wasmedge-runtimeclass.yaml

# ── 6. Smoke-test: deploy a SpinApp and verify it responds ───────────────────
test:
	$(KC) kubectl apply -f test-spin.yaml
	@echo "Waiting for hello-spin SpinApp to be available..."
	$(KC) kubectl wait --for=condition=Available spinapp/hello-spin \
		-n hello-spin --timeout=120s || true
	$(KC) kubectl logs -n hello-spin \
		-l core.spinkube.dev/app-name=hello-spin --tail=20
	$(KC) kubectl delete -f test-spin.yaml --ignore-not-found

# ── 7. Show access URLs and credentials ──────────────────────────────────────
info:
	@echo ""
	@echo "=== Thesis Experiment Access Info ==="
	@echo "  Server IP  : $(IP)"
	@echo "  Grafana    : http://$(IP):32000  (admin / thesis-grafana)"
	@echo "  Prometheus : http://$(IP):32090"
	@echo "  K8s API    : https://$(IP):6443"
	@echo "  SSH        : ssh -i $(SSH_KEY) root@$(IP)"
	@echo ""
	@echo "=== Kubeconfig ==="
	@echo "  export KUBECONFIG=$(PWD)/hetzner-thesis.yaml"
	@echo ""

# ── 8. Tear down everything ───────────────────────────────────────────────────
teardown:
	terraform destroy -auto-approve
	rm -f ./hetzner-thesis.yaml
